// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A lineup split into titled sections: favorites first, then each group in
/// the source's own order (#568), then channels with no group. A favorite also
/// stays in its group, as in the guide.
nonisolated enum LiveChannelSections {
    struct Section: Equatable, Sendable {
        /// nil when the lineup has no favorites and no groups: one list, no header.
        let title: String?
        let channels: [UnifiedChannel]
    }

    static func sections(of channels: [UnifiedChannel], favorites: [UnifiedChannel],
                         sourceOrder: [String] = []) -> [Section] {
        var grouped: [String: [UnifiedChannel]] = [:]
        var ungrouped: [UnifiedChannel] = []
        for channel in channels {
            if let title = LiveGroupOrder.trimmed(channel.groupTitle) {
                grouped[title, default: []].append(channel)
            } else {
                ungrouped.append(channel)
            }
        }
        var result: [Section] = []
        if !favorites.isEmpty {
            result.append(Section(title: String(localized: "Favorites"), channels: favorites))
        }
        for title in LiveGroupOrder.titles(in: channels, sourceOrder: sourceOrder) {
            if let members = grouped[title] { result.append(Section(title: title, channels: members)) }
        }
        if !ungrouped.isEmpty {
            result.append(Section(title: result.isEmpty ? nil : String(localized: "Other Channels"),
                                  channels: ungrouped))
        }
        return result
    }
}
