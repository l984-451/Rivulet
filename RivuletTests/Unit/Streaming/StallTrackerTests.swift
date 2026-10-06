// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class StallTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_secondStallWithinWindow_stepsDown() {
        var tracker = StallTracker()
        XCTAssertEqual(tracker.bufferingStarted(at: t0), .counted)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 30), .stepDown)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 40), .counted)   // reset after a step
    }

    func test_stallsOutsideWindow_doNotStepDown() {
        var tracker = StallTracker()
        _ = tracker.bufferingStarted(at: t0)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 61), .counted)
    }

    func test_seekAndLoadGrace_ignored() {
        var tracker = StallTracker()
        tracker.noteSeekOrLoad(at: t0)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 1), .ignored)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 4.9), .ignored)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 6), .counted)
        tracker.noteSeekOrLoad(at: t0 + 10)
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 11), .ignored)   // two seeks never step down
    }

    func test_longStall() {
        let tracker = StallTracker()
        XCTAssertFalse(tracker.isLongStall(startedAt: t0, now: t0 + 9))
        XCTAssertTrue(tracker.isLongStall(startedAt: t0, now: t0 + 10))
    }

    func test_longStallStepDown_clearsCount() {
        var tracker = StallTracker()
        XCTAssertEqual(tracker.bufferingStarted(at: t0), .counted)
        tracker.noteStepDown()   // the long stall stepped down
        XCTAssertEqual(tracker.bufferingStarted(at: t0 + 25), .counted)
    }
}
