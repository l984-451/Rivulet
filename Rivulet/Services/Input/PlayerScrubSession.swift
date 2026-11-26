// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The scrub model both players share: shuttle (ShuttleGrammar), swipe, wheel and step
// scrubbing over a time range. The host seeks on commit and owns thumbnails and chrome.

import Foundation
import Combine

@MainActor
final class PlayerScrubSession: ObservableObject {
    @Published private(set) var isScrubbing = false
    @Published private(set) var scrubTime: TimeInterval = 0
    /// -8...8 shuttle level (0 = not shuttling); see ShuttleGrammar.
    @Published private(set) var scrubSpeed: Int = 0
    /// Ring rotation is driving the scrub; clears 0.8 s after the last tick.
    @Published private(set) var wheelScrubbing = false

    var range: () -> ClosedRange<TimeInterval>
    var position: () -> TimeInterval
    /// Fires on every change of `scrubTime` the user caused (thumbnail loads).
    var onScrubTimeChanged: ((TimeInterval) -> Void)?
    /// Fires when a scrub starts (the host stops its controls hide timer).
    var onBegan: (() -> Void)?
    /// A finger resting on the ring keeps the wheel indicator up.
    var holdsWheel: () -> Bool = { false }

    private let updateInterval: TimeInterval
    private let wheelIdleDelay: TimeInterval
    private var shuttleTimer: Timer?
    private var wheelTimer: Timer?

    init(
        range: @escaping () -> ClosedRange<TimeInterval> = { 0...0 },
        position: @escaping () -> TimeInterval = { 0 },
        updateInterval: TimeInterval = 0.1,
        wheelIdleDelay: TimeInterval = 0.8
    ) {
        self.range = range
        self.position = position
        self.updateInterval = updateInterval
        self.wheelIdleDelay = wheelIdleDelay
    }

    deinit {
        shuttleTimer?.invalidate()
        wheelTimer?.invalidate()
    }

    private func clamped(_ time: TimeInterval) -> TimeInterval {
        let r = range()
        return min(max(r.lowerBound, time), r.upperBound)
    }

    private func moved() {
        onScrubTimeChanged?(scrubTime)
    }

    // MARK: - Start

    func start() {
        isScrubbing = true
        scrubTime = position()
        scrubSpeed = 0
        onBegan?()
        moved()
    }

    /// Hold or click on an edge: enter or step the shuttle, with an immediate 10 s jump.
    /// Returns false when the grammar reaches zero; the host then cancels.
    @discardableResult
    func shuttle(forward: Bool) -> Bool {
        let speedBefore = scrubSpeed
        let newSpeed = ShuttleGrammar.step(current: isScrubbing ? scrubSpeed : 0, clickForward: forward)
        if newSpeed == 0 { return false }

        if !isScrubbing {
            isScrubbing = true
            scrubTime = position()
            onBegan?()
            moved()
        }
        // A wheel tick mid-shuttle can zero the speed and stop the timer with isScrubbing
        // still true, so restart it on any 0 -> nonzero step, not only on entry.
        if speedBefore == 0 && newSpeed != 0 {
            startShuttleTimer()
        }
        scrubSpeed = newSpeed

        scrubTime = clamped(scrubTime + (forward ? 10 : -10))
        moved()
        return true
    }

    /// Proportional swipe; takes over from a running shuttle.
    func swipe(by seconds: TimeInterval) {
        if !isScrubbing {
            isScrubbing = true
            scrubTime = position()
            scrubSpeed = 0
            onBegan?()
            moved()
        } else if scrubSpeed != 0 {
            stopShuttleTimer()
            scrubSpeed = 0
        }
        scrubTime = clamped(scrubTime + seconds)
        moved()
    }

    /// Clickpad-ring rotation; `seekDelta` is already converted from the rotation.
    func wheel(by seekDelta: TimeInterval) {
        if !isScrubbing {
            isScrubbing = true
            scrubTime = position()
            scrubSpeed = 0
            onBegan?()
        } else if scrubSpeed != 0 {
            stopShuttleTimer()
            scrubSpeed = 0
        }

        scrubTime = clamped(scrubTime + seekDelta)
        moved()

        wheelScrubbing = true
        startWheelIdleTimer()
    }

    // MARK: - Move

    func jump(to time: TimeInterval) {
        scrubTime = clamped(time)
        moved()
    }

    func step(by seconds: TimeInterval) {
        if !isScrubbing { start() }
        scrubTime = clamped(scrubTime + seconds)
        moved()
    }

    // MARK: - End

    /// Stops the timers and returns where to seek, or nil when not scrubbing. State is
    /// kept so the chrome holds the target until `finish()`.
    func commitTarget() -> TimeInterval? {
        stopShuttleTimer()
        stopWheel()
        return isScrubbing ? scrubTime : nil
    }

    func finish() {
        isScrubbing = false
        scrubSpeed = 0
    }

    /// Stops the timers, clears the state and returns the target to seek to.
    func commit() -> TimeInterval? {
        guard let target = commitTarget() else { return nil }
        finish()
        return target
    }

    func cancel() {
        stopShuttleTimer()
        stopWheel()
        isScrubbing = false
        scrubSpeed = 0
        scrubTime = position()
    }

    func stopWheel() {
        wheelTimer?.invalidate()
        wheelTimer = nil
        wheelScrubbing = false
    }

    // MARK: - Timers

    private func startShuttleTimer() {
        shuttleTimer?.invalidate()
        shuttleTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func stopShuttleTimer() {
        shuttleTimer?.invalidate()
        shuttleTimer = nil
    }

    /// One shuttle step: the level's content-seconds per real-second over one interval.
    func tick() {
        guard isScrubbing, scrubSpeed != 0 else { return }

        let direction: TimeInterval = scrubSpeed > 0 ? 1 : -1
        let secondsPerTick = ShuttleGrammar.rate(forLevel: scrubSpeed) * updateInterval

        scrubTime = clamped(scrubTime + (secondsPerTick * direction))

        let r = range()
        if scrubTime <= r.lowerBound || scrubTime >= r.upperBound {
            scrubSpeed = 0
            stopShuttleTimer()
        }

        moved()
    }

    /// One timer, reset on each rotation tick.
    private func startWheelIdleTimer() {
        wheelTimer?.invalidate()
        wheelTimer = Timer.scheduledTimer(withTimeInterval: wheelIdleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.holdsWheel() { self.startWheelIdleTimer(); return }
                self.wheelScrubbing = false
            }
        }
    }
}
