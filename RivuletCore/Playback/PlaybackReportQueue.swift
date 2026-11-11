// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

@MainActor
final class PlaybackReportQueue {
    @MainActor final class Session {
        var isRevoked = false
    }

    private(set) var session = Session()
    private(set) var tail: Task<Void, Never>?

    func beginSession() { session = Session() }

    @discardableResult
    func enqueue(_ report: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail, session = session
        let task = Task {
            await previous?.value
            guard !session.isRevoked else { return }
            await report()
        }
        tail = task
        return task
    }
}
