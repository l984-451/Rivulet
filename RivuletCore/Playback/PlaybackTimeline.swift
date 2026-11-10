// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// When a player tells its server where it is, for every app and server. A session opens with
/// `playing` (#433), reports each 10 s of playback, repeats `paused` every 10 s so the server can
/// end a paused session (#403), and says nothing once it has stopped or the server ended it (#605),
/// until `begin()` or a fresh `playing`.
@MainActor
final class PlaybackTimeline {
    enum State: String, Sendable { case playing, paused, stopped }
    enum Transport { case playing, paused, other }

    /// Captures the item when called; the returned send gives the server's reason when it has ended the session.
    typealias Report = (State, TimeInterval) -> @MainActor () async -> String?

    var onTerminated: ((String) -> Void)?
    private(set) var isStopped = false

    private let interval: TimeInterval
    private let position: () -> TimeInterval
    private let report: Report
    private var transport = Transport.other
    private var hasPlayed = false
    private var lastBucket: Int?
    private var generation = 0
    private var keepalive: Task<Void, Never>?

    init(interval: TimeInterval = 10, position: @escaping () -> TimeInterval, report: @escaping Report) {
        self.interval = interval
        self.position = position
        self.report = report
    }

    /// A new play session (the next item, or a reload): it opens again and must start with `playing`.
    func begin() {
        generation += 1
        cancelKeepalive()
        hasPlayed = false
        isStopped = false
        lastBucket = nil
    }

    func transportChanged(_ new: Transport) {
        cancelKeepalive()
        transport = new
        switch new {
        case .playing:
            hasPlayed = true
            // Sought back into an ended item and carried on.
            isStopped = false
            send(.playing, at: position())
        case .paused:
            guard hasPlayed else { return }
            send(.paused, at: position())
            keepalive = Task { [weak self, interval] in
                while true {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled, let self else { return }
                    self.send(.paused, at: self.position())
                }
            }
        case .other:
            break
        }
    }

    /// The playhead moved: one report per `interval` of it, and after a seek.
    func tick(_ time: TimeInterval) {
        guard transport != .other, let current = bucket(time), current != lastBucket else { return }
        if transport == .playing { hasPlayed = true }
        guard hasPlayed else { return }
        send(transport == .playing ? .playing : .paused, at: time)
    }

    /// Reports `stopped` and goes quiet. Nil when the session had already stopped.
    @discardableResult
    func stop(at time: TimeInterval) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        close()
        let op = report(.stopped, time)
        return Task { _ = await op() }
    }

    private func send(_ state: State, at time: TimeInterval) {
        guard !isStopped else { return }
        lastBucket = bucket(time)
        let op = report(state, time)
        let generation = generation
        Task { [weak self] in
            guard let reason = await op(), let self, generation == self.generation, !self.isStopped else { return }
            self.close()
            self.onTerminated?(reason)
        }
    }

    private func close() {
        isStopped = true
        cancelKeepalive()
    }

    private func cancelKeepalive() {
        keepalive?.cancel()
        keepalive = nil
    }

    private func bucket(_ time: TimeInterval) -> Int? { time.isFinite ? Int((time / interval).rounded(.down)) : nil }
}
