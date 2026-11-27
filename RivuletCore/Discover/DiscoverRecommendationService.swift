// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DiscoverRecommendationService.swift
//  Rivulet
//
//  Personalized "For You" row on the Discover page. Reuses WatchProfileBuilder
//  to produce a FeatureProfile from watch history, then queries TMDB /discover
//  using the top genres. The page drops titles it already has: tvOS through
//  LibraryGUIDIndex, iOS and Mac through DiscoverOwnership.
//

import Foundation

protocol DiscoverFetching: Sendable {
    func discover(type: TMDBMediaType, withGenres: [Int], withKeywords: [Int]) async -> [TMDBListItem]
}

extension TMDBDiscoverService: DiscoverFetching {}

struct DiscoverRecommendationService {
    /// Minimum watched items required before we try to personalize the "For You"
    /// row. Fewer watches produce noisy recommendations that feel random.
    static let minimumWatched = 5
    static let maxItems = 20

    private let fetcher: DiscoverFetching
    private let coldStartGenreThreshold = 3

    // TODO: Genre normalization in WatchProfileBuilder collapses TV-specific genre
    // labels (war & politics, tv movie, reality, soap, kids, talk) into their
    // closest movie equivalents before they reach the profile. As a result the
    // TV-specific IDs below (10762, 10763, 10764, 10766, 10767, 10768) are
    // currently unreachable through the For You row. Revisit when we track
    // media-type separately in the profile.
    private static let genreNameToId: [String: Int] = [
        "action": 28, "adventure": 12, "animation": 16, "comedy": 35, "crime": 80,
        "documentary": 99, "drama": 18, "family": 10751, "fantasy": 14, "history": 36,
        "horror": 27, "music": 10402, "mystery": 9648, "romance": 10749,
        "science fiction": 878, "tv movie": 10770, "thriller": 53, "war": 10752,
        "western": 37, "kids": 10762, "news": 10763, "reality": 10764,
        "soap": 10766, "talk": 10767, "war & politics": 10768
    ]

    init(fetcher: DiscoverFetching = TMDBDiscoverService.shared) {
        self.fetcher = fetcher
    }

    /// TMDB's titles for a watch history, owned ones still in: none under `minimumWatched` titles.
    func candidates(watched: [WatchedTitle]) async -> [TMDBListItem] {
        guard watched.count >= Self.minimumWatched else { return [] }
        return await candidates(profile: WatchProfileBuilder.build(from: watched))
    }

    /// Movies then shows in the profile's top three genres, in TMDB's order, owned ones still in.
    func candidates(profile: FeatureProfile) async -> [TMDBListItem] {
        let topGenres = profile.topGenres(3)
        guard topGenres.count >= coldStartGenreThreshold else { return [] }

        let genreIds = topGenres.compactMap { Self.genreNameToId[$0] }
        guard !genreIds.isEmpty else { return [] }
        // Keywords in our profile are TMDB keyword names, not IDs.
        // Without a name→ID map we omit keyword filters for v1.
        let movies = await fetcher.discover(type: .movie, withGenres: genreIds, withKeywords: [])
        let tvShows = await fetcher.discover(type: .tv, withGenres: genreIds, withKeywords: [])
        return movies + tvShows
    }

    /// The row: the candidates in order with the owned ones dropped, at most `maxItems`.
    static func row<Item>(_ candidates: [Item], isOwned: (Item) async -> Bool) async -> [Item] {
        var row: [Item] = []
        for item in candidates {
            if await !isOwned(item) {
                row.append(item)
            }
            if row.count >= maxItems { break }
        }
        return row
    }
}
