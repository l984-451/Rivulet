// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The VOD swipe-to-scrub transfer function (finger travel to playhead
/// seconds): runtime-scaled base rate, a gentle fast-swipe gain capped at 2.5x
/// and at 0.3 s per point, nothing for an unknown runtime.
@MainActor
final class SwipeScrubTransferTests: XCTestCase {

    private let twoHours: TimeInterval = 7_200
    private let oneHour: TimeInterval = 3_600
    /// Below the 800 pt/s onset: travel maps at the base rate.
    private let slowSpeeds: [Double] = [0, 150, 400, 799]

    func test_zeroTravel_movesNothing() {
        for speed in [0.0, 300, 2_000, 9_000] {
            XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: 0, speed: speed, duration: twoHours), 0)
        }
        XCTAssertEqual(SwipeScrubTransfer.baseSeconds(forTravel: 0, duration: twoHours), 0)
    }

    func test_slowTravel_isExactlyProportional_andSignSymmetric() {
        for speed in slowSpeeds {
            let one = SwipeScrubTransfer.seconds(forTravel: 100, speed: speed, duration: twoHours)
            let two = SwipeScrubTransfer.seconds(forTravel: 200, speed: speed, duration: twoHours)
            XCTAssertGreaterThan(one, 0)
            XCTAssertEqual(two, 2 * one, accuracy: 1e-9, "speed \(speed)")
            // Left is backward by the same amount; the speed's sign does not matter.
            let back = SwipeScrubTransfer.seconds(forTravel: -100, speed: -speed, duration: twoHours)
            XCTAssertEqual(back, -one, accuracy: 1e-9, "speed \(speed)")
        }
    }

    func test_slowTravel_coversTheSameShareOfTheBar_on1hAnd2hTitles() {
        for speed in slowSpeeds {
            let shortShare = SwipeScrubTransfer.seconds(forTravel: 200, speed: speed, duration: oneHour) / oneHour
            let longShare = SwipeScrubTransfer.seconds(forTravel: 200, speed: speed, duration: twoHours) / twoHours
            XCTAssertEqual(shortShare, longShare, accuracy: 1e-12, "speed \(speed)")
        }
    }

    func test_twoHourTitle_200ptOfSlowTravel_moves36Seconds() {
        XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: 200, speed: 300, duration: twoHours), 36, accuracy: 1e-9)
        XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: -200, speed: 300, duration: twoHours), -36, accuracy: 1e-9)
    }

    func test_multiplier_isExactlyOne_belowTheOnset() {
        for speed in [0.0, 1, 250, 500, 799, 799.999, 800, -799] {
            XCTAssertEqual(SwipeScrubTransfer.multiplier(speed: speed), 1, "speed \(speed)")
        }
        XCTAssertGreaterThan(SwipeScrubTransfer.multiplier(speed: 900), 1)
    }

    func test_multiplier_neverExceeds2_5_andNeverDecreasesWithSpeed() {
        var previous = SwipeScrubTransfer.multiplier(speed: 0)
        for step in 1...1_200 {
            let speed = Double(step) * 10  // 10 ... 12,000 pt/s
            let gain = SwipeScrubTransfer.multiplier(speed: speed)
            XCTAssertLessThanOrEqual(gain, 2.5, "speed \(speed)")
            XCTAssertGreaterThanOrEqual(gain, previous, "speed \(speed)")
            previous = gain
        }
        XCTAssertEqual(SwipeScrubTransfer.multiplier(speed: 4_000), 2.5, accuracy: 1e-12)
        XCTAssertEqual(SwipeScrubTransfer.multiplier(speed: 50_000), 2.5, accuracy: 1e-12)
    }

    func test_fastTravel_gainsAtMost2_5Times_theSlowRate() {
        // A 1-hour title: 0.09 s/pt slow, 0.225 fast, under the 0.3 ceiling.
        let slow = SwipeScrubTransfer.seconds(forTravel: 120, speed: 300, duration: oneHour)
        let fast = SwipeScrubTransfer.seconds(forTravel: 120, speed: 6_000, duration: oneHour)
        XCTAssertEqual(fast, slow * 2.5, accuracy: 1e-9)
        // A fast leftward swipe (negative velocity) gains exactly as much.
        XCTAssertEqual(SwipeScrubTransfer.multiplier(speed: -6_000), 2.5, accuracy: 1e-12)
        let fastBack = SwipeScrubTransfer.seconds(forTravel: -120, speed: -6_000, duration: oneHour)
        XCTAssertEqual(fastBack, -slow * 2.5, accuracy: 1e-9)
    }

    /// A fast swipe never passes 0.3 s per point, whatever the runtime, and the
    /// ceiling never slows a slow swipe.
    func test_fastTravel_isCappedAt0_3SecondsPerPoint() {
        for duration in [twoHours, 10_800, 14_400] {  // 2 h, 3 h, 4 h
            XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: 400, speed: 6_000, duration: duration), 120, accuracy: 1e-9)
            XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: -400, speed: -6_000, duration: duration), -120, accuracy: 1e-9)
            for speed in stride(from: 0.0, through: 12_000, by: 250) {
                let rate = SwipeScrubTransfer.seconds(forTravel: 1, speed: speed, duration: duration)
                XCTAssertLessThanOrEqual(rate, 0.3 + 1e-12, "duration \(duration) speed \(speed)")
            }
        }
        // 3 h slow travel keeps its full base rate (0.27 s/pt, below the ceiling).
        XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: 100, speed: 300, duration: 10_800), 27, accuracy: 1e-9)
    }

    func test_runtimeScale_isClampedAtBothEnds() {
        // Over 3 h 12 min moves like 3 h 12 min (scale capped at 1.6): 200 * 0.18 * 1.6.
        XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: 200, speed: 300, duration: 14_400), 57.6, accuracy: 1e-9)
        XCTAssertEqual(
            SwipeScrubTransfer.seconds(forTravel: 200, speed: 300, duration: 21_600),
            SwipeScrubTransfer.seconds(forTravel: 200, speed: 300, duration: 14_400),
            accuracy: 1e-12)
        // Under 6 minutes moves like 6 minutes (scale floored at 0.05): 200 * 0.18 * 0.05.
        XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: 200, speed: 300, duration: 180), 1.8, accuracy: 1e-9)
    }

    func test_lockTravel_countsAtTheBaseRate() {
        for travel in [-37.0, 24, 60] {
            XCTAssertEqual(
                SwipeScrubTransfer.baseSeconds(forTravel: travel, duration: twoHours),
                SwipeScrubTransfer.seconds(forTravel: travel, speed: 0, duration: twoHours),
                accuracy: 1e-12)
        }
    }

    func test_invalidDuration_movesNothing() {
        let invalid: [TimeInterval] = [0, -60, .nan, .infinity, -.infinity]
        for duration in invalid {
            XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: 200, speed: 300, duration: duration), 0, "\(duration)")
            XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: 200, speed: 5_000, duration: duration), 0, "\(duration)")
            XCTAssertEqual(SwipeScrubTransfer.baseSeconds(forTravel: 200, duration: duration), 0, "\(duration)")
        }
    }

    func test_nonFiniteInput_neverProducesNaN() {
        XCTAssertEqual(SwipeScrubTransfer.multiplier(speed: .nan), 1)
        XCTAssertEqual(SwipeScrubTransfer.seconds(forTravel: .nan, speed: 300, duration: twoHours), 0)
        XCTAssertEqual(
            SwipeScrubTransfer.seconds(forTravel: 200, speed: .nan, duration: twoHours), 36, accuracy: 1e-9)
    }
}
