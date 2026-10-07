// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ReplayWindowTests.swift
//  RivuletTests
//
//  Pure-logic tests for ReplayWindowLogic, the skip-back subtitle
//  window: subtitles temporarily on after a skip back, then
//  auto-revert once playback passes the point where it was invoked.
//

import XCTest
@testable import Rivulet

final class ReplayWindowTests: XCTestCase {
    func testRevertsWhenPassingInvocationPoint() {
        var window = ReplayWindowLogic(invokedAt: 100, priorSubtitleTrackId: nil)
        window = window.observing(currentTime: 90)
        XCTAssertFalse(window.shouldRevert(currentTime: 90))
        XCTAssertTrue(window.shouldRevert(currentTime: 100.5))
    }

    func testExtendsWindow() {
        var window = ReplayWindowLogic(invokedAt: 100, priorSubtitleTrackId: nil)
        window = window.observing(currentTime: 90)
        window = window.extended(to: 130)
        XCTAssertFalse(window.shouldRevert(currentTime: 110))
        XCTAssertTrue(window.shouldRevert(currentTime: 130.1))
    }

    /// The skip-back seek lands asynchronously (in a Task),
    /// but the window is armed synchronously before that. A stale
    /// time-observer tick at/after invokedAt can fire before the seek
    /// actually lands — that must NOT trigger a revert. Only once playback
    /// has actually been observed *before* invokedAt (i.e. the seek has
    /// landed) should a subsequent pass back over invokedAt revert.
    func testDoesNotRevertBeforeArmed() {
        var window = ReplayWindowLogic(invokedAt: 100, priorSubtitleTrackId: nil)
        // Stale tick at/after invokedAt before the seek lands: no revert.
        XCTAssertFalse(window.shouldRevert(currentTime: 100.5))
        // Once a tick below invokedAt arrives, the window arms...
        window = window.observing(currentTime: 90)
        // ...and reverts when passing the invocation point again.
        XCTAssertTrue(window.shouldRevert(currentTime: 100.5))
    }

    func testReInvokeInsideWindowNeverShrinksIt() {
        var window = ReplayWindowLogic(invokedAt: 100, priorSubtitleTrackId: nil)
        window = window.observing(currentTime: 90)   // armed
        // Re-invoke at 95 (inside the window, before the original point):
        window = window.extended(to: 95)
        // The revert point must remain 100, not shrink to 95.
        XCTAssertFalse(window.shouldRevert(currentTime: 96))
        XCTAssertTrue(window.shouldRevert(currentTime: 100.5))
    }
}
