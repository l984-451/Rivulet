// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// One aggregate ledger for a relay's retained variable definitions, inherited
/// contexts, and expanded upstream targets. Temporary parses/registration batches
/// release their lease on failure; committing a batch transfers its charge to
/// the relay without increasing the allocation allowance.
nonisolated final class SiloMediaAllocationBudget: @unchecked Sendable {
    static let defaultLimit = 128 * 1_024 * 1_024
    private let lock = NSLock()
    private let limit: Int
    private var used = 0

    init(limit: Int = defaultLimit) {
        self.limit = max(0, limit)
    }

    func lease() -> Lease { Lease(budget: self) }

    nonisolated final class Lease: @unchecked Sendable {
        fileprivate let budget: SiloMediaAllocationBudget
        // Accessed only under budget.lock; a lease may be consumed only while
        // its owner keeps it alive, so deinit cannot race another consume.
        fileprivate var bytes = 0
        fileprivate init(budget: SiloMediaAllocationBudget) { self.budget = budget }

        func reserve(_ count: Int) throws {
            try budget.lock.withLock {
                guard count >= 0, count <= budget.limit - budget.used else { throw SiloSignInError.invalidResponse }
                budget.used += count
                bytes += count
            }
        }

        func transfer(to destination: Lease) {
            precondition(budget === destination.budget)
            budget.lock.withLock {
                destination.bytes += bytes
                bytes = 0
            }
        }

        func reset() {
            budget.lock.withLock {
                budget.used -= bytes
                bytes = 0
            }
        }

        deinit { reset() }
    }
}
