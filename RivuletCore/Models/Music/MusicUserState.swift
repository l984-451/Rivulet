// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicUserState.swift
//  Rivulet
//
//  Per-user state for any music entity (artist/album/track). Parallel to
//  MediaUserState but carries music-specific fields (userRating, lastPlayedAt).
//

import Foundation

struct MusicUserState: Hashable, Sendable {
    let isFavorite: Bool
    let userRating: Double?     // 0.0–5.0 normalized; nil = unrated
    let playCount: Int
    let lastPlayedAt: Date?

    static let empty = MusicUserState(
        isFavorite: false, userRating: nil, playCount: 0, lastPlayedAt: nil
    )
}
