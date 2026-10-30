// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import os

nonisolated enum SiloPlaybackSessionEvent: Sendable {
    case renewalRequired(SiloAPIError)
    case ended(SiloAPIError)
}

/// A native session owns its observers. Its last fault is replayed to a late
/// player subscriber, including a fault received while the source was loading.
nonisolated final class SiloPlaybackSessionEvents: Sendable {
    private struct State: Sendable {
        var event: SiloPlaybackSessionEvent?
        var observers: [UUID: AsyncStream<SiloPlaybackSessionEvent>.Continuation] = [:]
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var pending: SiloPlaybackSessionEvent? { state.withLock { $0.event } }

    func stream() -> AsyncStream<SiloPlaybackSessionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { value in
                if let event = value.event { continuation.yield(event) }
                if value.finished { continuation.finish() }
                else { value.observers[id] = continuation }
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.observers.removeValue(forKey: id) }
            }
        }
    }

    @discardableResult
    func publish(_ event: SiloPlaybackSessionEvent) -> Bool {
        state.withLock { value in
            guard !value.finished else { return false }
            if value.event != nil {
                guard case .ended = event else { return false }
                if case .some(.ended) = value.event { return false }
            }
            value.event = event
            for observer in value.observers.values { observer.yield(event) }
            return true
        }
    }

    func finish() {
        let observers = state.withLock { value in
            guard !value.finished else { return [:] as [UUID: AsyncStream<SiloPlaybackSessionEvent>.Continuation] }
            value.finished = true
            let observers = value.observers
            value.observers = [:]
            return observers
        }
        // finish invokes onTermination synchronously; it must not re-enter our lock.
        for observer in observers.values { observer.finish() }
    }
}

nonisolated enum SiloPlaybackSessionFault {
    static func classify(_ problem: SiloAPIError) -> SiloPlaybackSessionEvent? {
        switch (problem.status, problem.code) {
        case (404, "playback_session_not_found"), (404, "session_not_found"), (404, "not_found"):
            return .renewalRequired(problem)
        case (409, "installation_changed"):
            return .renewalRequired(problem)
        case (410, "playback_session_ended"):
            return .ended(problem)
        default: return nil
        }
    }

    static func classifyMedia(_ problem: SiloAPIError) -> SiloPlaybackSessionEvent? {
        guard (problem.status == 404 && problem.code == "playback_session_not_found") ||
              (problem.status == 409 && problem.code == "installation_changed") ||
              (problem.status == 410 && problem.code == "playback_session_ended") else { return nil }
        return classify(problem)
    }
}

extension SiloProvider {
    func playbackSessionEvents(for current: StreamInfo) async -> AsyncStream<SiloPlaybackSessionEvent> {
        guard let sessionID = current.playSessionID,
              let context = playbackSessions.withLock({ $0[sessionID] }),
              context.ref.providerID == id, context.fileID == current.source.id,
              context.lifetime.isActive else {
            return AsyncStream { $0.finish() }
        }
        return context.lifetime.events.stream()
    }
}
