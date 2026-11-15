// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonalizedRecommendationService.swift
//  Rivulet
//
//  Generates personalized recommendations using Plex watch signals + TMDB proxy data.
//  Scope: movies only for now to keep runtime reasonable; can extend to shows later.
//

import Foundation

enum RecommendationContentType: String, Codable {
    case movies
    case shows
    case moviesAndShows
}

private struct RecommendationResult: Codable {
    let generatedAt: Date
    let items: [PlexMetadata]
    let contentType: RecommendationContentType
    let libraryKey: String?
    let serverURL: String
}

actor PersonalizedRecommendationService {
    static let shared = PersonalizedRecommendationService()

    private let networkManager = PlexNetworkManager.shared
    private let dataStore = PlexDataStore.shared
    private let authManager = PlexAuthManager.shared

    private struct CacheKey: Hashable {
        let contentType: RecommendationContentType
        let libraryKey: String?
        let serverURL: String
        /// The profile the row was built from (0 is the account).
        let userID: Int
    }

    private var cachedResults: [CacheKey: RecommendationResult] = [:]
    private let cacheTTL: TimeInterval = 60 * 60 * 2  // 2 hours
    private let maxItemsPerLibrary = 200
    private let maxWatchedForProfile = 120
    private let maxRecommendations = 40

    func recommendations(
        forceRefresh: Bool = false,
        contentType: RecommendationContentType = .moviesAndShows,
        libraryKey: String? = nil
    ) async throws -> [PlexMetadata] {
        let auth = await MainActor.run { (authManager.selectedServerURL, authManager.selectedServerToken) }
        guard let serverURL = auth.0 else {
            throw NSError(domain: "PlexAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not authenticated with Plex"])
        }

        let key = CacheKey(contentType: contentType, libraryKey: libraryKey, serverURL: serverURL,
                           userID: UserDefaults.standard.integer(forKey: PlexProfileSession.contentUserIDKey))

        if !forceRefresh, let cached = cachedResults[key] {
            if Date().timeIntervalSince(cached.generatedAt) < cacheTTL {
                return cached.items
            }
        }

        let items = try await computeRecommendations(contentType: contentType, libraryKey: libraryKey, serverURL: serverURL)
        cachedResults[key] = RecommendationResult(
            generatedAt: Date(),
            items: items,
            contentType: contentType,
            libraryKey: libraryKey,
            serverURL: serverURL
        )
        return items
    }

    /// Get recommendations for a specific item (content-based + personalized)
    /// Builds a profile from the item's features and optionally blends with watch history
    /// - Parameters:
    ///   - item: The item to get recommendations for
    ///   - blendWithHistory: If true, blends item features with user's watch history (85/15 split)
    ///   - limit: Maximum number of recommendations to return
    func recommendationsForItem(
        _ item: PlexMetadata,
        blendWithHistory: Bool = true,
        limit: Int = 12
    ) async throws -> [PlexMetadata] {
        let auth = await MainActor.run { (authManager.selectedServerURL, authManager.selectedServerToken) }
        guard let serverURL = auth.0, let token = auth.1 else {
            throw NSError(domain: "PlexAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not authenticated with Plex"])
        }

        // Build feature profile from the current item
        let itemFeatures = await WatchProfileBuilder.buildFeatures(for: item)
        var itemProfile = FeatureProfile()
        itemProfile.add(features: itemFeatures, weight: 1.0)

        // Optionally blend with watch history profile
        let profile: FeatureProfile
        if blendWithHistory {
            // Get watch history profile
            let historyProfile = try await buildWatchHistoryProfile(serverURL: serverURL, token: token)
            profile = blendProfiles(primary: itemProfile, secondary: historyProfile, primaryWeight: 0.85)
        } else {
            profile = itemProfile
        }

        // Get library items to score
        await dataStore.loadLibrariesIfNeeded()
        let visibleLibraries = await MainActor.run { dataStore.visibleLibraries }
        let movieLibraries = visibleLibraries.filter { $0.type == "movie" }

        var libraryItems: [PlexMetadata] = []
        for library in movieLibraries {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: library.key,
                start: 0,
                size: maxItemsPerLibrary
            )
            libraryItems.append(contentsOf: result.items.filter { $0.type == "movie" })
        }

        // Filter out watched items and the current item
        let candidates = libraryItems.filter {
            $0.ratingKey != item.ratingKey && ($0.viewCount ?? 0) == 0
        }

        // Score candidates
        var scored: [(PlexMetadata, Double)] = []
        let candidateFeatures = await WatchProfileBuilder.buildFeatures(for: candidates)
        for (candidate, features) in zip(candidates, candidateFeatures) {
            let itemScore = score(features: features, profile: profile, metadata: candidate)
            scored.append((candidate, itemScore))
        }

        // Sort and return top results
        let sorted = scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }

        return Array(sorted)
    }

    // MARK: - Core logic

    private func computeRecommendations(contentType: RecommendationContentType, libraryKey: String?, serverURL: String) async throws -> [PlexMetadata] {
        let authToken = await MainActor.run { authManager.selectedServerToken }
        guard let token = authToken else {
            throw NSError(domain: "PlexAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not authenticated with Plex"])
        }

        await dataStore.loadLibrariesIfNeeded()
        let visibleLibraries = await MainActor.run { dataStore.visibleLibraries }

        // Determine target libraries: specific library when provided, else all visible video libraries
        let targetLibraries: [PlexLibrary] = {
            if let libraryKey {
                return visibleLibraries.filter { $0.key == libraryKey }
            }
            return visibleLibraries.filter { $0.isVideoLibrary }
        }()
        guard !targetLibraries.isEmpty else { return [] }

        var libraryItems: [PlexMetadata] = []
        for library in targetLibraries {
            switch contentType {
            case .movies where library.type != "movie":
                continue
            case .shows where library.type != "show":
                continue
            default:
                break
            }

            // Limit fetch size to keep runtime in check
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: library.key,
                start: 0,
                size: maxItemsPerLibrary
            )
            let filtered: [PlexMetadata]
            switch contentType {
            case .movies:
                filtered = result.items.filter { $0.type == "movie" }
            case .shows:
                filtered = result.items.filter { $0.type == "show" }
            case .moviesAndShows:
                filtered = result.items.filter { $0.type == "movie" || $0.type == "show" }
            }
            libraryItems.append(contentsOf: filtered)
        }

        if libraryItems.isEmpty { return [] }

        // Split watched/unwatched
        let watchedItems = libraryItems.filter { ($0.viewCount ?? 0) > 0 || $0.lastViewedAt != nil }
        let unwatchedItems = libraryItems.filter { ($0.viewCount ?? 0) == 0 }

        // Build profile from most recently watched items
        let recentWatched = watchedItems.sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
        let watchedSample = Array(recentWatched.prefix(maxWatchedForProfile))
        let profile = await WatchProfileBuilder.build(from: watchedSample)

        var scored: [(PlexMetadata, Double)] = []
        let unwatchedFeatures = await WatchProfileBuilder.buildFeatures(for: unwatchedItems)
        for (item, features) in zip(unwatchedItems, unwatchedFeatures) {
            let score = score(features: features, profile: profile, metadata: item)
            scored.append((item, score))
        }

        let sorted = scored
            .filter { !$0.0.isWatched && $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(maxRecommendations)
            .map { $0.0 }

        return Array(sorted)
    }

    // MARK: - Scoring helpers

    /// Popularity dampening: slightly penalizes very popular content (upstream v2.8+)
    private func popularityDampening(voteCount: Int?) -> Double {
        guard let votes = voteCount, votes > 50_000 else { return 1.0 }
        let penalty = 0.03 * log10(Double(votes) / 50_000.0)
        return max(0.90, 1.0 - penalty)
    }

    /// Upstream-style scoring: sqrt normalization with saturation curve (diminishing returns)
    private func normalizedScore(tags: [String], counts: [String: Double], maxCount: Double) -> Double {
        guard !tags.isEmpty, maxCount > 0 else { return 0 }
        let sum = tags.reduce(0.0) { partial, tag in
            let raw = counts[tag, default: 0]
            return partial + sqrt(raw / maxCount)
        }
        // Saturation curve: prevents items with many matches from linearly dominating
        return 1.0 - (1.0 / (1.0 + sum))
    }

    private func fuzzyKeywordScore(keywords: [String], counts: [String: Double]) -> Double {
        guard !keywords.isEmpty, !counts.isEmpty else { return 0 }
        let maxCount = counts.values.max() ?? 1
        var total: Double = 0

        for keyword in keywords {
            var bestMatch = 0.0
            for (userKeyword, weight) in counts {
                if keyword == userKeyword {
                    bestMatch = max(bestMatch, weight)
                    continue
                }
                if keyword.contains(userKeyword) || userKeyword.contains(keyword) {
                    let kwParts = Set(keyword.split(separator: " "))
                    let userParts = Set(userKeyword.split(separator: " "))
                    let overlap = kwParts.intersection(userParts).count
                    let union = max(kwParts.union(userParts).count, 1)
                    let similarity = Double(overlap) / Double(union)
                    let matchScore = weight * (0.5 + 0.5 * similarity)
                    bestMatch = max(bestMatch, matchScore)
                }
            }
            // sqrt normalization per match
            total += sqrt(bestMatch / maxCount)
        }

        // Saturation curve (matches upstream)
        return 1.0 - (1.0 / (1.0 + total))
    }

    private func score(features: TMDBItemFeatures, profile: FeatureProfile, metadata: PlexMetadata) -> Double {
        let keywordScore = fuzzyKeywordScore(keywords: features.keywords, counts: profile.keywords)
        let genreScore = normalizedScore(tags: features.genres, counts: profile.genres, maxCount: profile.maxGenre)
        let castScore = normalizedScore(tags: features.cast, counts: profile.cast, maxCount: profile.maxCast)
        let directorScore = normalizedScore(tags: features.directors, counts: profile.directors, maxCount: profile.maxDirector)

        // Per-item weight redistribution (upstream v2.8+):
        // First pass: drop components where profile has data but item has zero match
        // Second pass: redistribute remaining weights proportionally
        let components: [(weight: Double, score: Double, hasProfileData: Bool)] = [
            (0.50, keywordScore, !profile.keywords.isEmpty),
            (0.25, genreScore, !profile.genres.isEmpty),
            (0.20, castScore, !profile.cast.isEmpty),
            (0.05, directorScore, !profile.directors.isEmpty)
        ]

        // Only include components that either matched or had no profile data to match against
        var activeWeight: Double = 0
        var weightedSum: Double = 0
        for c in components {
            if c.score > 0 || !c.hasProfileData {
                activeWeight += c.weight
                weightedSum += c.score * c.weight
            }
        }

        let baseScore = activeWeight > 0 ? weightedSum / activeWeight : 0

        // Rating boost from item's community/audience rating
        let ratingBoost = ((metadata.audienceRating ?? metadata.rating ?? 0) / 10.0) * 0.1

        // Popularity dampening for very popular content
        let dampening = popularityDampening(voteCount: features.voteCount)

        return (baseScore + ratingBoost) * dampening
    }

    // MARK: - Profile helpers

    /// Build a feature profile from user's watch history
    private func buildWatchHistoryProfile(serverURL: String, token: String) async throws -> FeatureProfile {
        await dataStore.loadLibrariesIfNeeded()
        let visibleLibraries = await MainActor.run { dataStore.visibleLibraries }
        let movieLibraries = visibleLibraries.filter { $0.type == "movie" }

        var watchedItems: [PlexMetadata] = []
        for library in movieLibraries {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: library.key,
                start: 0,
                size: maxItemsPerLibrary
            )
            let watched = result.items.filter { ($0.viewCount ?? 0) > 0 || $0.lastViewedAt != nil }
            watchedItems.append(contentsOf: watched)
        }

        // Sort by recency and take top items
        let recentWatched = Array(
            watchedItems
                .sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
                .prefix(maxWatchedForProfile)
        )

        return await WatchProfileBuilder.build(from: recentWatched)
    }

    /// Blend two profiles with specified weights
    private func blendProfiles(primary: FeatureProfile, secondary: FeatureProfile, primaryWeight: Double) -> FeatureProfile {
        let secondaryWeight = 1.0 - primaryWeight

        var blended = FeatureProfile()

        // Blend keywords
        for (key, value) in primary.keywords {
            blended.keywords[key, default: 0] += value * primaryWeight
        }
        for (key, value) in secondary.keywords {
            blended.keywords[key, default: 0] += value * secondaryWeight
        }

        // Blend genres
        for (key, value) in primary.genres {
            blended.genres[key, default: 0] += value * primaryWeight
        }
        for (key, value) in secondary.genres {
            blended.genres[key, default: 0] += value * secondaryWeight
        }

        // Blend cast
        for (key, value) in primary.cast {
            blended.cast[key, default: 0] += value * primaryWeight
        }
        for (key, value) in secondary.cast {
            blended.cast[key, default: 0] += value * secondaryWeight
        }

        // Blend directors
        for (key, value) in primary.directors {
            blended.directors[key, default: 0] += value * primaryWeight
        }
        for (key, value) in secondary.directors {
            blended.directors[key, default: 0] += value * secondaryWeight
        }

        return blended
    }
}
