// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelsPaneScopeTests.swift
//  RivuletTests
//
//  The player's Channels pane: every channel of a small lineup, the playing
//  channel's group of a large one, never more than the limit.
//

import XCTest
@testable import Rivulet

final class LiveChannelsPaneScopeTests: XCTestCase {
    private func lineup(_ count: Int, group: (Int) -> String) -> [UnifiedChannel] {
        (0..<count).map { UnifiedChannel(id: "x:\($0)", sourceType: .xtream, sourceId: "x", name: "\($0)", groupTitle: group($0)) }
    }

    func test_smallLineup_isListedWhole() {
        let channels = lineup(120) { $0 % 2 == 0 ? "A" : "B" }
        XCTAssertEqual(LiveChannelsPaneScope.channels(channels, playing: channels[3]).count, 120)
    }

    func test_largeLineup_listsThePlayingChannelsGroup() {
        let channels = lineup(23_000) { $0 < 40 ? "NL" : "Other \($0 % 50)" }
        let shown = LiveChannelsPaneScope.channels(channels, playing: channels[7])
        XCTAssertEqual(shown.count, 40)
        XCTAssertTrue(shown.allSatisfy { $0.groupTitle == "NL" })
    }

    func test_largeGroup_isCutAroundThePlayingChannel() {
        let channels = lineup(5_000) { _ in "All" }
        let shown = LiveChannelsPaneScope.channels(channels, playing: channels[2_500])
        XCTAssertEqual(shown.count, LiveChannelsPaneScope.limit)
        XCTAssertTrue(shown.contains { $0.id == "x:2500" })
        XCTAssertEqual(LiveChannelsPaneScope.channels(channels, playing: channels[1]).first?.id, "x:0")
    }
}
