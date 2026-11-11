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
            "liveTVRecentChannelIds", "liveTVViewings", "liveTVEventSlotChannelIds",
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
}
