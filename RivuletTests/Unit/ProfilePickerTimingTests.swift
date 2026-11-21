// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// A cold launch asks who is watching whenever the Profile Picker is on;
/// the timer decides only for coming back to Rivulet.
@MainActor
final class ProfilePickerTimingTests: XCTestCase {

    private let manager = PlexUserProfileManager.shared
    private let leftAppAtKey = "profilePickerLeftAppAt"
    private var savedAfter: TimeInterval?
    private var savedLeftAt: Any?

    override func setUp() async throws {
        savedAfter = manager.profilePickerAfter
        savedLeftAt = UserDefaults.standard.object(forKey: leftAppAtKey)
    }

    override func tearDown() async throws {
        manager.profilePickerAfter = savedAfter
        UserDefaults.standard.set(savedLeftAt, forKey: leftAppAtKey)
    }

    func test_coldLaunch_asksForEveryChoiceButOff_evenJustAfterLeaving() {
        let now = Date()
        manager.noteLeftApp(at: now.addingTimeInterval(-5))
        for after in PlexUserProfileManager.profilePickerChoices {
            manager.profilePickerAfter = after
            XCTAssertEqual(manager.shouldAskWhoIsWatchingAtLaunch, after != nil, "choice \(String(describing: after))")
        }
    }

    func test_return_asksOnlyOnceAwayForTheChosenTime() {
        let now = Date()
        manager.profilePickerAfter = 30
        manager.noteLeftApp(at: now.addingTimeInterval(-5))
        XCTAssertFalse(manager.shouldAskWhoIsWatching(now: now))
        manager.noteLeftApp(at: now.addingTimeInterval(-30))
        XCTAssertTrue(manager.shouldAskWhoIsWatching(now: now))
    }

    func test_off_neverAsks() {
        manager.profilePickerAfter = nil
        manager.noteLeftApp(at: Date.distantPast)
        XCTAssertFalse(manager.shouldAskWhoIsWatchingAtLaunch)
        XCTAssertFalse(manager.shouldAskWhoIsWatching())
    }
}
