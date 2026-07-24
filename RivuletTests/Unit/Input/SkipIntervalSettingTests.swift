// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SkipIntervalSettingTests.swift
//  RivuletTests
//
//  The Skip Length setting (#233): the SkipInterval enum, and the wiring from
//  the `skipSeconds` default through InputConfig.tapSeekSeconds into an actual
//  coalesced seek.
//

import XCTest
@testable import Rivulet

@MainActor
final class SkipIntervalSettingTests: XCTestCase {

    private let key = SkipInterval.storageKey
    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: Enum integrity

    func testSkipIntervalOptionsAreNumberedGlyphMagnitudes() {
        XCTAssertEqual(SkipInterval.allCases.map(\.rawValue), [5, 10, 15, 30])
    }

    func testSkipIntervalDescriptionRendersSeconds() {
        XCTAssertEqual(SkipInterval.tenSeconds.description, "10 seconds")
        XCTAssertEqual(SkipInterval.thirtySeconds.description, "30 seconds")
    }

    // MARK: InputConfig wiring

    func testTapSeekSecondsDefaultsToThirtyWhenUnset() {
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertEqual(InputConfig.tapSeekSeconds, 30, accuracy: 0.0001)
    }

    func testTapSeekSecondsReflectsStoredSetting() {
        UserDefaults.standard.set(SkipInterval.tenSeconds.rawValue, forKey: key)
        XCTAssertEqual(InputConfig.tapSeekSeconds, 10, accuracy: 0.0001)
    }

    // MARK: End-to-end through the input coordinator

    func testStepSeekUsesConfiguredSkipLength() {
        UserDefaults.standard.set(SkipInterval.fifteenSeconds.rawValue, forKey: key)

        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        coordinator.target = target

        coordinator.handle(action: .stepSeek(forward: true), source: .siriMicroGamepad)

        // The coalesce timer fires on the main run loop; spin it until the
        // seek is dispatched rather than betting on a fixed deadline.
        let deadline = Date().addingTimeInterval(InputConfig.seekCoalesceInterval + 2.0)
        while target.received.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(target.received.count, 1)
        guard case .seekRelative(let seconds) = target.received.first?.0 else {
            return XCTFail("Expected a coalesced seekRelative action")
        }
        XCTAssertEqual(seconds, 15, accuracy: 0.0001)
    }

    // MARK: Helpers

    private final class MockTarget: PlaybackInputTarget {
        var isScrubbingForInput = false
        private(set) var received: [(PlaybackInputAction, PlaybackInputSource)] = []

        func handleInputAction(_ action: PlaybackInputAction, source: PlaybackInputSource) {
            received.append((action, source))
        }
    }
}
