// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A genre the library's albums carry. `id` is the backend's filter key.
struct MusicGenre: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

/// Server-side sort for library lists. `artist` falls back to title for artists.
enum MusicSort: Sendable, Hashable {
    case title
    case artist
    /// Albums newest first; tracks in that album order.
    case year
    /// Tracks by album title, then track order.
    case album
    case recentlyAdded
    /// Tracks only: albums newest added first, each in track order.
    case albumRecentlyAdded
    /// Tracks only: artists newest added first, each one's albums in track order.
    case artistRecentlyAdded
    /// A fresh random order per request: library-wide shuffle.
    case random
}

/// Server-side filter for library lists, so paging and totals stay correct.
struct MusicFilter: Sendable, Hashable {
    var genreID: String?
    var favoritesOnly = false
}
