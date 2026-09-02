// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BelowFoldContentLoaderTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class BelowFoldContentLoaderTests: XCTestCase {

    /// A season's page is that season only: its own episodes in the rail, with
    /// the pills and show detail still resolved through the parent show.
    func test_seasonLoadsOnlyItsOwnEpisodes() async {
        let stub = StubMediaProvider()
        stub.childrenByParent["show"] = [item("s1", .season, parent: "show"), item("s2", .season, parent: "show")]
        stub.childrenByParent["s2"] = [item("e3", .episode, parent: "s2")]
        stub.episodesByShow["show"] = [
            item("e1", .episode, parent: "s1"), item("e2", .episode, parent: "s1"), item("e3", .episode, parent: "s2"),
        ]
        MediaProviderRegistry.shared.register(stub)
        defer { MediaProviderRegistry.shared.unregister(providerID: stub.id) }

        let content = await BelowFoldContentLoader().load(for: item("s2", .season, parent: "show"), detail: nil)

        XCTAssertEqual(content.episodes.map(\.ref.itemID), ["e3"])
        XCTAssertEqual(content.seasons.map(\.ref.itemID), ["s1", "s2"])
        XCTAssertEqual(content.selectedSeason?.ref.itemID, "s2")
    }

    /// A show's page carries every season's episodes: that is what lets the
    /// pills switch season on focus by scrolling the rail.
    func test_showLoadsEveryEpisode() async {
        let stub = StubMediaProvider()
        stub.childrenByParent["show"] = [item("s1", .season, parent: "show"), item("s2", .season, parent: "show")]
        stub.episodesByShow["show"] = [
            item("e1", .episode, parent: "s1"), item("e2", .episode, parent: "s1"), item("e3", .episode, parent: "s2"),
        ]
        MediaProviderRegistry.shared.register(stub)
        defer { MediaProviderRegistry.shared.unregister(providerID: stub.id) }

        let content = await BelowFoldContentLoader().load(for: item("show", .show, parent: nil), detail: nil)

        XCTAssertEqual(content.episodes.map(\.ref.itemID), ["e1", "e2", "e3"])
    }

    private func item(_ id: String, _ kind: MediaKind, parent: String?) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "stub", itemID: id),
            kind: kind, title: id, sortTitle: nil, overview: nil,
            year: nil, runtime: nil,
            parentRef: parent.map { MediaItemRef(providerID: "stub", itemID: $0) },
            grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }
}
