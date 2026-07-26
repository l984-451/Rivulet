// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StagedMenuBackTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

// MARK: - Stage-1 policy

final class StagedMenuBackPolicyTests: XCTestCase {

    func testReturnsToTopFromBelowTheTopSection() {
        XCTAssertTrue(StagedMenuBack.shouldReturnToTop(focusedSection: 4, topSection: 0))
    }

    func testPassesThroughAtTheTopSection() {
        XCTAssertFalse(StagedMenuBack.shouldReturnToTop(focusedSection: 0, topSection: 0))
    }

    /// Search has no hero, so its top section is 0; hero pages top out at the
    /// hero's own index.
    func testHonoursANonZeroTopSection() {
        XCTAssertFalse(StagedMenuBack.shouldReturnToTop(focusedSection: 2, topSection: 2))
        XCTAssertTrue(StagedMenuBack.shouldReturnToTop(focusedSection: 3, topSection: 2))
    }

    /// A section above the top (shouldn't happen, but must not consume the
    /// press and strand the user with no way back).
    func testPassesThroughAboveTheTopSection() {
        XCTAssertFalse(StagedMenuBack.shouldReturnToTop(focusedSection: 1, topSection: 2))
    }

    func testPassesThroughWhenNoSectionOwnsFocus() {
        XCTAssertFalse(StagedMenuBack.shouldReturnToTop(focusedSection: nil, topSection: 0))
    }
}

// MARK: - Press-phase swallow state

final class MenuPressSwallowStateTests: XCTestCase {

    /// A consumed press must withhold both its `.began` and its `.ended`, or
    /// the system sees half a press.
    func testWithholdsBothPhasesOfAConsumedPress() {
        var state = MenuPressSwallowState()
        XCTAssertTrue(state.shouldWithhold(began: true, finished: false, handle: { true }))
        XCTAssertTrue(state.isSwallowing)
        XCTAssertTrue(state.shouldWithhold(began: false, finished: true, handle: { true }))
        XCTAssertFalse(state.isSwallowing)
    }

    func testForwardsBothPhasesOfADeclinedPress() {
        var state = MenuPressSwallowState()
        XCTAssertFalse(state.shouldWithhold(began: true, finished: false, handle: { false }))
        XCTAssertFalse(state.isSwallowing)
        XCTAssertFalse(state.shouldWithhold(began: false, finished: true, handle: { false }))
    }

    /// The handler is consulted once per press — on `.began` only. Asking again
    /// on `.ended` would run the scroll twice.
    func testHandlerIsAskedOnlyOnBegan() {
        var state = MenuPressSwallowState()
        var asked = 0
        _ = state.shouldWithhold(began: true, finished: false, handle: { asked += 1; return true })
        _ = state.shouldWithhold(began: false, finished: false, handle: { asked += 1; return true })
        _ = state.shouldWithhold(began: false, finished: true, handle: { asked += 1; return true })
        XCTAssertEqual(asked, 1)
    }

    /// Intermediate phases between began and ended stay withheld.
    func testWithholdsIntermediatePhases() {
        var state = MenuPressSwallowState()
        _ = state.shouldWithhold(began: true, finished: false, handle: { true })
        XCTAssertTrue(state.shouldWithhold(began: false, finished: false, handle: { true }))
        XCTAssertTrue(state.isSwallowing)
    }

    /// A cancelled press ends the swallow just like `.ended` — otherwise the
    /// state latches and every later Menu press is eaten.
    func testCancelledPressClearsTheSwallow() {
        var state = MenuPressSwallowState()
        _ = state.shouldWithhold(began: true, finished: false, handle: { true })
        _ = state.shouldWithhold(began: false, finished: true, handle: { true })
        XCTAssertFalse(state.isSwallowing)
        // Next press is free to be declined and forwarded.
        XCTAssertFalse(state.shouldWithhold(began: true, finished: false, handle: { false }))
    }

    /// A single event carrying both phases must not latch the swallow on.
    func testSingleEventCarryingBothPhasesDoesNotLatch() {
        var state = MenuPressSwallowState()
        XCTAssertTrue(state.shouldWithhold(began: true, finished: true, handle: { true }))
        XCTAssertFalse(state.isSwallowing)
    }

    /// A stray `.ended` with no preceding consumed `.began` must be forwarded,
    /// not eaten.
    func testStrayEndedIsForwarded() {
        var state = MenuPressSwallowState()
        XCTAssertFalse(state.shouldWithhold(began: false, finished: true, handle: { true }))
    }

    /// A second `.began` arriving before the first press ends must not re-ask
    /// the handler or take over the pending press's tracking — the press being
    /// swallowed owns the state until its own terminal phase.
    func testOverlappingBeganDoesNotReAskOrRetrack() {
        var state = MenuPressSwallowState()
        var asked = 0
        XCTAssertTrue(state.shouldWithhold(began: true, finished: false, handle: { asked += 1; return true }))
        // Second press begins while the first is still down.
        XCTAssertTrue(state.shouldWithhold(began: true, finished: false, handle: { asked += 1; return true }))
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(state.isSwallowing)
        // The original press's terminal phase still ends the swallow.
        XCTAssertTrue(state.shouldWithhold(began: false, finished: true, handle: { true }))
        XCTAssertFalse(state.isSwallowing)
    }

    /// The declined case must stay re-askable: no swallow is pending, so a
    /// following `.began` is a fresh decision.
    func testBeganAfterADeclinedPressIsAskedAgain() {
        var state = MenuPressSwallowState()
        var asked = 0
        XCTAssertFalse(state.shouldWithhold(began: true, finished: false, handle: { asked += 1; return false }))
        XCTAssertFalse(state.shouldWithhold(began: true, finished: false, handle: { asked += 1; return false }))
        XCTAssertEqual(asked, 2)
    }
}
