// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchProfileBuilder.swift
//  Rivulet
//
//  Builds a FeatureProfile (genre/keyword/cast/director weights) from a set of
//  watched items. Shared by PersonalizedRecommendationService (in-library
//  recommendations) and DiscoverRecommendationService (TMDB catalog).
//

import Foundation

struct FeatureProfile {
    var keywords: [String: Double] = [:]
    var genres: [String: Double] = [:]
    var cast: [String: Double] = [:]
    var directors: [String: Double] = [:]

    var maxKeyword: Double { keywords.values.max() ?? 0 }
    var maxGenre: Double { genres.values.max() ?? 0 }
    var maxCast: Double { cast.values.max() ?? 0 }
    var maxDirector: Double { directors.values.max() ?? 0 }

    mutating func add(features: TMDBItemFeatures, weight: Double) {
        for tag in features.keywords {
            keywords[tag, default: 0] += weight
        }
        for tag in features.genres {
            genres[tag, default: 0] += weight
        }
        for name in features.cast {
            cast[name, default: 0] += weight
        }
        for name in features.directors {
            directors[name, default: 0] += weight
        }
    }

    func topGenres(_ n: Int) -> [String] {
        Array(genres.sorted(by: { $0.value > $1.value }).prefix(n).map(\.key))
    }

    func topKeywords(_ n: Int) -> [String] {
        Array(keywords.sorted(by: { $0.value > $1.value }).prefix(n).map(\.key))
    }
}

enum WatchProfileBuilder {

    private static let genreNormalization: [String: String] = [
        "sci-fi": "science fiction",
        "scifi": "science fiction",
        "science-fiction": "science fiction",
        "sci-fi & fantasy": "science fiction",
        "action & adventure": "action",
        "action/adventure": "action",
        "war & politics": "war",
        "tv movie": "drama",
        "news": "documentary",
        "talk": "comedy",
        "reality": "documentary",
        "soap": "drama",
        "kids": "family"
    ]

    /// Build a profile from a set of watched items.
    /// Each item is weighted by recency × rewatch × user rating.
    /// TMDB features are merged when available; absence is fine.
    static func build(from items: [PlexMetadata]) async -> FeatureProfile {
        var profile = FeatureProfile()
        let allFeatures = await buildFeatures(for: items)
        for (item, features) in zip(items, allFeatures) {
            let weight = recencyWeight(lastViewedAt: item.lastViewedAt)
                * rewatchBoost(viewCount: item.viewCount)
                * ratingMultiplier(userRating: item.userRating)
            profile.add(features: features, weight: weight)
        }
        return profile
    }

    /// Features for each item, in input order. TMDB lookups run six at a time.
    static func buildFeatures(for items: [PlexMetadata]) async -> [TMDBItemFeatures] {
        let found = await BoundedFanOut.map(Array(items.enumerated()), width: 6) { index, item in
            (index, await buildFeatures(for: item))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func buildFeatures(for item: PlexMetadata) async -> TMDBItemFeatures {
        func normalize(_ genre: String) -> String {
            let lower = genre.lowercased()
            return genreNormalization[lower] ?? lower
        }

        var features = TMDBItemFeatures(
            keywords: [],
            cast: item.castNames,
            directors: item.directorNames,
            genres: item.genreTags.map(normalize),
            voteAverage: nil,
            voteCount: nil
        )

        if let tmdbId = item.tmdbId {
            if let tmdbFeatures = await TMDBClient.shared.fetchFeatures(tmdbId: tmdbId, type: item.tmdbMediaType) {
                features.merge(from: tmdbFeatures)
            }
        }

        return features.normalized()
    }

    static func recencyWeight(lastViewedAt: Int?) -> Double {
        guard let ts = lastViewedAt else { return 1.0 }
        let days = (Date().timeIntervalSince1970 - Double(ts)) / (60 * 60 * 24)
        switch days {
        case ..<30: return 1.0
        case ..<90: return 0.75
        case ..<180: return 0.5
        case ..<365: return 0.25
        default: return 0.1
        }
    }

    static func rewatchBoost(viewCount: Int?) -> Double {
        let count = Double(viewCount ?? 0)
        if count <= 1 { return 1.0 }
        return log2(count) + 1.0
    }

    /// Rating multiplier for profile building (upstream v2.8.7+)
    /// User's star rating directly weights how much an item influences the profile
    static func ratingMultiplier(userRating: Double?) -> Double {
        guard let rating = userRating, rating > 0 else { return 0.6 }  // Unrated = 0.6x
        switch rating {
        case 9...10: return 1.0    // 5 stars
        case 7..<9: return 0.75    // 4 stars
        case 5..<7: return 0.5     // 3 stars
        case 4..<5: return 0.25    // 2 stars
        default: return 0.6        // Unrated default
        }
    }
}
