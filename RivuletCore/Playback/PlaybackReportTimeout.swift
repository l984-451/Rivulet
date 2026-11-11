// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

enum PlaybackReportTimeout {
    nonisolated static let duration: Duration = .seconds(5)

    // Cleanup must survive cancellation of the report that precedes it, but remain bounded and awaited.
    static func cleanup(for duration: Duration = duration,
                        operation: @escaping @Sendable () async throws -> Void) async {
        await Task {
            try? await run(for: duration, operation: operation)
        }.value
    }

    // A final report gets one fresh deadline even when the caller cancelled its first attempt.
    static func finalReport(for duration: Duration = duration,
                            operation: @escaping @Sendable () async throws -> Void) async {
        do { try await run(for: duration, operation: operation) }
        catch {
            await Task {
                try? await run(for: duration, operation: operation)
            }.value
        }
    }

    // Cancels at the deadline, then awaits cooperative completion. Stop cleanup has its own deadline.
    static func run<Value: Sendable>(for duration: Duration = duration,
                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
