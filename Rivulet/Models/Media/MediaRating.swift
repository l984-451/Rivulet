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

    /// Official awards are not score thresholds. Only an upstream designation
    /// may set these; Silo's current score-only contract cannot supply one.
    enum RottenTomatoesDesignation: Sendable, Hashable {
        case certifiedFresh, verifiedHot
    }

    enum RottenTomatoesStatus: Sendable, Hashable {
        case certifiedFresh, fresh, rotten, verifiedHot, hot, stale

        var imageName: String {
            switch self {
            case .certifiedFresh: "RatingRTCertifiedFresh"
            case .fresh: "RatingRTFresh"
            case .rotten: "RatingRTRotten"
            case .verifiedHot: "RatingRTVerifiedHot"
            case .hot: "RatingRTHot"
            case .stale: "RatingRTStale"
            }
        }

        var name: String {
            switch self {
            case .certifiedFresh: "Certified Fresh"
            case .fresh: "Fresh"
            case .rotten: "Rotten"
            case .verifiedHot: "Verified Hot"
            case .hot: "Hot"
            case .stale: "Stale"
            }
        }
    }

    let rottenTomatoesDesignation: RottenTomatoesDesignation?
    /// Retain the provider's original URI as evidence, including unrecognized
    /// marks. Never infer an award from an arbitrary URI substring.
    let plexRatingImage: String?

    var rottenTomatoesStatus: RottenTomatoesStatus? {
        switch source {
        case .rottenTomatoes:
            if rottenTomatoesDesignation == .certifiedFresh { return .certifiedFresh }
            return value >= 6 ? .fresh : .rotten
        case .rottenTomatoesAudience:
            if rottenTomatoesDesignation == .verifiedHot { return .verifiedHot }
            return value >= 6 ? .hot : .stale
        default:
            return nil
        }
    }

    /// A provider's authoritative mark and formatted score. Keeping its source
    /// identity avoids collapsing unrelated plugin ratings into `.unknown`.
    struct NativeDisplay: Sendable, Hashable {
        let sourceID: String
        let name: String
        let text: String
    }
    let nativeDisplay: NativeDisplay?

    /// Nil for a missing or zero score: Plex, Jellyfin and TMDB all send 0
    /// for "no score yet".
    init?(
        _ value: Double?, source: Source,
        rottenTomatoesDesignation: RottenTomatoesDesignation? = nil,
        plexRatingImage: String? = nil
    ) {
        // Server-supplied: a NaN or huge value would trap the badge's Int conversion.
        guard let value, value > 0, value <= 100 else { return nil }
        self.value = value
        self.source = source
        self.nativeDisplay = nil
        self.rottenTomatoesDesignation = rottenTomatoesDesignation
        self.plexRatingImage = plexRatingImage
    }

    init?(scoreOutOf100: Double, source: Source, sourceID: String, name: String, display: String) {
        guard scoreOutOf100.isFinite, (0...100).contains(scoreOutOf100),
              !sourceID.isEmpty, !name.isEmpty, !display.isEmpty else { return nil }
        self.value = scoreOutOf100 / 10
        self.source = source
        self.nativeDisplay = NativeDisplay(sourceID: sourceID, name: name, text: display)
        self.rottenTomatoesDesignation = nil
        self.plexRatingImage = nil
    }

    /// One score per source in display order; the first of a source wins. An
    /// unnamed score (Jellyfin's community rating) is dropped once IMDb or
    /// TMDB is present, since it is one of those.
    static func ordered(_ ratings: [MediaRating?]) -> [MediaRating] {
        if ratings.contains(where: { $0?.nativeDisplay != nil }) {
            var seen = Set<String>()
            return ratings.compactMap { $0 }.filter {
                seen.insert($0.nativeDisplay?.sourceID ?? "legacy:\($0.source.rawValue)").inserted
            }
        }
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

    var name: String { nativeDisplay?.name ?? source.name }

    /// Each source in its own format: "89%", "73", "4.2", "7.6".
    var badgeText: String {
        if let nativeDisplay { return nativeDisplay.text }
        return switch source {
        case .rottenTomatoes, .rottenTomatoesAudience: "\(Int((value * 10).rounded()))%"
        case .metacritic: "\(Int((value * 10).rounded()))"
        case .letterboxd: String(format: "%.1f", value / 2)
        case .imdb, .tmdb, .unknown: String(format: "%.1f", value)
        }
    }

    /// Who the score is from, for the ratings popup.
    var detailText: String {
        if let nativeDisplay { return nativeDisplay.name }
        return switch source {
        case .rottenTomatoes: "Tomatometer, critics"
        case .rottenTomatoesAudience: "Popcornmeter, audience"
        case .imdb: "IMDb users"
        case .metacritic: "Metascore, critics"
        case .letterboxd: "Letterboxd members"
        case .tmdb: "TMDB users"
        case .unknown: "Average rating"
        }
    }

    /// The scale suffix drawn after the score, nil when the score carries its own.
    var scale: String? {
        if nativeDisplay != nil { return nil } // Native display already carries its own scale.
        return switch source {
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
        case .rottenTomatoesAudience: "RT Audience"
        case .imdb: "IMDb"
        case .metacritic: "Metacritic"
        case .letterboxd: "Letterboxd"
        case .tmdb: "TMDB"
        case .unknown: "Rating"
        }
    }
}
