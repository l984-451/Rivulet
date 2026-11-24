// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveGroupDisplay.swift
//  Rivulet
//
//  Channel group names as the viewer reads them: an IPTV list's leading tags
//  ("| NL | ", "┃PPV┃ ") left out, as on channel names, and a flag for where the
//  group is from in their place ("🇳🇱 NEDERLAND HD", `ContentOrigin`). Two groups
//  that would still read the same keep their full names. Display only: a group
//  is still matched, pinned and sorted by its own title.
//

import Foundation

nonisolated enum LiveGroupDisplay {
    /// The display name of each title, by title.
    static func names(_ titles: [String]) -> [String: String] {
        let cleaned = Dictionary(titles.map { ($0, ContentOrigin.marked($0)) }, uniquingKeysWith: { first, _ in first })
        var users: [String: Int] = [:]
        for name in cleaned.values { users[name, default: 0] += 1 }
        return cleaned.mapValues { $0 }.reduce(into: [:]) { result, entry in
            result[entry.key] = users[entry.value] == 1 ? entry.value : entry.key
        }
    }

    /// One group alone, with nothing to tell it from: always without its tags.
    static func name(_ title: String) -> String { ContentOrigin.marked(title) }
}
