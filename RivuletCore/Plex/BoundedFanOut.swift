// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Runs one request per element, at most `width` in flight. PMS builds library hubs on demand, and
/// twenty at once timed out together at 30s, taking every later request to the server with them (#474).
nonisolated enum BoundedFanOut {
    static let libraryRequests = 4

    /// Results in completion order.
    static func map<Element: Sendable, Result: Sendable>(
        _ elements: [Element], width: Int = libraryRequests,
        _ body: @escaping @Sendable (Element) async -> Result
    ) async -> [Result] {
        await withTaskGroup(of: Result.self) { group in
            var results: [Result] = []
            var running = 0
            for element in elements {
                if running >= width, let result = await group.next() {
                    results.append(result)
                    running -= 1
                }
                group.addTask { await body(element) }
                running += 1
            }
            for await result in group { results.append(result) }
            return results
        }
    }
}
