// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Which way a remote-surface touch is going, from its cumulative translation, for the VOD
// swipe-to-scrub pan. A diagonal start stays undecided.

import Foundation

nonisolated struct SwipeScrubAxisLock {

    enum Axis: Equatable { case undecided, horizontal, vertical }

    /// Travel on the winning axis before the touch commits, as Live TV's.
    static let lockDistance: Double = 24
    /// x must dominate y 2:1 for a scrub, the old velocity test's ratio.
    static let horizontalDominance: Double = 2
    /// Looser than horizontal on purpose: locking vertical only protects.
    static let verticalDominance: Double = 1.5

    /// Sticky once decided; `reset()` starts the next touch.
    private(set) var axis: Axis = .undecided

    /// Feeds the cumulative translation since the touch began (points, y down)
    /// and returns the axis, which never changes again once decided.
    @discardableResult
    mutating func update(translationX: Double, translationY: Double) -> Axis {
        guard axis == .undecided else { return axis }
        axis = Self.classify(translationX: translationX, translationY: translationY)
        return axis
    }

    mutating func reset() {
        axis = .undecided
    }

    /// The axis a cumulative translation alone points to, or undecided.
    static func classify(translationX: Double, translationY: Double) -> Axis {
        let x = abs(translationX), y = abs(translationY)
        if x >= lockDistance && x >= horizontalDominance * y { return .horizontal }
        if y >= lockDistance && y >= verticalDominance * x { return .vertical }
        return .undecided
    }
}
