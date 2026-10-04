// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveAiringTitleTests.swift
//  RivuletTests
//
//  What's On drops the guide's "Live:" marker from titles and shows LIVE
//  only for live airings, so a replay of a game never reads as live.
//

import XCTest
@testable import Rivulet

final class LiveAiringTitleTests: XCTestCase {
    private func program(_ title: String, isLive: Bool = false) -> UnifiedProgram {
        UnifiedProgram(id: "p", channelId: "c", title: title, startTime: .now,
                       endTime: .now + 1800, isLive: isLive)
    }

    func test_liveMarkers_areStripped() {
        XCTAssertEqual(UnifiedProgram.displayTitle("Live: SportsCenter"), "SportsCenter")
        XCTAssertEqual(UnifiedProgram.displayTitle("LIVE:College Football"), "College Football")
        XCTAssertEqual(UnifiedProgram.displayTitle("Live | MLB Baseball"), "MLB Baseball")
        XCTAssertEqual(UnifiedProgram.displayTitle("Live - NWSL Soccer"), "NWSL Soccer")
        XCTAssertEqual(UnifiedProgram.displayTitle("[LIVE] Premier League"), "Premier League")
        XCTAssertEqual(UnifiedProgram.displayTitle("(Live) Horse Racing"), "Horse Racing")
    }

    func test_showNamesStartingWithLive_areKept() {
        for title in ["Live PD: Police Patrol", "Live with Kelly and Mark", "LiveNOW from FOX",
                      "Live From The Nation's Capital", "Live-Action Shorts", "Live:", "College Football"] {
            XCTAssertEqual(UnifiedProgram.displayTitle(title), title)
        }
    }

    func test_onlyLiveAiringsAreLive() {
        XCTAssertTrue(program("Live: College Football").isLiveAiring)
        XCTAssertFalse(program("College Football").isLiveAiring, "a replay")
        XCTAssertFalse(program("Live PD: Police Patrol").isLiveAiring)
        XCTAssertTrue(program("College Football", isLive: true).isLiveAiring, "Plex's live flag")
    }
}
