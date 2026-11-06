// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ChildProgress.swift
//  Rivulet
//
//  Watch-progress for hierarchical items (show/season). Carries the
//  played/total pair the UI uses for "12/24 watched" displays.
//

import Foundation

nonisolated struct ChildProgress: Hashable, Sendable, Codable {
    let played: Int
    let total: Int
    /// True when only the unplayed count is known (`total` stands for it, `played` is 0), so the pair is not a real "n of m".
    let unplayedOnly: Bool?

    init(played: Int, total: Int, unplayedOnly: Bool? = nil) {
        self.played = played
        self.total = total
        self.unplayedOnly = unplayedOnly
    }
}
