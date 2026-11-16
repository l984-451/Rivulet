// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SwipeScrubAxisLock.swift
//  Rivulet
//
//  Which way a touch on the remote's surface is going, for the VOD
//  swipe-to-scrub pan. The pan only observes (it never cancels the focus
//  engine's move or the content anchor's swipes), so it must not act until the
//  touch has clearly picked an axis. Decided from the cumulative translation
//  since the touch began, never from one velocity sample: a vertical swipe whose
//  first samples leaned sideways used to start a scrub. Live TV's timeline scrub
//  keeps its own, looser lock (`LiveTimelineScrub`: 1.2:1, decided at once); this
//  one keeps VOD's existing 2:1 rule and leaves a diagonal start undecided. Kept
//  free of UIKit so it is testable; `PlayerContainerViewController` feeds it pan
//  samples.
//

import Foundation

nonisolated struct SwipeScrubAxisLock {

    enum Axis: Equatable { case undecided, horizontal, vertical }

    /// Travel on the winning axis before the touch commits to it, as the Live TV
    /// timeline scrub's `LiveTimelineScrub.axisLockDistance`.
    static let lockDistance: Double = 24
    /// How far x must dominate y for a scrub: 2:1, the ratio the old one-shot
    /// velocity test used, so no swipe that test left to the focus engine becomes
    /// a scrub now. Looser would take Up swipes whose first 24 pt lean 27 to 34
    /// degrees off horizontal.
    static let horizontalDominance: Double = 2
    /// How far y must dominate x to lock vertical, leaving the touch to the focus
    /// engine. Looser than horizontal on purpose, since it only protects. Between
    /// the two (about 27 to 56 degrees off horizontal) nothing is decided.
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
