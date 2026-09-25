// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DirectionalPressDetector.swift
//  Rivulet
//
//  One tap-vs-hold state machine for a Left/Right directional input slot: a
//  quick release fires a tap, holding past `InputConfig.holdThreshold` fires a
//  hold instead. Shared by every input source that delivers seek/scrub as a
//  discrete begin/end pair — `PlayerContainerViewController`'s content-state
//  presses, `ScrubberFocusProxyView` (the focused-scrubber `UIPress` path), and
//  `RemoteInputHandler` (GameController d-pad / keyboard arrows, for the hosts
//  that still listen to those) each hand-rolled an identical Timer before this
//  existed, and the duplication is exactly what made the seek-drop bug hard to
//  pin down — a fix to one copy's edge case silently left the others unfixed.
//

import Foundation

@MainActor
final class DirectionalPressDetector {
    private var timer: Timer?
    private var forward: Bool?
    private var holdFired = false

    /// Fires once, `InputConfig.holdThreshold` after `begin(forward:)`, if
    /// `end`/`cancel` hasn't already happened.
    var onHold: ((Bool) -> Void)?
    /// Fires from `end()` when the release beat the hold threshold — the
    /// forward direction of the tap that just completed.
    var onTap: ((Bool) -> Void)?

    /// Starts the tap-vs-hold window for a press in `forward`'s direction.
    /// Replaces any window already in progress on this instance (a new
    /// press always supersedes a stale one — matches the pre-extraction
    /// `holdTimer?.invalidate()` behavior at both call sites).
    func begin(forward: Bool) {
        self.forward = forward
        holdFired = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: InputConfig.holdThreshold, repeats: false) { [weak self] _ in
            // `assumeIsolated`, NOT `Task { @MainActor }`: the hold must mark
            // itself fired SYNCHRONOUSLY. `begin` is @MainActor, so the timer
            // is scheduled on the main run loop and this closure genuinely
            // fires on the main thread — the assumption is sound. With an
            // async hop instead, a release landing between the timer firing
            // and the hop running would see `holdFired == false` and emit a
            // tap, and then the queued hold would ALSO fire: one press
            // producing both a skip and a shuttle nudge.
            MainActor.assumeIsolated {
                guard let self, let forward = self.forward else { return }
                self.holdFired = true
                self.onHold?(forward)
            }
        }
    }

    /// Ends the in-progress press. Does nothing if the hold already fired
    /// (that press already committed to a hold action) or if there is no
    /// press in progress. `tapOverride`, when non-nil, replaces the default
    /// `onTap(forward)` call — used by callers (keyboard's Shift-modified
    /// arrow) that need a different action for the same tap.
    func end(tapOverride: (() -> Void)? = nil) {
        timer?.invalidate()
        timer = nil
        defer { forward = nil; holdFired = false }
        guard !holdFired, let forward else { return }
        if let tapOverride {
            tapOverride()
        } else {
            onTap?(forward)
        }
    }

    /// Discards the in-progress press without firing a tap (system
    /// interruption — `pressesCancelled`).
    func cancel() {
        timer?.invalidate()
        timer = nil
        forward = nil
        holdFired = false
    }
}
