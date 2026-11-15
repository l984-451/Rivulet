// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class LiveTimelineScrubTests: XCTestCase {
    func testHorizontalSwipePreviewsAndCommitsOnLift() throws {
        var scrub = LiveTimelineScrub()
        scrub.begin(behindLive: 0)
        // Below the axis lock: nothing previews yet.
        scrub.change(translationX: -10, translationY: 0, speed: 100, windowSeconds: 3_600)
        XCTAssertNil(scrub.behindLive)
        // Left swipe: back into the window.
        scrub.change(translationX: -40, translationY: 2, speed: 100, windowSeconds: 3_600)
        scrub.change(translationX: -240, translationY: 4, speed: 100, windowSeconds: 3_600)
        let preview = try XCTUnwrap(scrub.behindLive)
        XCTAssertGreaterThan(preview, 0)
        XCTAssertEqual(scrub.end(), preview)
        XCTAssertNil(scrub.behindLive)
    }

    func testVerticalSwipeNeverScrubs() {
        var scrub = LiveTimelineScrub()
        scrub.begin(behindLive: 30)
        scrub.change(translationX: 5, translationY: 60, speed: 100, windowSeconds: 3_600)
        scrub.change(translationX: 200, translationY: 80, speed: 100, windowSeconds: 3_600)
        XCTAssertNil(scrub.behindLive)
        XCTAssertNil(scrub.end())
    }

    func testScrubStaysInsideTheWindow() throws {
        var scrub = LiveTimelineScrub()
        scrub.begin(behindLive: 50)
        scrub.change(translationX: -30, translationY: 0, speed: 5_000, windowSeconds: 60)
        scrub.change(translationX: -3_000, translationY: 0, speed: 5_000, windowSeconds: 60)
        XCTAssertEqual(try XCTUnwrap(scrub.behindLive), 60)
        scrub.change(translationX: 6_000, translationY: 0, speed: 5_000, windowSeconds: 60)
        XCTAssertEqual(try XCTUnwrap(scrub.behindLive), 0)
    }

    func testAccelerationEasesFromOneToTheCeiling() {
        let tuning = LiveTimelineScrub.tuning(windowSeconds: 3_600)
        XCTAssertEqual(LiveTimelineScrub.accelerationMultiplier(speed: 100, tuning: tuning), 1)
        XCTAssertEqual(LiveTimelineScrub.accelerationMultiplier(speed: 10_000, tuning: tuning), 5)
        let mid = LiveTimelineScrub.accelerationMultiplier(speed: 2_000, tuning: tuning)
        XCTAssertGreaterThan(mid, 1)
        XCTAssertLessThan(mid, 5)
    }
}
