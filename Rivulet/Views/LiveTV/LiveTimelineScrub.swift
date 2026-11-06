// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTimelineScrub.swift
//  Rivulet
//
//  A horizontal swipe on the remote's touch surface through a live channel's
//  rewind window: the playhead follows the finger and the seek is made once,
//  where the scrub is confirmed. Kept free of UIKit so the axis lock and the
//  seconds mapping are testable; `LiveTimelineScrubPan` feeds it pan samples.
//

import Foundation

struct LiveTimelineScrub {
    /// Seconds behind live the scrub is showing; nil when not scrubbing.
    private(set) var behindLive: TimeInterval?
    private var startBehind: TimeInterval = 0
    private var lastTranslationX: Double = 0
    private var axis: Axis = .undecided

    enum Axis { case undecided, horizontal, vertical }

    /// Travel before the swipe commits to an axis, so a vertical swipe to the
    /// rail never nudges the playhead on its way.
    static let axisLockDistance: Double = 24

    mutating func begin(behindLive current: TimeInterval) {
        startBehind = max(0, current)
        lastTranslationX = 0
        axis = .undecided
        behindLive = nil
    }

    /// One pan sample. Right moves toward live (less behind).
    mutating func change(
        translationX: Double, translationY: Double, speed: Double, windowSeconds: TimeInterval
    ) {
        if axis == .undecided {
            guard max(abs(translationX), abs(translationY)) >= Self.axisLockDistance else { return }
            axis = abs(translationX) > abs(translationY) * 1.2 ? .horizontal : .vertical
            if axis == .horizontal {
                behindLive = startBehind
                lastTranslationX = translationX
            }
        }
        guard axis == .horizontal, let current = behindLive else { return }
        let dx = translationX - lastTranslationX
        lastTranslationX = translationX
        let tuning = Self.tuning(windowSeconds: windowSeconds)
        let delta = dx * tuning.baseSecondsPerPoint * Self.accelerationMultiplier(speed: speed, tuning: tuning)
        behindLive = min(max(current - delta, 0), max(0, windowSeconds))
    }

    /// The scrub's landing, or nil if the swipe never became one.
    mutating func end() -> TimeInterval? {
        defer { behindLive = nil; axis = .undecided }
        return behindLive
    }

    mutating func cancel() {
        behindLive = nil
        axis = .undecided
    }

    struct Tuning: Equatable {
        /// Seconds per point of pad travel below the acceleration onset.
        var baseSecondsPerPoint: Double
        /// Pan speed (points/sec) below which travel stays 1:1.
        var accelOnsetSpeed: Double
        /// Pan speed at which the gain reaches `maxAccelMultiplier`.
        var accelSaturationSpeed: Double
        /// Kept modest: a fast flick is quick but still controllable.
        var maxAccelMultiplier: Double
    }

    /// VOD's transfer function, scaled to the window rather than a runtime, so a
    /// swipe covers the same share of the bar whatever the window's depth.
    static func tuning(windowSeconds: TimeInterval) -> Tuning {
        let scale = min(max(windowSeconds / 7_200, 0.05), 1.6)
        return Tuning(
            baseSecondsPerPoint: 0.18 * scale,
            accelOnsetSpeed: 500,
            accelSaturationSpeed: 3_500,
            maxAccelMultiplier: 5
        )
    }

    /// Always ≥ 1: a smoothstep from 1 at the onset to the ceiling at
    /// saturation, so a flick eases in and out rather than snapping on and
    /// clipping at the cap.
    static func accelerationMultiplier(speed: Double, tuning: Tuning) -> Double {
        let lo = tuning.accelOnsetSpeed
        let hi = max(lo + 1, tuning.accelSaturationSpeed)
        let t = min(max((speed - lo) / (hi - lo), 0), 1)
        let smooth = t * t * (3 - 2 * t)
        return 1 + (tuning.maxAccelMultiplier - 1) * smooth
    }
}
