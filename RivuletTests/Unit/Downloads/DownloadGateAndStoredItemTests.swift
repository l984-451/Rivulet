// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Synchronization
import XCTest
@testable import Rivulet

final class DownloadGateAndStoredItemTests: XCTestCase {
    private var savedSelected: Set<String> = []
    private var savedExtra: Set<String> = []

    override func setUp() {
        super.setUp()
        savedSelected = MediaItemRef.selectedPlexIDs.withLock { $0 }
        savedExtra = MediaItemRef.extraPlexIDs.withLock { $0 }
        MediaItemRef.selectedPlexIDs.withLock { $0 = ["plex:hash"] }
        MediaItemRef.extraPlexIDs.withLock { $0 = ["plex:OTHER"] }
    }

    override func tearDown() {
        MediaItemRef.selectedPlexIDs.withLock { $0 = savedSelected }
        MediaItemRef.extraPlexIDs.withLock { $0 = savedExtra }
        super.tearDown()
    }

    private func ref(_ provider: String) -> MediaItemRef { MediaItemRef(providerID: provider, itemID: "1") }

    // MARK: - Gate

    func test_gate_plexNeedsAServerStillSignedIn() {
        XCTAssertTrue(IOSDownloadGate.canDownload(ref("plex:hash")))
        XCTAssertTrue(IOSDownloadGate.canDownload(ref("plex:OTHER")))
        XCTAssertFalse(IOSDownloadGate.canDownload(ref("plex:GONE")))
    }

    func test_gate_jellyfinAndEmbyCanDownload_otherIdsCannot() {
        XCTAssertTrue(IOSDownloadGate.canDownload(ref("jellyfin:srv")))
        XCTAssertTrue(IOSDownloadGate.canDownload(ref("emby:srv")))
        XCTAssertFalse(IOSDownloadGate.canDownload(ref("tmdb")))
        XCTAssertFalse(IOSDownloadGate.canDownload(ref("")))
    }

    // MARK: - The copy a download keeps

    private func item(provider: String, art: String) -> MediaItem {
        let url = URL(string: art)
        let artwork = MediaArtwork(poster: url, backdrop: url, thumbnail: url, logo: url)
        return MediaItem(
            ref: MediaItemRef(providerID: provider, itemID: "ep"), kind: .episode, title: "Pilot", sortTitle: nil, overview: nil,
            year: nil, runtime: 1300, parentRef: MediaItemRef(providerID: provider, itemID: "season"),
            grandparentRef: MediaItemRef(providerID: provider, itemID: "show"), seriesTitle: "Show", episodeNumber: 1,
            seasonNumber: 1, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: artwork, parentArtwork: artwork, grandparentArtwork: artwork)
    }

    func test_storedPlexItem_isRekeyedToTheMachineIdAndKeepsNoArtwork() {
        let plex = item(provider: "plex:hash", art: "http://192.168.1.140:32400/library/metadata/1/thumb/2?X-Plex-Token=SECRET")
        let stored = plex.storedForDownload(providerID: "plex:MACHINE")
        XCTAssertEqual(stored.ref, MediaItemRef(providerID: "plex:MACHINE", itemID: "ep"))
        XCTAssertEqual(stored.parentRef, MediaItemRef(providerID: "plex:MACHINE", itemID: "season"))
        XCTAssertEqual(stored.grandparentRef, MediaItemRef(providerID: "plex:MACHINE", itemID: "show"))
        XCTAssertNil(stored.artwork.poster)
        XCTAssertNil(stored.grandparentArtwork?.backdrop)
        XCTAssertEqual(stored.title, "Pilot")
        XCTAssertEqual(stored.seriesTitle, "Show")
        XCTAssertEqual(stored.episodeNumber, 1)
        XCTAssertEqual(stored.runtime, 1300)
        let json = String(decoding: (try? JSONEncoder().encode(stored)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET"))
        XCTAssertFalse(json.contains("192.168"))
    }

    func test_storedJellyfinItem_keepsItsImagesWithoutTheKey() throws {
        let jelly = item(provider: "jellyfin:srv", art: "http://jf.local:8096/Items/ep/Images/Primary?tag=t1&ApiKey=SECRET&maxWidth=300")
        let stored = jelly.storedForDownload(providerID: "jellyfin:srv")
        let poster = try XCTUnwrap(stored.artwork.poster)
        XCTAssertEqual(poster.path, "/Items/ep/Images/Primary")
        XCTAssertEqual(URLComponents(url: poster, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["tag", "maxWidth"])
        XCTAssertEqual(stored.ref.providerID, "jellyfin:srv")
    }

    // MARK: - A Plex download's item comes from the full metadata

    func test_plexDownloadCopy_carriesTheHierarchyTheFullMetadataHas() {
        var meta = PlexMetadata(ratingKey: "124", type: "episode", title: "Low Tide")
        meta.grandparentRatingKey = "60"
        meta.grandparentTitle = "Harbor Lights"
        meta.parentRatingKey = "61"
        meta.parentIndex = 2
        meta.index = 5
        meta.thumb = "/library/metadata/124/thumb/1"
        meta.grandparentThumb = "/library/metadata/60/thumb/1"
        let item = MediaItem.plexDownloadCopy(meta, providerID: "plex:MACHINE")
        XCTAssertEqual(item.ref, MediaItemRef(providerID: "plex:MACHINE", itemID: "124"))
        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(item.seriesTitle, "Harbor Lights")
        XCTAssertEqual(item.seasonNumber, 2)
        XCTAssertEqual(item.episodeNumber, 5)
        XCTAssertEqual(item.parentRef, MediaItemRef(providerID: "plex:MACHINE", itemID: "61"))
        XCTAssertEqual(item.grandparentRef, MediaItemRef(providerID: "plex:MACHINE", itemID: "60"))
        XCTAssertNil(item.artwork.poster, "no address or token is kept")
        XCTAssertNil(item.artwork.thumbnail)
        XCTAssertNil(item.grandparentArtwork?.poster)
    }
}
