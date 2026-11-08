// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// #556: the floating skip pill goes 5 seconds after it appears, and comes back
/// when the controls close or a new marker starts.
final class SkipPillPresenceTests: XCTestCase {
    func test_aMarkerShowsThePillAndItsWindowTimesOut() {
        var pill = SkipPillPresence()
        XCTAssertFalse(pill.isShowing)
        XCTAssertTrue(pill.track("intro-1"))
        XCTAssertTrue(pill.isShowing)
        pill.timeOut(window: pill.window, held: false)
        XCTAssertFalse(pill.isShowing)
    }

    func test_theSameMarkerDoesNotOpenAnotherWindow() {
        var pill = SkipPillPresence()
        pill.track("intro-1")
        pill.timeOut(window: pill.window, held: false)
        XCTAssertFalse(pill.track("intro-1"), "a clock tick inside the marker")
        XCTAssertFalse(pill.isShowing)
    }

    func test_aStaleTimerCannotCloseALaterWindow() {
        var pill = SkipPillPresence()
        pill.track("intro-1")
        let first = pill.window
        pill.reveal()
        pill.timeOut(window: first, held: false)
        XCTAssertTrue(pill.isShowing)
    }

    func test_aRunningCountdownHoldsThePill() {
        var pill = SkipPillPresence()
        pill.track("credits-7")
        pill.timeOut(window: pill.window, held: true)
        XCTAssertTrue(pill.isShowing)
    }

    func test_closingTheControlsShowsItAgain() {
        var pill = SkipPillPresence()
        pill.track("intro-1")
        pill.timeOut(window: pill.window, held: false)
        XCTAssertTrue(pill.reveal())
        XCTAssertTrue(pill.isShowing)
    }

    func test_leavingAndReenteringTheMarkerShowsItAgain() {
        var pill = SkipPillPresence()
        pill.track("intro-1")
        pill.timeOut(window: pill.window, held: false)
        pill.track(nil)
        XCTAssertFalse(pill.isShowing)
        XCTAssertTrue(pill.track("intro-1"), "seeked back into the marker")
        XCTAssertTrue(pill.isShowing)
    }

    func test_theNextMarkerShowsItAgain() {
        var pill = SkipPillPresence()
        pill.track("credits-7")
        pill.timeOut(window: pill.window, held: false)
        XCTAssertTrue(pill.track("upNext"))
        XCTAssertTrue(pill.isShowing)
    }

    func test_revealWithoutAMarkerDoesNothing() {
        var pill = SkipPillPresence()
        XCTAssertFalse(pill.reveal())
        XCTAssertFalse(pill.isShowing)
    }

    // MARK: - The 5 seconds count from when the pill appears

    func test_theCountStartsWhenThePillAppears_notWhenItsMarkerStarts() {
        var pill = SkipPillPresence()
        pill.track("intro-1")
        XCTAssertEqual(pill.syncTimer(), .none, "still loading: nothing on screen to time")
        pill.setCanAppear(true)
        XCTAssertEqual(pill.syncTimer(), .start(window: pill.window))
        XCTAssertEqual(pill.syncTimer(), .none, "already counting this window")
    }

    func test_leavingTheScreenStopsTheCount_andComingBackCountsAfresh() {
        var pill = SkipPillPresence()
        pill.setCanAppear(true)
        pill.track("intro-1")
        XCTAssertEqual(pill.syncTimer(), .start(window: pill.window))
        pill.setCanAppear(false)
        XCTAssertEqual(pill.syncTimer(), .stop, "paused, or the controls came up")
        pill.setCanAppear(true)
        XCTAssertEqual(pill.syncTimer(), .start(window: pill.window))
    }

    func test_closingTheControlsCountsANewWindowOnceThePillIsBack() {
        var pill = SkipPillPresence()
        pill.track("intro-1")
        pill.timeOut(window: pill.window, held: false)
        XCTAssertTrue(pill.reveal(), "controls closed")
        XCTAssertEqual(pill.syncTimer(), .none, "the controls are still fading out")
        pill.setCanAppear(true)
        XCTAssertEqual(pill.syncTimer(), .start(window: pill.window))
    }

    func test_aHeldTimeOutCountsAgain() {
        var pill = SkipPillPresence()
        pill.setCanAppear(true)
        pill.track("credits-7")
        XCTAssertEqual(pill.syncTimer(), .start(window: pill.window))
        pill.timeOut(window: pill.window, held: true)
        XCTAssertTrue(pill.isShowing)
        XCTAssertEqual(pill.syncTimer(), .start(window: pill.window), "the countdown is still running")
    }

    func test_aTimedOutPillIsOffScreenAndStopsCounting() {
        var pill = SkipPillPresence()
        pill.setCanAppear(true)
        pill.track("intro-1")
        XCTAssertEqual(pill.syncTimer(), .start(window: pill.window))
        pill.timeOut(window: pill.window, held: false)
        XCTAssertFalse(pill.isOnScreen)
        XCTAssertEqual(pill.syncTimer(), .none)
    }

    func test_aHostDismissalStopsTheCount() {
        var pill = SkipPillPresence()
        pill.setCanAppear(true)
        pill.track("intro-1")
        XCTAssertEqual(pill.syncTimer(), .start(window: pill.window))
        pill.setCanAppear(false)
        XCTAssertEqual(pill.syncTimer(), .stop, "Menu put it away")
    }
}
