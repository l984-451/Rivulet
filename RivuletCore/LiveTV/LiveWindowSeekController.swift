// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveWindowSeekController.swift
//  Rivulet
//
//  Seeking through a live stream's own rewind window.
//
//  Presses stack: each step measures from the last REQUESTED place, not from
//  a playhead still on its way there, and the stacked target is sent to the
//  player once the presses settle. One player seek runs at a time; a target
//  that moves while one is landing is picked up by that same worker. AVPlayer
//  cancelling its segment loads for every superseded seek is what takes a
//  live item down under a held button. A target at the edge becomes Go Live,
//  which follows the edge as it moves instead of landing where it was.
//

import Foundation

@MainActor
final class LiveWindowSeekController {

    /// The player half, as closures so tests can drive it without an engine.
    struct Player {
        /// The stream's advertised window, on the axis `position` and `seek` use.
        var window: () -> LiveSeekableWindow?
        var position: () -> TimeInterval
        var seek: (TimeInterval) async -> Void
        var seekToLiveEdge: () async -> Void
        var play: () -> Void
        /// The viewer paused on purpose; a seek must not resume them.
        var isUserPaused: () -> Bool
        /// Seconds a skip may go past the window's lower and upper bounds: a session that
        /// joined behind live (Start from Beginning) is still fetching toward its head.
        var reach: () -> (before: TimeInterval, after: TimeInterval) = { (0, 0) }
    }

    enum Request: Equatable {
        case liveEdge
        case position(TimeInterval)
    }

    /// One remote press through the window.
    static let step: TimeInterval = 10
    /// How long presses must settle before the stacked seek goes to the player.
    static let commitDelay: Duration = .milliseconds(450)

    /// Fires when the staged target or time-shift state changes, so the
    /// timeline can redraw at once rather than on its next tick.
    var onChange: (() -> Void)?

    private(set) var pendingRequest: Request?
    /// The viewer paused or rewound: being behind live is their doing until
    /// they come back to it.
    private(set) var timeShifted = false

    private var player: Player?
    private var commitTask: Task<Void, Never>?
    private var activeSeekID: UUID?
    /// Presses made while a seek lands, applied from where it landed.
    private var carriedDelta: TimeInterval = 0

    /// A seek is landing; presses meanwhile are held for it, not sent to the player.
    var isLanding: Bool { activeSeekID != nil }
    /// Bumped on every attach/reset so a seek from a torn-down session never
    /// writes into the next one.
    private var generation = 0

    func attach(_ player: Player) {
        reset()
        self.player = player
    }

    func reset() {
        generation &+= 1
        commitTask?.cancel()
        commitTask = nil
        activeSeekID = nil
        carriedDelta = 0
        pendingRequest = nil
        timeShifted = false
        player = nil
    }

    /// The window the player offers. Whether one is deep enough to seek is
    /// the player's call (`AetherPlayer.liveTimeshift` drops a direct-HLS
    /// window no deeper than its live holdback).
    var window: LiveSeekableWindow? {
        guard let window = player?.window(), window.duration > 0 else { return nil }
        return window
    }

    /// Drops a staged seek without detaching (Go Live, a pause-and-scrub).
    func cancelPending() {
        commitTask?.cancel()
        commitTask = nil
        pendingRequest = nil
        onChange?()
    }

    /// Seconds behind live, as the timeline should draw it: the staged press
    /// wins over the playhead still travelling there.
    func behindLiveSeconds(in window: LiveSeekableWindow) -> TimeInterval {
        switch pendingRequest {
        case .liveEdge:
            return 0
        case .position(let target):
            return max(0, window.upperBound - target)
        case nil:
            return max(0, window.upperBound - (player?.position() ?? window.upperBound))
        }
    }

