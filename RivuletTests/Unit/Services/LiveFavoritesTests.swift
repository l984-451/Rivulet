// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveFavoritesTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveFavoritesTests: XCTestCase {

    /// One list across sources in the viewer's order, then Plex's own
    /// favourites in Plex's order. Channel number decides neither.
    func test_rivuletOrderThenSourceOrder() {
        let channels = [
            UnifiedChannel(id: "plexB", sourceType: .plex, sourceId: "p", channelNumber: 1, name: "B",
                           isFavourite: true, favouriteRank: 1),
            UnifiedChannel(id: "iptv", sourceType: .dispatcharr, sourceId: "d", channelNumber: 2, name: "I"),
            UnifiedChannel(id: "plexA", sourceType: .plex, sourceId: "p", channelNumber: 3, name: "A",
                           isFavourite: true, favouriteRank: 0),
            UnifiedChannel(id: "m3u", sourceType: .genericM3U, sourceId: "m", channelNumber: 4, name: "M"),
            UnifiedChannel(id: "other", sourceType: .genericM3U, sourceId: "m", channelNumber: 5, name: "O"),
        ]

        let ordered = LiveTVDataStore.favorites(in: channels, order: ["m3u", "iptv", "plexB", "gone"])

        XCTAssertEqual(ordered.map(\.id), ["m3u", "iptv", "plexB", "plexA"])
    }

    /// A Plex favourite removed in Rivulet leaves the list; one the viewer
    /// favourited again in Rivulet stays.
    func test_unfavoritedSourceFavoriteIsHidden() {
        let channels = [
            UnifiedChannel(id: "plexA", sourceType: .plex, sourceId: "p", channelNumber: 1, name: "A",
                           isFavourite: true, favouriteRank: 0),
            UnifiedChannel(id: "plexB", sourceType: .plex, sourceId: "p", channelNumber: 2, name: "B",
                           isFavourite: true, favouriteRank: 1),
        ]

        let ordered = LiveTVDataStore.favorites(in: channels, order: ["plexB"], unfavorited: ["plexA", "plexB"])

        XCTAssertEqual(ordered.map(\.id), ["plexB"])
    }
}
