// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A passing note over the player, for all three apps: a title, an optional line of detail, and an SF Symbol.
nonisolated struct PlaybackNotice: Equatable, Sendable {
    let title: String
    var detail: String?
    var symbol: String = "info.circle"
}
