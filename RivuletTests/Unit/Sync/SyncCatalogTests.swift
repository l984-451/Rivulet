// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SyncCatalogTests: XCTestCase {

    func test_tastePreferencesSync() {
        for key in ["showHomeHero", "autoplayLimit", "autoSkipIntro", "skipForwardSeconds", "skipBackSeconds",
                    "liveTVFavoriteChannelIds", "liveTVLayout", "contentFilter.enabled", "contentFilter.customWords",
                    "plexDisabledServers", "useIntroDB", "showFavoritesTab"] {
            XCTAssertTrue(SyncCatalog.isSynced(key), key)
        }
    }

    func test_perProfileAndPerServerFamiliesSync() {
        XCTAssertTrue(SyncCatalog.isSynced("hiddenLibraryKeys"))
        XCTAssertTrue(SyncCatalog.isSynced("hiddenLibraryKeys_user_12"))
        XCTAssertTrue(SyncCatalog.isSynced("libraryOrder_provider_jellyfin:abc_u1"))
        XCTAssertTrue(SyncCatalog.isSynced("trackIntent.subtitle_user_7"))
        XCTAssertTrue(SyncCatalog.isSynced("homeCollectionPins_user_7"))
        XCTAssertTrue(SyncCatalog.isSynced("homeRowOrder_user_7"))
        XCTAssertTrue(SyncCatalog.isSynced("homePlaylistPins_user_7"))
        XCTAssertTrue(SyncCatalog.isSynced("showHomeFavoriteMovies_user_7"))
        XCTAssertTrue(SyncCatalog.isSynced("showHomeFavoriteShows_user_7"))
        XCTAssertTrue(SyncCatalog.isSynced("homeHeroSources_user_7"))
        XCTAssertTrue(SyncCatalog.isSynced("homeHeroSources"), "a profile-less device")
        XCTAssertTrue(SyncCatalog.isSynced("heroPlaylistPins_user_7"))
        XCTAssertTrue(SyncCatalog.isSynced("mediaLibrarySort.plex:1"))
        XCTAssertTrue(SyncCatalog.isSynced("contentFilter.violence.enabled"))
    }

    func test_photoPreferencesSync() {
        for key in ["photoSlideInterval", "photoSlideTransition", "photoSlidePlaysClips"] {
            XCTAssertTrue(SyncCatalog.isSynced(key), key)
        }
        XCTAssertTrue(SyncCatalog.isSynced("photoLibraryQuery.plex:abc.27"))
        XCTAssertFalse(SyncCatalog.isSynced("photoLibraryQuery."))
    }

    func test_familyPrefixDoesNotLeakToSimilarKeys() {
        XCTAssertFalse(SyncCatalog.isSynced("hiddenLibraryKeysExtra"))
        XCTAssertFalse(SyncCatalog.isSynced("hiddenLibraryKeys_other"))
        XCTAssertFalse(SyncCatalog.isSynced("contentFilter.a.b.enabled"))
        XCTAssertFalse(SyncCatalog.isSynced("contentFilter..enabled"))
        XCTAssertFalse(SyncCatalog.isSynced("trackIntent.migratedFromLegacy"))
    }

    func test_neverSynced() {
        let never = [
            // Credentials, identity and anything that can embed access.
            "plexAuthToken", "selectedServerToken", "plexProfileSession", "plexPin_abc", "server.token.jellyfin:x",
            "jellyfinAccount", "embyAccount", "liveTVSourceConfigurations", "liveTVSourceToken_x",
            "contentFilter.listSourceURL", "selectedServerURL", "selectedServerMachineID", "plexExtraServers",
            "plexUsername", "plexHasPersistedSession",
            // Per device.
            "plexClientIdentifier", "plexDirectCertificateHashesByAddress", "selectedPlexUserId",
            "homeStreamingQuality", "awayStreamingQuality", "upscaleLowResolution", "audioSyncOffsetMs",
            "subtitleDelayByMedia", "subtitleHeightUnits", "downloadQuality", "iosShowPlaylists",
            "recentSearchItems", "iosRecentSearches", "lastSeenBuild", "setupComplete",
            "liveTVRecentChannelIds", "liveTVEventSlotChannelIds",
            // The switch itself and its bookkeeping.
            SyncCatalog.enabledKey, SyncCatalog.stateKey, SyncCatalog.accountStateKey, SyncCatalog.accountPrintKey, SyncCatalog.heldKey,
        ]
        for key in never { XCTAssertFalse(SyncCatalog.isSynced(key), key) }
    }

    func test_channelIdsThatEmbedAddressesOrLoginsStayHome() {
        XCTAssertTrue(SyncCatalog.isSyncableChannelId("xtream:xtream:ab12cd34ef56ab12:7"))
        XCTAssertTrue(SyncCatalog.isSyncableChannelId("m3u:m3u:ab12cd34ef56ab12:CNN HD#1"))
        XCTAssertTrue(SyncCatalog.isSyncableChannelId("jellyfin:jellyfin:ee404c68:5"))
        // Before the re-key migration an M3U source was named by its whole playlist URL.
        XCTAssertFalse(SyncCatalog.isSyncableChannelId("m3u:http://host/get.php?username=u&password=p:Channel 1"))
        // Plex and Dispatcharr ids carry the server address, which differs per device.
        XCTAssertFalse(SyncCatalog.isSyncableChannelId("plex:plex:http://192.168.1.5:32400:5"))
        XCTAssertFalse(SyncCatalog.isSyncableChannelId("dispatcharr:dispatcharr:https://tv.example.com:abc"))
        XCTAssertFalse(SyncCatalog.isSyncableChannelId("x:user@host:1"))
        XCTAssertFalse(SyncCatalog.isSyncableChannelId("x:y:z?password=1"))
    }

    func test_channelListsAndPins_syncWithoutIdsThatStayHome() throws {
        XCTAssertTrue(SyncCatalog.isSynced("liveTVChannelLists"))
        XCTAssertTrue(SyncCatalog.isSynced("liveTVPinnedCategories"))
        let plex = "plex:plex:http://192.168.1.5:32400:5"
        let local: [[String: Any]] = [
            ["id": "a", "name": "Mine", "channelIds": ["xtream:xtream:ab12:7", plex]],
            ["id": "s", "name": "Dutch", "channelIds": [],
             "rules": ["origins": ["NL"], "genres": [], "sourceIds": ["xtream:ab12", "plex:http://host"], "words": []]],
        ]
        let data = try JSONSerialization.data(withJSONObject: local)
        let sent = try XCTUnwrap(SyncCatalog.outgoing("liveTVChannelLists", data) as? Data)
        let sentText = String(decoding: sent, as: UTF8.self)
        XCTAssertFalse(sentText.contains("192.168"))
        XCTAssertFalse(sentText.contains("plex:http"))
        XCTAssertTrue(sentText.contains("xtream:xtream:ab12:7"))
        // Same lists, same bytes.
        XCTAssertEqual(sent, SyncCatalog.outgoing("liveTVChannelLists", data) as? Data)

        // Back from the cloud with a channel added elsewhere: this device keeps its own home ids.
        var cloud = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [[String: Any]])
        cloud[0]["channelIds"] = ["xtream:xtream:ab12:7", "xtream:xtream:ab12:9"]
        let cloudData = try JSONSerialization.data(withJSONObject: cloud)
        let kept = try XCTUnwrap(SyncCatalog.incoming("liveTVChannelLists", cloud: cloudData, local: data) as? Data)
        let lists = try XCTUnwrap(JSONSerialization.jsonObject(with: kept) as? [[String: Any]])
        XCTAssertEqual(lists[0]["channelIds"] as? [String], ["xtream:xtream:ab12:7", "xtream:xtream:ab12:9", plex])
        XCTAssertEqual((lists[1]["rules"] as? [String: Any])?["sourceIds"] as? [String], ["xtream:ab12", "plex:http://host"])

        let pins = SyncCatalog.outgoing("liveTVPinnedCategories", ["xtream:ab12|NEWS", "plex:http://host|News"])
        XCTAssertEqual(pins as? [String], ["xtream:ab12|NEWS"])
    }

    func test_kvsKeyLimit() {
        XCTAssertTrue(SyncCatalog.fitsKVS(key: String(repeating: "k", count: 128)))
        XCTAssertFalse(SyncCatalog.fitsKVS(key: String(repeating: "k", count: 129)))
        // UTF-16 units, not characters.
        XCTAssertFalse(SyncCatalog.fitsKVS(key: String(repeating: "\u{1F3AC}", count: 65)))
    }

    /// An allowlisted name that looks like a secret must be a reviewed exception.
    func test_noAllowlistedKeyLooksLikeASecretExceptReviewedOnes() {
        let names = Array(SyncCatalog.exactKeys) + SyncCatalog.profileFamilies
        let flagged = Set(names.filter { name in
            SyncCatalog.secretWords.contains { name.lowercased().contains($0) }
        })
        XCTAssertEqual(flagged, SyncCatalog.reviewedSecretWordKeys)
    }

    // MARK: iCloud availability from the embedded profile

    private func profile(entitlements: String) -> Data {
        // The real file wraps the plist in a CMS signature: binary bytes on both sides.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Test</string>
        <key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
        """
        return Data([0x30, 0x82, 0x00, 0xFF]) + Data(plist.utf8) + Data([0xA0, 0x00, 0x31])
    }

    func test_cloudAvailable_profileWithoutICloud_isFalse() {
        let free = profile(entitlements: "<key>application-identifier</key><string>T.app</string>")
        XCTAssertFalse(SyncCatalog.cloudAvailable(profile: free))
    }

    func test_cloudAvailable_profileWithICloud_isTrue() {
        let paid = profile(entitlements: "<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>")
        XCTAssertTrue(SyncCatalog.cloudAvailable(profile: paid))
    }

    func test_cloudAvailable_noOrUnreadableProfile_isTrue() {
        XCTAssertTrue(SyncCatalog.cloudAvailable(profile: nil))
        XCTAssertTrue(SyncCatalog.cloudAvailable(profile: Data([0x00, 0x01, 0x02])))
    }
}
