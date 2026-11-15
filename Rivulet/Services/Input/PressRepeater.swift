// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Auto-repeat for a held arrow press on a focusable control: the action runs
// at once, again after `InputConfig.holdThreshold`, then every `interval` until
// the press ends. The press half of a stepper row (`CardStepperRowView`); a
// touch surface expresses "hold" as repeated swipes instead.

import Foundation

@MainActor
final class PressRepeater {
    private var timer: Timer?
    private var action: (() -> Void)?

    /// Runs `action` now and keeps running it while the press is held. A new
    /// press replaces any open one.
    func begin(interval: TimeInterval, action: @escaping () -> Void) {
        end()
        self.action = action
        action()
        let timer = Timer(fire: Date(timeIntervalSinceNow: InputConfig.holdThreshold),
                          interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.action?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The press let go or cancelled, or its control lost focus.
    func end() {
        timer?.invalidate()
        timer = nil
        action = nil
    }
}
