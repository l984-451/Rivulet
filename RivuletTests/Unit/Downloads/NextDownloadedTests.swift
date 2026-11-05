// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Offline, Up Next is the next episode of the show that is on the device.
final class NextDownloadedTests: XCTestCase {
    private func episode(_ id: String, show: String = "show", season: Int, number: Int, provider: String = "jellyfin:srv",
                         state: DownloadState = .completed) -> DownloadRecord {
        var item = JellyfinFixtures.mediaItem(id, kind: .episode, providerID: provider, grandparent: show)
        item = MediaItem(ref: item.ref, kind: .episode, title: id, sortTitle: nil, overview: nil, year: nil, runtime: nil,
                         parentRef: nil, grandparentRef: item.grandparentRef, seriesTitle: "Show",
                         episodeNumber: number, seasonNumber: season, childProgress: nil, userState: item.userState,
                         artwork: item.artwork, parentArtwork: nil, grandparentArtwork: nil)
        return DownloadRecord(providerID: provider, itemID: id, sourceID: id, quality: "original", state: state,
                              item: item, metadata: PlexMetadata(ratingKey: id))
    }

    func test_nextEpisodeInTheSameSeason() {
        let records = [episode("e1", season: 1, number: 1), episode("e3", season: 1, number: 3), episode("e2", season: 1, number: 2)]
        let next = DownloadRules.nextDownloaded(afterShow: "show", season: 1, episode: 1, providerID: "jellyfin:srv", in: records)
        XCTAssertEqual(next?.itemID, "e2")
    }

    func test_rollsIntoTheNextSeason() {
        let records = [episode("s1e9", season: 1, number: 9), episode("s2e1", season: 2, number: 1)]
        let next = DownloadRules.nextDownloaded(afterShow: "show", season: 1, episode: 9, providerID: "jellyfin:srv", in: records)
        XCTAssertEqual(next?.itemID, "s2e1")
    }

    func test_skipsOtherShowsServersAndUnfinishedDownloads() {
        let records = [
            episode("other-show", show: "other", season: 1, number: 2),
            episode("other-server", season: 1, number: 2, provider: "emby:srv"),
            episode("partial", season: 1, number: 2, state: .downloading),
            episode("later", season: 1, number: 5),
        ]
        let next = DownloadRules.nextDownloaded(afterShow: "show", season: 1, episode: 1, providerID: "jellyfin:srv", in: records)
        XCTAssertEqual(next?.itemID, "later")
    }

    func test_noneAfterTheLastOne() {
        let records = [episode("e1", season: 1, number: 1)]
        XCTAssertNil(DownloadRules.nextDownloaded(afterShow: "show", season: 1, episode: 1, providerID: "jellyfin:srv", in: records))
    }

    func test_aBarePlexKeyMatchesAnyPlexServer() {
        let records = [episode("e2", season: 1, number: 2, provider: "plex:")]
        XCTAssertEqual(DownloadRules.nextDownloaded(afterShow: "show", season: 1, episode: 1, providerID: "plex:M", in: records)?.itemID, "e2")
    }
}
