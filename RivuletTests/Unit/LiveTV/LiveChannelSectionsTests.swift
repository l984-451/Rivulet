// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelSectionsTests.swift
//  RivuletTests
//
//  The Live TV player's channel list: favorites, groups in source order, then the rest.
//

import XCTest
@testable import Rivulet

final class LiveChannelSectionsTests: XCTestCase {
    private func ch(_ id: String, _ group: String?, rank: Int? = nil) -> UnifiedChannel {
        UnifiedChannel(id: id, sourceType: .genericM3U, sourceId: "s1", name: id, groupTitle: group, groupRank: rank)
    }

    func test_favoritesThenGroupsInSourceOrderThenUngrouped() {
        let channels = [ch("a", "Sports", rank: 1), ch("b", nil), ch("c", "News", rank: 0), ch("d", " Sports ", rank: 1)]
        let sections = LiveChannelSections.sections(of: channels, favorites: [channels[3]])
        XCTAssertEqual(sections.map(\.title), ["Favorites", "News", "Sports", "Other Channels"])
        XCTAssertEqual(sections.map { $0.channels.map(\.id) }, [["d"], ["c"], ["a", "d"], ["b"]])
    }

    func test_noGroupsNoFavorites_isOneUntitledSection() {
        let sections = LiveChannelSections.sections(of: [ch("a", nil), ch("b", "")], favorites: [])
        XCTAssertEqual(sections, [.init(title: nil, channels: [ch("a", nil), ch("b", "")])])
    }

    func test_emptyLineup_hasNoSections() {
        XCTAssertTrue(LiveChannelSections.sections(of: [], favorites: []).isEmpty)
    }
}
