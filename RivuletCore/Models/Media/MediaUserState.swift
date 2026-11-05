// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaUserState.swift
//  Rivulet
//
//  Per-user playback/library state for a media item.
//

import Foundation

struct MediaUserState: Hashable, Sendable, Codable {
    let isPlayed: Bool
    let viewOffset: TimeInterval     // seconds; 0 if not started
    let isFavorite: Bool             // Plex starred / Jellyfin favorite
    var lastViewedAt: Date?
}
