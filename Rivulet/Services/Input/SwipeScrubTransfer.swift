// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// VOD swipe-to-scrub: finger travel to playhead seconds, scaled to the runtime so a swipe
// covers the same share of the bar on any title, with a modest gain for a fast swipe.

import Foundation

enum SwipeScrubTransfer {

    struct Tuning: Equatable {
        /// Seconds per point of pad travel below the acceleration onset.
        var baseSecondsPerPoint: Double
        /// Pan speed (points/sec) below which travel stays 1:1.
        var accelOnsetSpeed: Double
        /// Pan speed at which the gain reaches `maxAccelMultiplier`.
        var accelSaturationSpeed: Double
        var maxAccelMultiplier: Double
    }

    /// Always >= 1: a smoothstep from 1 at the onset to the ceiling at saturation, so a
    /// flick eases in and out rather than snapping on and clipping at the cap.
    static func accelerationMultiplier(speed: Double, tuning: Tuning) -> Double {
        let lo = tuning.accelOnsetSpeed
        let hi = max(lo + 1, tuning.accelSaturationSpeed)
        let t = min(max((speed - lo) / (hi - lo), 0), 1)
        let smooth = t * t * (3 - 2 * t)
        return 1 + (tuning.maxAccelMultiplier - 1) * smooth
    }

    /// Seconds per point of slow travel on a 2-hour title (`referenceDuration`);
    /// other runtimes scale from it.
    static let baseSecondsPerPointAtReference: Double = 0.18
    /// Swipe speed (points/sec) below which travel maps 1:1 at the base rate.
    static let accelOnsetSpeed: Double = 800
    /// Swipe speed at which the gain reaches `maxAccelMultiplier`.
    static let accelSaturationSpeed: Double = 4_000
    /// The most a fast swipe multiplies the base rate by.
    static let maxAccelMultiplier: Double = 2.5
    /// Ceiling on a fast swipe's rate; never below the base rate.
    static let maxSecondsPerPoint: Double = 0.3

    /// The runtime the base rate is quoted for, and the scale's clamp (Live TV's range).
    static let referenceDuration: TimeInterval = 7_200
    static let minDurationScale: Double = 0.05
    static let maxDurationScale: Double = 1.6

    /// The scrub tuning for a title of `duration` seconds. A missing or invalid
    /// runtime (0, negative, NaN, infinite) gets a base rate of 0: no movement.
    static func tuning(duration: TimeInterval) -> Tuning {
        let base: Double
        if duration.isFinite, duration > 0 {
            let scale = min(max(duration / referenceDuration, minDurationScale), maxDurationScale)
            base = baseSecondsPerPointAtReference * scale
        } else {
            base = 0
        }
        return Tuning(
            baseSecondsPerPoint: base,
            accelOnsetSpeed: accelOnsetSpeed,
            accelSaturationSpeed: accelSaturationSpeed,
            maxAccelMultiplier: maxAccelMultiplier
        )
    }

    /// The fast-swipe gain at `speed` points/sec (either sign): exactly 1 below
    /// the onset, easing up to `maxAccelMultiplier` at saturation.
    static func multiplier(speed: Double) -> Double {
        let magnitude = speed.isFinite ? abs(speed) : 0
        return accelerationMultiplier(speed: magnitude, tuning: tuning(duration: referenceDuration))
    }

    /// Seconds for `dx` points of travel (positive = right = forward) made at
    /// `speed` points/sec, on a title of `duration` seconds. The fast-swipe gain
    /// stops at `maxSecondsPerPoint`; the base rate is never reduced.
    static func seconds(forTravel dx: Double, speed: Double, duration: TimeInterval) -> Double {
        guard dx.isFinite else { return 0 }
        let base = tuning(duration: duration).baseSecondsPerPoint
        guard base > 0 else { return 0 }
        let rate = min(base * multiplier(speed: speed), max(base, maxSecondsPerPoint))
        return dx * rate
    }

    /// Seconds for `dx` points at the base rate (no fast-swipe gain), for the
    /// travel that decided the axis lock: it counts in full, never boosted.
    static func baseSeconds(forTravel dx: Double, duration: TimeInterval) -> Double {
        guard dx.isFinite else { return 0 }
        return dx * tuning(duration: duration).baseSecondsPerPoint
    }
}
