// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveBehindLiveTests.swift
//  RivuletTests
//
//  When the live player counts as behind live (the Go Live button, the badge,
//  the LIVE chip). A stream drifting a few seconds behind is still live, and
//  the verdict must not flip back and forth around one threshold, because the
//  button moving in and out shifts the whole rail.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveBehindLiveTests: XCTestCase {
    private typealias VC = LiveTVAetherPlayerViewController

    func test_aFewSecondsBehind_isStillLive() {
        XCTAssertFalse(VC.isBehindLive(behindSeconds: 10, wasBehind: false))
        XCTAssertFalse(VC.isBehindLive(behindSeconds: 29, wasBehind: false))
    }

    func test_halfAMinuteBehind_isBehind() {
        XCTAssertTrue(VC.isBehindLive(behindSeconds: 30, wasBehind: false))
    }

    /// Once behind, it takes getting close to the edge again to count as live,
    /// so a stream hovering near 30s does not bounce.
    func test_hysteresis() {
        XCTAssertTrue(VC.isBehindLive(behindSeconds: 20, wasBehind: true))
        XCTAssertFalse(VC.isBehindLive(behindSeconds: 9, wasBehind: true))
    }
}
