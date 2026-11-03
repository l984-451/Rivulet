// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class PressRepeaterTests: XCTestCase {

    func test_begin_stepsOnceAtOnceAndRepeatsOnlyPastTheHoldThreshold() {
        let repeater = PressRepeater()
        var steps = 0
        repeater.begin(interval: 0.05) { steps += 1 }
        XCTAssertEqual(steps, 1, "a tap is one step, with no wait")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: InputConfig.holdThreshold / 2))
        XCTAssertEqual(steps, 1, "nothing repeats before the hold threshold")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: InputConfig.holdThreshold / 2 + 0.25))
        XCTAssertGreaterThanOrEqual(steps, 2, "a held press keeps stepping")

        repeater.end()
        let atRelease = steps
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        XCTAssertEqual(steps, atRelease, "nothing steps after the release")
    }

    func test_begin_replacesAnOpenPress() {
        let repeater = PressRepeater()
        var first = 0
        var second = 0
        repeater.begin(interval: 0.05) { first += 1 }
        repeater.begin(interval: 0.05) { second += 1 }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: InputConfig.holdThreshold + 0.15))
        XCTAssertEqual(first, 1, "the replaced press never repeats")
        XCTAssertGreaterThanOrEqual(second, 2)
        repeater.end()
    }
}
