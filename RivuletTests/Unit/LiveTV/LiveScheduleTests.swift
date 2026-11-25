// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveScheduleTests.swift
//  RivuletTests
//
//  The channel list's "Next" line and schedule column: real programmes from now on.
//

import XCTest
@testable import Rivulet

final class LiveScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A programme starting `start` minutes from now and lasting `length`.
    private func p(_ id: String, _ start: Double, _ length: Double = 30, title: String? = nil) -> UnifiedProgram {
        UnifiedProgram(id: id, channelId: "c", title: title ?? id,
                       startTime: now.addingTimeInterval(start * 60),
                       endTime: now.addingTimeInterval((start + length) * 60))
    }

    func test_upcoming_startsWithTheProgrammeOnNow_inAiringOrder() {
        let programs = [p("later", 60), p("past", -90), p("now", -10), p("next", 20)]
        XCTAssertEqual(LiveSchedule.upcoming(in: programs, now: now, limit: 10).map(\.id), ["now", "next", "later"])
    }

    func test_upcoming_skipsPlaceholdersAndEmptySlots_andStopsAtTheLimit() {
        let programs = [p("c:placeholder:1", -10), p("gap", 20, title: "Off Air"), p("a", 50), p("b", 80), p("d", 110)]
        XCTAssertEqual(LiveSchedule.upcoming(in: programs, now: now, limit: 2).map(\.id), ["a", "b"])
    }

    func test_next_isTheFirstListedProgrammeAfterNow() {
        let programs = [p("later", 60), p("now", -10), p("gap", 20, title: "No Games Scheduled"), p("next", 40)]
        XCTAssertEqual(LiveSchedule.next(in: programs, now: now)?.id, "next")
        XCTAssertNil(LiveSchedule.next(in: [p("now", -10)], now: now))
    }
}
