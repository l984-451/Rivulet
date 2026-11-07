// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

/// Per-launch budget for handled errors. A failure that repeats in a session (a retry
/// loop, a dead server) used to send an event every time and spent the month's quota.
nonisolated struct SentryThrottle {
    private var counts: [String: Int] = [:]
    private var total = 0
    let maxTotal: Int

    init(maxTotal: Int = 30) { self.maxTotal = maxTotal }

    mutating func admit(_ key: String, limit: Int = 1) -> Bool {
        guard total < maxTotal, counts[key, default: 0] < limit else { return false }
        counts[key, default: 0] += 1
        total += 1
        return true
    }

    /// Type plus description: the same failure on another item still differs by its message.
    static func key(for error: Error) -> String {
        "\(String(reflecting: type(of: error)))|\(String(describing: error).prefix(200))"
    }
}
