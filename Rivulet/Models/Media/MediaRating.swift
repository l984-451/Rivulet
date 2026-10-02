// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaRating.swift
//  Rivulet
//
//  The one score a detail page shows, and where it came from. Each provider
//  maps its own fields in through `preferred(critic:audience:)`; every render
//  site reads `badgeText` / `summary`, so the format rules live here only.
//

import Foundation

nonisolated struct MediaRating: Sendable, Hashable {
    enum Source: Sendable, Hashable {
        case rottenTomatoes, imdb, tmdb, unknown
    }

    /// Normalized 0–10. A Rotten Tomatoes 89% is 8.9.
    let value: Double
    let source: Source

    /// Nil for a missing or zero score: Plex, Jellyfin and TMDB all send 0
    /// for "no score yet".
    init?(_ value: Double?, source: Source) {
        guard let value, value > 0 else { return nil }
        self.value = value
        self.source = source
    }

    /// The critic score when there is one, else the audience score. A server
    /// only has a critic score when its admin picked a ratings source that
    /// has critics, so this follows that choice.
    static func preferred(critic: MediaRating?, audience: MediaRating?) -> MediaRating? {
        critic ?? audience
    }

    /// "89%" for Rotten Tomatoes, "7.6" for everything else.
    var badgeText: String {
        source == .rottenTomatoes
            ? "\(Int((value * 10).rounded()))%"
            : String(format: "%.1f", value)
    }

    /// Star glyph beside the badge. A percent with a star reads as an average.
    var showsStar: Bool { source != .rottenTomatoes }

    /// Prose form for text that describes the score.
    var summary: String {
        switch source {
        case .rottenTomatoes: "\(badgeText) on Rotten Tomatoes"
        case .imdb: "\(badgeText) on IMDb"
        case .tmdb: "\(badgeText) on TMDB"
        case .unknown: "\(badgeText) / 10 average rating"
        }
    }
}
