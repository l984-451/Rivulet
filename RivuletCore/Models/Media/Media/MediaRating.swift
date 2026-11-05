// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaRating.swift
//  Rivulet
//
//  A review score and where it came from. Providers and the ratings worker map
//  their fields in; the About card reads `name` / `badgeText` / `scale`, so the
//  format rules live here only.
//

import Foundation

nonisolated struct MediaRating: Sendable, Hashable {
    /// Declared in About-card display order.
    enum Source: Int, Sendable, Hashable, Comparable, CaseIterable {
        case rottenTomatoes, rottenTomatoesAudience, imdb, metacritic, letterboxd, tmdb, unknown

        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    /// Normalized 0–10. A Rotten Tomatoes 89% is 8.9, a Letterboxd 4.2 is 8.4.
    let value: Double
    let source: Source

    /// Nil for a missing or zero score: Plex, Jellyfin and TMDB all send 0
    /// for "no score yet".
    init?(_ value: Double?, source: Source) {
        // Server-supplied: a NaN or huge value would trap the badge's Int conversion.
        guard let value, value > 0, value <= 100 else { return nil }
        self.value = value
        self.source = source
    }

    /// One score per source in display order; the first of a source wins. An
    /// unnamed score (Jellyfin's community rating) is dropped once IMDb or
    /// TMDB is present, since it is one of those.
    static func ordered(_ ratings: [MediaRating?]) -> [MediaRating] {
        var seen = Set<Source>()
        let unique = ratings.compactMap { $0 }.filter { seen.insert($0.source).inserted }
        let named = seen.contains(.imdb) || seen.contains(.tmdb)
        return unique.filter { !(named && $0.source == .unknown) }.sorted { $0.source < $1.source }
    }

    /// The detail row's one score (Settings > Appearance > Rating); Rotten Tomatoes when the
    /// title lacks the chosen source. The raw value is stored, so 0 (unset) is Rotten Tomatoes.
    static let detailSourceKey = "detailRatingSource"
    static var detailSource: Source {
        Source(rawValue: UserDefaults.standard.integer(forKey: detailSourceKey)) ?? .rottenTomatoes
    }
    static func detailRating(in ratings: [MediaRating]) -> MediaRating? {
        ratings.first { $0.source == detailSource } ?? ratings.first { $0.source == .rottenTomatoes }
    }

    var name: String { source.name }

    /// Each source in its own format: "89%", "73", "4.2", "7.6".
    var badgeText: String {
        switch source {
        case .rottenTomatoes, .rottenTomatoesAudience: "\(Int((value * 10).rounded()))%"
        case .metacritic: "\(Int((value * 10).rounded()))"
        case .letterboxd: String(format: "%.1f", value / 2)
        case .imdb, .tmdb, .unknown: String(format: "%.1f", value)
        }
    }

    /// Who the score is from, for the ratings popup.
    var detailText: String {
        switch source {
        case .rottenTomatoes: String(localized: "Tomatometer, critics")
        case .rottenTomatoesAudience: String(localized: "Popcornmeter, audience")
        case .imdb: String(localized: "IMDb users")
        case .metacritic: String(localized: "Metascore, critics")
        case .letterboxd: String(localized: "Letterboxd members")
        case .tmdb: String(localized: "TMDB users")
        case .unknown: String(localized: "Average rating")
        }
    }

    /// The scale suffix drawn after the score, nil when the score carries its own.
    var scale: String? {
        switch source {
        case .rottenTomatoes, .rottenTomatoesAudience: nil
        case .metacritic: "/100"
        case .letterboxd: "/5"
        case .imdb, .tmdb, .unknown: "/10"
        }
    }
}

nonisolated extension MediaRating.Source {
    var name: String {
        switch self {
        case .rottenTomatoes: "Rotten Tomatoes"
        case .rottenTomatoesAudience: String(localized: "RT Audience")
        case .imdb: "IMDb"
        case .metacritic: "Metacritic"
        case .letterboxd: "Letterboxd"
        case .tmdb: "TMDB"
        case .unknown: String(localized: "Rating")
        }
    }
}