    /// Whether the LIVE badge should read as behind. Back at the edge by any
    /// route (a seek, Go Live, or simply catching up) ends the time shift.
    func isBehindLive(in window: LiveSeekableWindow) -> Bool {
        let behind = behindLiveSeconds(in: window)
        if timeShifted, pendingRequest == nil, player?.isUserPaused() != true,
           behind <= LiveSeekableWindow.liveEdgeTolerance {
            timeShifted = false
        }
        return LiveSeekableWindow.isBehindLive(behind, timeShifted: timeShifted)
    }

    /// The viewer paused: from here on, falling behind is their time shift.
    func notePaused() {
        guard window != nil else { return }
        timeShifted = true
        onChange?()
    }

    /// Step through the window by a signed number of seconds.
    func step(by delta: TimeInterval) {
        guard let player else { return }
        // While a seek lands (a recording can reload onto a new axis), hold the press for it.
        if activeSeekID != nil { carriedDelta += delta; return }
        guard let window else { return }
        let base: TimeInterval
        switch pendingRequest {
        case .liveEdge: base = window.upperBound
        case .position(let target): base = target
        case nil: base = player.position()
        }
        stage(base + delta, in: window)
    }

    /// Land `seconds` behind the live edge.
    func seek(behindLive seconds: TimeInterval) {
        guard let window else { return }
        stage(window.upperBound - max(0, seconds), in: window)
    }

    /// A resume after a long pause must land inside the window: the oldest
    /// segments the pause sat on may have been evicted meanwhile.
    func clampResumeIntoWindow() {
        guard let window, let player, pendingRequest == nil else { return }
        if player.position() < window.seekTarget(window.lowerBound) {
            stage(window.lowerBound, in: window)
        }
    }

    /// Where `requested` lands: in the window, or in the reach the player offers past it.
    /// The far end of the forward reach is the live edge itself.
    private func landing(_ requested: TimeInterval, in window: LiveSeekableWindow) -> (target: TimeInterval, atLive: Bool) {
        let reach: (before: TimeInterval, after: TimeInterval) = player?.reach() ?? (0, 0)
        if reach.after > 0 {
            let head = window.upperBound + reach.after
            if requested >= head { return (head, true) }
            if requested > window.upperBound { return (requested, false) }
        }
        if reach.before > 0, requested < window.seekTarget(window.lowerBound) {
            return (max(requested, window.lowerBound - reach.before), false)
        }
        let target = window.seekTarget(requested)
        return (target, reach.after == 0 && window.isAtLiveEdge(target))
    }

    private func stage(_ requested: TimeInterval, in window: LiveSeekableWindow) {
        let (target, atLive) = landing(requested, in: window)
        pendingRequest = atLive ? .liveEdge : .position(target)
        timeShifted = !atLive
        onChange?()
        commitTask?.cancel()
        let generation = generation
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.commitDelay)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.commitTask = nil
            await self.commit(generation: generation)
        }
    }

    private func commit(generation: Int) async {
        // A seek already landing drains this target when it finishes.
        guard generation == self.generation, activeSeekID == nil, let player else { return }
        let owner = UUID()
        activeSeekID = owner
        defer { if activeSeekID == owner { activeSeekID = nil } }
        while let request = pendingRequest {
            let resume = !player.isUserPaused()
            switch request {
            case .liveEdge:
                await player.seekToLiveEdge()
            case .position(let target):
                // Re-clamp against the window as it is now: it slid while the presses settled.
                guard let window = player.window() else { pendingRequest = nil; return }
                await player.seek(landing(target, in: window).target)
            }
            guard generation == self.generation, activeSeekID == owner else { return }
            if pendingRequest == request { pendingRequest = nil }
            if resume { player.play() }
            onChange?()
            // A newer target still settling will commit through its own task.
            if commitTask != nil { return }
        }
        // A reload lands on a new axis whose window takes a moment to appear: presses wait for it.
        for _ in 0..<25 where window == nil {
            try? await Task.sleep(for: .milliseconds(200))
            guard generation == self.generation, activeSeekID == owner else { return }
        }
        let carried = carriedDelta
        carriedDelta = 0
        activeSeekID = nil
        if carried != 0 { step(by: carried) }
    }
}
