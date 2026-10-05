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

    /// EPG & Sports Editor's pregame block holds a slot until the game: it is
    /// not live, and its event starts as the block ends.
    func test_pregameBlock() {
        let block = UnifiedProgram(id: "b", channelId: "c", title: "UPCOMING: New York Jets @ Chicago Bears",
                                   startTime: .now - 3600, endTime: .now + 7200)
        XCTAssertTrue(block.isPregameBlock)
        XCTAssertFalse(block.isLiveAiring)
        XCTAssertEqual(block.displayTitle, "New York Jets @ Chicago Bears")
        XCTAssertEqual(block.eventStart, block.endTime)
        XCTAssertFalse(program("Live: New York Jets @ Chicago Bears").isPregameBlock)
        XCTAssertFalse(program("Upcoming Releases").isPregameBlock)
    }

    func test_emptySlot() {
        for title in ["No game scheduled", "NO EVENTS", "No Match", "Off Air", "off-air"] {
            XCTAssertTrue(program(title).isEmptySlot, title)
        }
        for title in ["No Reservations", "No Game Like It: The 1986 Mets", "To Be Announced", "College Football"] {
            XCTAssertFalse(program(title).isEmptySlot, title)
        }
    }

    func test_startLabel_namesTheDayOnlyWhenNotToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9))!
        let today = UnifiedProgram(id: "a", channelId: "c", title: "t", startTime: now + 3 * 3600, endTime: now + 6 * 3600)
        let monday = UnifiedProgram(id: "b", channelId: "c", title: "t", startTime: now + 34 * 3600, endTime: now + 37 * 3600)
        XCTAssertFalse(LiveCardItem.startLabel(today, now: now, calendar: calendar).contains("Mon"))
        XCTAssertTrue(LiveCardItem.startLabel(monday, now: now, calendar: calendar).contains("Mon"))
    }

    func test_onlyLiveAiringsAreLive() {
        XCTAssertTrue(program("Live: College Football").isLiveAiring)
        XCTAssertFalse(program("College Football").isLiveAiring, "a replay")
        XCTAssertFalse(program("Live PD: Police Patrol").isLiveAiring)
        XCTAssertTrue(program("College Football", isLive: true).isLiveAiring, "Plex's live flag")
    }
}
