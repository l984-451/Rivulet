// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

@MainActor
final class PlaybackReportQueue {
    private(set) var tail: Task<Void, Never>?

    @discardableResult
    func enqueue(_ report: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            await report()
        }
        tail = task
        return task
    }
}
