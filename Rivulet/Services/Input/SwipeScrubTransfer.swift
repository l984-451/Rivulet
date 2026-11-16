// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SwipeScrubTransfer.swift
//  Rivulet
//
//  The VOD swipe-to-scrub transfer function, from finger travel on the touch
//  surface to seconds on the playhead. It replaces a flat 0.5 s per point (a
//  2-hour title crossed in a short swipe) and the post-lift "flick" (a jump not
//  tied to finger travel). Built on the Live TV timeline scrub's pieces
//  (`LiveTimelineScrub.Tuning`, `LiveTimelineScrub.accelerationMultiplier`):
//  the base rate scales with the runtime, so a swipe covers the same share of
//  the bar whatever the title's length, and a fast swipe gains a little, less
//  than on Live TV, since precision is the point here. Kept free of UIKit so it
//  is testable; `PlayerContainerViewController` feeds it pan samples. Main-actor
//  isolated like the Live TV pieces it reuses.
//

import Foundation

enum SwipeScrubTransfer {

    // The `[scrub] swipe ended` diagnostics line logs each scrub's travel, peak
    // speed and seconds, to tune these numbers from real swipes.

    /// Seconds per point of slow travel on a 2-hour title (`referenceDuration`);
    /// other runtimes scale from it. 0.18 is the Live TV scrub's base rate.
    static let baseSecondsPerPointAtReference: Double = 0.18
    /// Swipe speed (points/sec) below which travel maps 1:1 at the base rate.
    static let accelOnsetSpeed: Double = 800
    /// Swipe speed at which the gain reaches `maxAccelMultiplier`.
    static let accelSaturationSpeed: Double = 4_000
    /// The most a fast swipe multiplies the base rate by.
    static let maxAccelMultiplier: Double = 2.5
    /// A hard ceiling on a fast swipe's rate, in seconds per point, whatever the
    /// runtime. Without it a fast swipe on a long film (a base rate up to 0.288,
    /// times 2.5) would travel about as far as the old flat 0.5 s/pt. It never
    /// slows the base rate (at most 0.288).
    static let maxSecondsPerPoint: Double = 0.3

    /// The runtime the base rate is quoted for, and how far the runtime scale is
    /// clamped either side of it (Live TV's range): under 6 minutes moves like
    /// 6 minutes, over 3 h 12 min like 3 h 12 min.
    static let referenceDuration: TimeInterval = 7_200
    static let minDurationScale: Double = 0.05
    static let maxDurationScale: Double = 1.6

    /// The scrub tuning for a title of `duration` seconds. A missing or invalid
    /// runtime (0, negative, NaN, infinite) gets a base rate of 0: no movement.
    static func tuning(duration: TimeInterval) -> LiveTimelineScrub.Tuning {
        let base: Double
        if duration.isFinite, duration > 0 {
            let scale = min(max(duration / referenceDuration, minDurationScale), maxDurationScale)
            base = baseSecondsPerPointAtReference * scale
        } else {
            base = 0
        }
        return LiveTimelineScrub.Tuning(
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
        return LiveTimelineScrub.accelerationMultiplier(
            speed: magnitude, tuning: tuning(duration: referenceDuration))
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
