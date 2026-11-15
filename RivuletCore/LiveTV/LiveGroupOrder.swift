// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Channel group order: the order each source publishes its categories, never alphabetical (#568).
nonisolated enum LiveGroupOrder {
    /// Gives a rank to channels whose source published none: first appearance in its own list.
    static func ranked(_ channels: [UnifiedChannel]) -> [UnifiedChannel] {
        var first: [String: Int] = [:]
        return channels.map { channel in
            guard channel.groupRank == nil, let title = trimmed(channel.groupTitle) else { return channel }
            let rank = first[title] ?? first.count
            first[title] = rank
            return channel.withGroupRank(rank)
        }
    }

    /// Distinct group titles: sources in `sourceOrder`, then each source's own order.
    /// A name in several sources sits at its earliest place; no rank falls back to list position.
    static func titles(in channels: [UnifiedChannel], sourceOrder: [String] = []) -> [String] {
        var best: [String: [Int]] = [:]
        for (position, channel) in channels.enumerated() {
            guard let title = trimmed(channel.groupTitle) else { continue }
            let key = [sourceOrder.firstIndex(of: channel.sourceId) ?? Int.max, channel.groupRank ?? Int.max, position]
            if let old = best[title], old.lexicographicallyPrecedes(key) { continue }
            best[title] = key
        }
        return best.sorted { $0.value.lexicographicallyPrecedes($1.value) }.map(\.key)
    }

    static func trimmed(_ title: String?) -> String? {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}
