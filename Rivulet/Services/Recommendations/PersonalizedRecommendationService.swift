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

private struct FeatureProfile {
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
}

actor PersonalizedRecommendationService {
    static let shared = PersonalizedRecommendationService()

    private let tmdbClient = TMDBClient.shared
    private let networkManager = PlexNetworkManager.shared
    private let dataStore = PlexDataStore.shared
    private let authManager = PlexAuthManager.shared

    private struct CacheKey: Hashable {
        let contentType: RecommendationContentType
        let libraryKey: String?
        let serverURL: String
    }

    private var cachedResults: [CacheKey: RecommendationResult] = [:]
    private let cacheTTL: TimeInterval = 60 * 60 * 12  // 12 hours
    private let maxItemsPerLibrary = 200
    private let maxWatchedForProfile = 120
    private let maxRecommendations = 40

    // Genre normalization (common variants)
    private let genreNormalization: [String: String] = [
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

    func recommendations(
        forceRefresh: Bool = false,
        contentType: RecommendationContentType = .moviesAndShows,
        libraryKey: String? = nil
    ) async throws -> [PlexMetadata] {
        let auth = await MainActor.run { (authManager.selectedServerURL, authManager.selectedServerToken) }
        guard let serverURL = auth.0 else {
            throw NSError(domain: "PlexAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not authenticated with Plex"])
        }

        let key = CacheKey(contentType: contentType, libraryKey: libraryKey, serverURL: serverURL)

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
        var profile = FeatureProfile()

        for item in watchedSample {
            let features = await buildFeatures(for: item)
            let weight = recencyWeight(lastViewedAt: item.lastViewedAt) * rewatchBoost(viewCount: item.viewCount)
            profile.add(features: features, weight: weight)
        }

        var scored: [(PlexMetadata, Double)] = []
        for item in unwatchedItems {
            let features = await buildFeatures(for: item)
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

    // MARK: - Feature helpers

    private func buildFeatures(for item: PlexMetadata) async -> TMDBItemFeatures {
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
            if let tmdbFeatures = await tmdbClient.fetchFeatures(tmdbId: tmdbId, type: item.tmdbMediaType) {
                features.merge(from: tmdbFeatures)
            }
        }

        return features.normalized()
    }

    private func recencyWeight(lastViewedAt: Int?) -> Double {
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

    private func rewatchBoost(viewCount: Int?) -> Double {
        let count = Double(viewCount ?? 0)
        if count <= 1 { return 1.0 }
        return log2(count) + 1.0
    }

    private func normalizedScore(tags: [String], counts: [String: Double], maxCount: Double) -> Double {
        guard !tags.isEmpty, maxCount > 0 else { return 0 }
        let sum = tags.reduce(0.0) { partial, tag in
            partial + (counts[tag, default: 0])
        }
        return sum / (maxCount * Double(tags.count))
    }

    private func fuzzyKeywordScore(keywords: [String], counts: [String: Double]) -> Double {
        guard !keywords.isEmpty, !counts.isEmpty else { return 0 }
        let maxCount = counts.values.max() ?? 1
        var total: Double = 0

        for keyword in keywords {
            var bestMatch = 0.0
            for (userKeyword, weight) in counts {
                let kwLower = keyword
                let userLower = userKeyword
                if kwLower == userLower {
                    bestMatch = max(bestMatch, weight)
                    continue
                }
                if kwLower.contains(userLower) || userLower.contains(kwLower) {
                    let kwParts = Set(kwLower.split(separator: " "))
                    let userParts = Set(userLower.split(separator: " "))
                    let overlap = kwParts.intersection(userParts).count
                    let union = max(kwParts.union(userParts).count, 1)
                    let similarity = Double(overlap) / Double(union)
                    let matchScore = weight * (0.5 + 0.5 * similarity)
                    bestMatch = max(bestMatch, matchScore)
                }
            }
            total += bestMatch
        }

        return total / (Double(keywords.count) * maxCount)
    }

    private func score(features: TMDBItemFeatures, profile: FeatureProfile, metadata: PlexMetadata) -> Double {
        let keywordScore = fuzzyKeywordScore(keywords: features.keywords, counts: profile.keywords)
        let genreScore = normalizedScore(tags: features.genres, counts: profile.genres, maxCount: profile.maxGenre)
        let castScore = normalizedScore(tags: features.cast, counts: profile.cast, maxCount: profile.maxCast)
        let directorScore = normalizedScore(tags: features.directors, counts: profile.directors, maxCount: profile.maxDirector)

        // Redistribute weights if signals are missing (weights similar to upstream)
        var weights: [Double] = []
        var signals: [Double] = []

        let components: [(Double, Double)] = [
            (0.5, keywordScore),
            (0.25, genreScore),
            (0.20, castScore),
            (0.05, directorScore)
        ]

        var totalWeight: Double = 0
        for (w, s) in components where s > 0 {
            weights.append(w)
            signals.append(s)
            totalWeight += w
        }

        let redistributed = zip(weights, signals).reduce(0.0) { partial, pair in
            let (w, s) = pair
            return partial + (s * (w / max(totalWeight, 0.0001)))
        }

        let ratingBoost = ((metadata.audienceRating ?? metadata.rating ?? metadata.userRating ?? 0) / 10.0) * 0.1
        return redistributed + ratingBoost
    }
}
