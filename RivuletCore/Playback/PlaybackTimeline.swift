// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// When a player tells its server where it is, for every app and server. A session opens with
/// `playing` (#433), reports each 10 s of playback, repeats paused and buffering reports every 10 s so the server can
/// end a paused session (#403), and says nothing once it has stopped (until `begin()` or a fresh
/// `playing`) or the server ended it (until `begin()`, #605).
@MainActor
final class PlaybackTimeline {
    enum State: String, Sendable { case playing, paused, buffering, stopped }
    enum Transport { case playing, paused, buffering, other }

    /// Captures the item when called; the returned send gives the server's reason when it has ended the session.
    typealias Report = (State, TimeInterval) -> @MainActor () async -> String?

    var onTerminated: ((String) -> Void)?
    private(set) var isStopped = false

    var heartbeatInterval: Duration
    private let reports: PlaybackReportQueue
    private let interval: TimeInterval
    private let position: () -> TimeInterval
    private let report: Report
    private var transport = Transport.other
    private var hasPlayed = false
    private var lastBucket: Int?
    private var lastPosition: TimeInterval?
    private var keepalive: Task<Void, Never>?

    init(interval: TimeInterval = 10, reports: PlaybackReportQueue? = nil, position: @escaping () -> TimeInterval, report: @escaping Report) {
        self.interval = interval
        self.heartbeatInterval = .seconds(interval)
        self.reports = reports ?? PlaybackReportQueue()
        self.position = position
        self.report = report
    }

    /// A new play session (the next item, or a reload): it opens again and must start with `playing`.
    func begin() {
        reports.beginSession()
        cancelKeepalive()
        hasPlayed = false
        transport = .other
        isStopped = false
        lastBucket = nil
        lastPosition = nil
    }

    func transportChanged(_ new: Transport, hasStarted: Bool = false) {
        guard !reports.session.isRevoked else { return }
        if !isStopped, new == transport, lastPosition == position() { return }
        cancelKeepalive()
        transport = new
        hasPlayed = hasPlayed || hasStarted
        switch new {
        case .playing:
            hasPlayed = true
            isStopped = false
            send(.playing, at: position())
        case .paused, .buffering:
            guard hasPlayed, !isStopped else { return }
            let state: State = new == .paused ? .paused : .buffering
            send(state, at: position())
            keepalive = Task { [weak self, heartbeatInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: heartbeatInterval)
                    guard !Task.isCancelled, let self else { return }
                    await self.send(state, at: self.position())?.value
                }
            }
        case .other:
            break
        }
    }

    /// The playhead moved: one report per `interval` of it, and after a seek.
    func tick(_ time: TimeInterval, force: Bool = false) {
        guard !isStopped, transport != .other, hasPlayed,
              let current = bucket(time), force || current != lastBucket else { return }
        let state: State
        switch transport {
        case .playing: state = .playing
        case .paused: state = .paused
        case .buffering: state = .buffering
        case .other: return
        }
        send(state, at: time)
    }

    /// Reports `stopped` and goes quiet. Nil when the session had already stopped.
    @discardableResult
    func stop(at time: TimeInterval) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        close()
        let op = report(.stopped, time)
        return enqueue(op)
    }

    @discardableResult
    private func send(_ state: State, at time: TimeInterval) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        lastBucket = bucket(time)
        lastPosition = time
        let op = report(state, time)
        return enqueue(op)
    }

    @discardableResult
    func enqueue(_ op: @escaping @MainActor () async -> String?) -> Task<Void, Never> {
        let session = reports.session
        return reports.enqueue { [weak self] in
            guard let reason = await op() else { return }
            session.isRevoked = true
            guard let self, self.reports.session === session else { return }
            self.close()
            self.onTerminated?(reason)
        }
    }

    func close() {
        isStopped = true
        cancelKeepalive()
    }

    private func cancelKeepalive() {
        keepalive?.cancel()
        keepalive = nil
    }

    private func bucket(_ time: TimeInterval) -> Int? { time.isFinite ? Int((time / interval).rounded(.down)) : nil }
}
