// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Circular jog on the Siri Remote clickpad ring, ported from UIKit's private
/// `_UIRotaryGestureRecognizer` (the recognizer AVKit scrubs with). Constants
/// were read from its tvOS 26.5 runtime: digitizer space is 0...1 with the centre
/// at 0.5, wheel position runs clockwise from 12 o'clock, and a turn's distance is
/// weighted by 2.5 × the touch's radius (full weight at radius 0.4).
///
/// A touch is classified once: it becomes a jog when it turns far enough before
/// travelling the directional threshold in a straight line, and a swipe otherwise.
/// Feed absolute `GCMicroGamepad` dpad values (-1...1, y up); (0, 0) is a lift.
///
/// Speed is AVKit's (`rotaryGestureDetected:`): each turn moves the scrub needle
/// 100 points per weighted revolution, scaled up with the turn's velocity, along
/// the 1760-point bar that spans the whole title.
struct ClickpadRingJog {
    static let directionalThreshold = 0.15
    /// Degrees of turn, at full weight, that classify a touch as a jog (inferred
    /// from the recognizer's angle-threshold numerator).
    static let angleThresholdDegrees = 15.0
    /// Touches nearer the centre than this never jog.
    static let centreDeadzone = 1.0 / 6.0

    enum Classification: Equatable { case undecided, jog, swipe }

    private(set) var classification = Classification.undecided
    private var start: (x: Double, y: Double)?
    private var lastWheel: Double?
    private var pendingTurn = 0.0
    /// The last few raw wheel moves, for the velocity UIKit averages over.
    private var recent: [(time: Double, delta: Double)] = []
    /// Weighted revolutions per second over the last five samples.
    private(set) var velocity = 0.0

    static let velocitySamples = 5
    /// UIKit floors each sample's interval at 1/66 s; the floor applies to the
    /// whole window here, since GameController may sample faster than that.
    static let minimumSampleInterval = 1.0 / 66
    static let barWidth = 1760.0
    static let pointsPerRevolution = 100.0

    /// Seconds of a `duration`-long title that a weighted `turn` scrubs at `velocity`.
    static func seconds(forTurn turn: Double, velocity: Double, duration: Double) -> Double {
        let speed = abs(velocity)
        // AVKit's gain: 0.75 + v below one revolution a second, easing toward 2.75 above.
        let gain = speed < 1 ? speed + 0.75 : 2.75 - 1 / speed
        return turn * pointsPerRevolution * gain / barWidth * duration
    }

    var isJogging: Bool { classification == .jog }

    /// Where the finger sits on the wheel (clockwise fraction from 12 o'clock),
    /// once the touch is a jog. AVKit's ring dot tracks this, not the scrub.
    var fingerPosition: Double? { isJogging ? lastWheel : nil }

    /// Returns the weighted turn since the last sample in revolutions (clockwise
    /// positive) once the touch is a jog, otherwise nil.
    mutating func feed(x: Float, y: Float, time: Double = 0) -> Double? {
        guard x != 0 || y != 0 else {
            reset()
            return nil
        }
        // GameController reports y up; the digitizer runs y down from the top edge.
        let point = (x: (Double(x) + 1) / 2, y: (1 - Double(y)) / 2)
        let dx = point.x - 0.5, dy = point.y - 0.5
        let radius = (dx * dx + dy * dy).squareRoot()
        let wheel = Self.wheelPosition(dx: dx, dy: dy)
        defer { lastWheel = radius < Self.centreDeadzone ? nil : wheel }

        guard let start else {
            self.start = point
            return nil
        }
        guard classification != .swipe, radius >= Self.centreDeadzone, let lastWheel else { return nil }

        let raw = Self.wrapped(wheel - lastWheel)
        updateVelocity(raw: raw, time: time, weight: 2.5 * radius)
        let turn = raw * 2.5 * radius
        switch classification {
        case .swipe:
            return nil
        case .jog:
            return turn
        case .undecided:
            pendingTurn += turn
            let travelled = ((point.x - start.x) * (point.x - start.x) + (point.y - start.y) * (point.y - start.y)).squareRoot()
            if abs(pendingTurn) * 360 >= Self.angleThresholdDegrees {
                classification = .jog
                return pendingTurn
            }
            if travelled >= Self.directionalThreshold { classification = .swipe }
            return nil
        }
    }

    mutating func reset() {
        classification = .undecided
        start = nil
        lastWheel = nil
        pendingTurn = 0
        recent = []
        velocity = 0
    }

    /// UIKit's rotary velocity: the recent moves over the time they took.
    private mutating func updateVelocity(raw: Double, time: Double, weight: Double) {
        recent.append((time, raw))
        if recent.count > Self.velocitySamples + 1 { recent.removeFirst() }
        guard recent.count > 1, let first = recent.first, let last = recent.last else { return }
        let turned = recent.dropFirst().reduce(0) { $0 + $1.delta }
        velocity = turned / max(last.time - first.time, Self.minimumSampleInterval) * weight
    }

    /// Clockwise fraction of a turn from 12 o'clock, 0..<1.
    static func wheelPosition(dx: Double, dy: Double) -> Double {
        let angle = atan2(dx, -dy) / (2 * .pi)
        return angle < 0 ? angle + 1 : angle
    }

    /// Shortest signed difference between two wheel positions.
    private static func wrapped(_ delta: Double) -> Double {
        delta - delta.rounded()
    }
}
