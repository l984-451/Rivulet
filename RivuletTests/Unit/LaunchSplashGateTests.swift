// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  LaunchSplashGateTests.swift
//  RivuletTests
//
//  When the iOS and Mac launch splash leaves (`LaunchSplashGate.decide`).
//

import XCTest
@testable import Rivulet

final class LaunchSplashGateTests: XCTestCase {

    /// Signed in, still loading, hero on and not yet drawn.
    private let loading = LaunchSplashGate.Signals(hasServers: true, needsProfile: false, hasContent: false,
                                                   hasError: false, loadEnded: false, heroEnabled: true,
                                                   heroReady: false)

    @MainActor
    private func decide(_ change: (inout LaunchSplashGate.Signals) -> Void) -> LaunchSplashGate.Decision {
        var signals = loading
        change(&signals)
        return LaunchSplashGate.decide(signals)
    }

    @MainActor
    func test_waitsWhileHomeLoads() {
        XCTAssertEqual(decide { _ in }, .wait)
    }

    @MainActor
    func test_leavesAtOnceWithNothingToLoad() {
        XCTAssertEqual(decide { $0.hasServers = false }, .finish)
    }

    @MainActor
    func test_leavesForTheProfilePicker() {
        XCTAssertEqual(decide { $0.needsProfile = true }, .finish)
    }

    @MainActor
    func test_leavesOnAnError() {
        XCTAssertEqual(decide { $0.hasError = true }, .finish)
    }

    @MainActor
    func test_leavesWhenALoadComesBackEmpty() {
        XCTAssertEqual(decide { $0.loadEnded = true }, .finish)
    }

    @MainActor
    func test_rowsWaitForTheHero() {
        XCTAssertEqual(decide { $0.hasContent = true }, .waitForHero)
        XCTAssertEqual(decide { $0.hasContent = true; $0.loadEnded = true }, .waitForHero)
    }

    @MainActor
    func test_rowsAndHeroLeave() {
        XCTAssertEqual(decide { $0.hasContent = true; $0.heroReady = true }, .finish)
    }

    @MainActor
    func test_rowsLeaveWithTheHeroOff() {
        XCTAssertEqual(decide { $0.hasContent = true; $0.heroEnabled = false }, .finish)
    }

    @MainActor
    func test_heroAloneDoesNotLeave() {
        XCTAssertEqual(decide { $0.heroReady = true }, .wait)
    }
}
