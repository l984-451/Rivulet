// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchTogetherPlayerAdapter.swift
//  Rivulet
//
//  How the room reads and drives the player, on either platform.
//

import Combine
import Foundation
import OpenWatchParty

/// What the room needs from a platform's player. All of it goes straight to the
/// player, past the press funnel that sends the user's presses to the room.
@MainActor
protocol WatchTogetherPlayer: AnyObject {
    var syncPosition: TimeInterval { get }
    var syncDuration: TimeInterval { get }
    var syncIntendsToPlay: Bool { get }
    var syncIsBuffering: Bool { get }
    var syncHasFrame: Bool { get }
    func syncPlay()
    func syncPause()
    func syncSetRate(_ rate: Float)
    /// Seeks and returns where it landed, or nil when it gave up or was replaced.
    func syncSeek(to time: TimeInterval) async -> TimeInterval?
}

/// One seek's progress, as a player's engine reports it.
nonisolated enum WatchTogetherSeekOutcome: Sendable {
    case began
    case landed(TimeInterval)
    case gaveUp
}

/// Runs `seek` and returns where it landed, or nil. `seek` alone only says the engine accepted
/// it. Subscribes first, or a quick landing is missed. A seek that never began (the engine
/// refused it) must not hold the room's next command for the full wait.
@MainActor
func watchTogetherLanding(of outcomes: AnyPublisher<WatchTogetherSeekOutcome, Never>,
                          seek: @escaping @MainActor () async -> Void) async -> TimeInterval? {
    final class Wait {
        var began = false
        var continuation: CheckedContinuation<TimeInterval?, Never>?
        func finish(_ landed: TimeInterval?) {
            continuation?.resume(returning: landed)
            continuation = nil
        }
    }
    let wait = Wait()
    var subscription: AnyCancellable?
    let landed = await withCheckedContinuation { continuation in
        wait.continuation = continuation
        subscription = outcomes.sink { outcome in
            switch outcome {
            case .began: wait.began = true
            case .landed(let time): wait.finish(time)
            case .gaveUp: wait.finish(nil)
            }
        }
        Task { @MainActor in
            await seek()
            try? await Task.sleep(for: .seconds(1))
            if !wait.began { return wait.finish(nil) }
            try? await Task.sleep(for: .seconds(10))
            wait.finish(nil)
        }
    }
    subscription?.cancel()
    return landed
}

@MainActor
final class WatchTogetherPlayerAdapter: PlayerAdapter {
    private weak var player: (any WatchTogetherPlayer)?
    /// How far recent seeks landed from their target. Keeps a keyframe-only source
    /// from seeking forever at a target it can't hit: the SDK nudges inside this.
    private var landingErrors: [Int64] = []
    /// What the SDK asked for: its ±4% nudge above 350 ms of drift, otherwise the room's rate.
    private var roomRate = 1.0
    private var trim = 1.0
    private var isSeeking = false
    private var trimTask: Task<Void, Never>?

    init(player: any WatchTogetherPlayer) {
        self.player = player
    }

    /// The engine starts about 300 ms after the room says go, and the SDK leaves anything
    /// under 350 ms alone, so two devices could rest 700 ms apart. This holds the rest tight.
    func startTrimming(drift: @escaping @MainActor () -> Int64?) {
        trimTask?.cancel()
        trimTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let measured = !self.paused && !self.buffering && !self.isSeeking && self.roomRate == 1 ? drift() : nil
                let next = Self.trimRate(drift: measured, current: self.trim)
                if next != self.trim {
                    self.trim = next
                    self.applyRate()
                }
            }
        }
    }

    func stopTrimming() {
        trimTask?.cancel()
        trimTask = nil
        trim = 1
        applyRate()
    }

    private func applyRate() {
        player?.syncSetRate(Float(roomRate * trim))
    }

    /// 2% is inaudible with the engine's pitch-preserving stretch. Starts past 100 ms,
    /// stops inside 40 ms, and hands anything the SDK corrects itself back to it.
    nonisolated static func trimRate(drift: Int64?, current: Double) -> Double {
        guard let drift, abs(drift) <= 350 else { return 1 }
        if abs(drift) < 40 { return 1 }
        if current == 1, abs(drift) < 100 { return 1 }
        return drift > 0 ? 0.98 : 1.02
    }

    var positionMs: Int64 { Int64((player?.syncPosition ?? 0) * 1000) }
    var durationMs: Int64? {
        guard let duration = player?.syncDuration, duration > 0 else { return nil }
        return Int64(duration * 1000)
    }
    var paused: Bool { !(player?.syncIntendsToPlay ?? false) }
    var buffering: Bool { player?.syncIsBuffering ?? false }
    var firstFrameShown: Bool { player?.syncHasFrame ?? false }
    var canSetRate: Bool { player != nil }
    var seekAccuracyMs: Int64 { Self.accuracy(from: landingErrors) }

    func play() async throws { player?.syncPlay() }
    func pause() async throws { player?.syncPause() }
    func setRate(_ rate: Double) async throws {
        roomRate = rate
        applyRate()
    }

    func seek(to positionMs: Int64) async throws {
        guard let player else { return }
        let target = TimeInterval(positionMs) / 1000
        isSeeking = true
        defer { isSeeking = false }
        guard let landed = await player.syncSeek(to: target) else { return }
        landingErrors = Array((landingErrors + [Int64(abs(landed - target) * 1000)]).suffix(3))
    }

    /// The worst of the last few landings, capped: a bad reading must not switch corrections off.
    nonisolated static func accuracy(from errors: [Int64]) -> Int64 {
        min(errors.max() ?? 0, 8000)
    }
}
