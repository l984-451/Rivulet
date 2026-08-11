// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBClient.swift
//  Rivulet
//
//  Lightweight TMDB client that talks to the Cloudflare Worker proxy.
//  Used only for per-item features (keywords/cast/genres/directors) that
//  feed the personalized recommendation engine. Artwork (logos, backdrops)
//  comes from Plex directly.
//

import Foundation

enum TMDBMediaType: String, Codable, Sendable {
    case movie
    case tv
}

struct TMDBKeyword: Codable {
    let id: Int?
    let name: String?
}

struct TMDBGenre: Codable, Sendable {
    let id: Int?
    let name: String?
}

struct TMDBDetails: Codable {
    let genres: [TMDBGenre]?
    let voteAverage: Double?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case genres
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }
}

struct TMDBCredit: Codable, Sendable {
    let id: Int?
    let name: String?
    let job: String?
    let department: String?
    let character: String?
    let profilePath: String?
    enum CodingKeys: String, CodingKey {
        case id, name, job, department, character
        case profilePath = "profile_path"
    }
}

struct TMDBPersonDetails: Codable, Sendable {
    let biography: String?
    let profilePath: String?
    enum CodingKeys: String, CodingKey {
        case biography
        case profilePath = "profile_path"
    }
}

private struct TMDBKeywordsResponse: Codable {
    let keywords: [TMDBKeyword]?
    let results: [TMDBKeyword]?

    var allKeywords: [TMDBKeyword] {
        if let keywords { return keywords }
        if let results { return results }
        return []
    }
}

private struct TMDBCreditsResponse: Codable {
    let cast: [TMDBCredit]?
    let crew: [TMDBCredit]?
}

struct TMDBEpisodeCreditsResponse: Codable {
    let cast: [TMDBCredit]?
    let guestStars: [TMDBCredit]?
    enum CodingKeys: String, CodingKey {
        case cast
        case guestStars = "guest_stars"
    }
}

struct TMDBItemFeatures: Codable {
    var keywords: [String]
    var cast: [String]
    var directors: [String]
    var genres: [String]
    var voteAverage: Double?
    var voteCount: Int?

    mutating func merge(from other: TMDBItemFeatures) {
        keywords.append(contentsOf: other.keywords)
        cast.append(contentsOf: other.cast)
        directors.append(contentsOf: other.directors)
        genres.append(contentsOf: other.genres)
    }

    func normalized() -> TMDBItemFeatures {
        TMDBItemFeatures(
            keywords: Array(Set(keywords)),
            cast: Array(Set(cast)),
            directors: Array(Set(directors)),
            genres: Array(Set(genres)),
            voteAverage: voteAverage,
            voteCount: voteCount
        )
    }
}

private struct CachedFeatures: Codable {
    let generatedAt: Date
    let features: TMDBItemFeatures
}

final class TMDBClient: @unchecked Sendable {
    static let shared = TMDBClient()

    private let session: URLSession
    private let cacheDirectory: URL
    private let cacheTTL = TMDBConfig.localCacheTTL

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDirectory = caches.appendingPathComponent("TMDBCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func fetchFeatures(tmdbId: Int, type: TMDBMediaType) async -> TMDBItemFeatures? {
        if let cached = loadCachedFeatures(tmdbId: tmdbId, type: type) {
            return cached
        }

        do {
            async let keywordsResponse: TMDBKeywordsResponse = request(endpoint: "tmdb/keywords/\(tmdbId)", type: type)
            async let creditsResponse: TMDBCreditsResponse = request(endpoint: "tmdb/credits/\(tmdbId)", type: type)
            async let detailsResponse: TMDBDetails = request(endpoint: "tmdb/details/\(tmdbId)", type: type)

            let (keywords, credits, details) = try await (keywordsResponse, creditsResponse, detailsResponse)

            let features = TMDBItemFeatures(
                keywords: keywords.allKeywords.compactMap { $0.name?.lowercased() },
                cast: (credits.cast ?? []).prefix(8).compactMap { $0.name?.lowercased() },
                directors: (credits.crew ?? []).filter { $0.job?.lowercased() == "director" }.prefix(4).compactMap { $0.name?.lowercased() },
                genres: (details.genres ?? []).compactMap { $0.name?.lowercased() },
                voteAverage: details.voteAverage,
                voteCount: details.voteCount
            ).normalized()

            saveCachedFeatures(features, tmdbId: tmdbId, type: type)
            return features
        } catch {
            return nil
        }
    }

    // MARK: - Networking

    private func request<T: Decodable>(endpoint: String, type: TMDBMediaType) async throws -> T {
        try await request(endpoint: endpoint, queryItems: [
            URLQueryItem(name: "type", value: type.rawValue)
        ])
    }

    private func request<T: Decodable>(endpoint: String, queryItems: [URLQueryItem]) async throws -> T {
        guard let url = URL(string: endpoint, relativeTo: TMDBConfig.proxyBaseURL) else {
            throw URLError(.badURL)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.queryItems = queryItems
        guard let finalURL = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.attestedData(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Local Cache

    private func cacheURL(tmdbId: Int, type: TMDBMediaType) -> URL {
        cacheDirectory.appendingPathComponent("\(type.rawValue)_\(tmdbId).json")
    }

    private func loadCachedFeatures(tmdbId: Int, type: TMDBMediaType) -> TMDBItemFeatures? {
        let url = cacheURL(tmdbId: tmdbId, type: type)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cached = try? JSONDecoder().decode(CachedFeatures.self, from: data) else { return nil }
        let age = Date().timeIntervalSince(cached.generatedAt)
        guard age < cacheTTL else { return nil }
        return cached.features
    }

    private func saveCachedFeatures(_ features: TMDBItemFeatures, tmdbId: Int, type: TMDBMediaType) {
        let cached = CachedFeatures(generatedAt: Date(), features: features)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let url = cacheURL(tmdbId: tmdbId, type: type)
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Actor bio

    /// Resolves an actor (by the originating title's TMDB credits + a name match)
    /// to their TMDB biography. Plex exposes no actor-bio API, so TMDB is the bio
    /// source for the person page. The PORTRAIT is intentionally NOT taken from
    /// TMDB — the page renders the Plex role thumb from first paint, and swapping
    /// in a different TMDB image seconds later is jarring. Returns nil if unresolved.
    func actorBiography(titleTmdbId: Int, type: TMDBMediaType, actorName: String) async -> String? {
        guard let credits: TMDBCreditsResponse = try? await request(endpoint: "tmdb/credits/\(titleTmdbId)", type: type) else {
            return nil
        }
        func norm(_ s: String) -> String { s.folding(options: .diacriticInsensitive, locale: .current).lowercased() }
        let target = norm(actorName)
        let match = (credits.cast ?? []).first { ($0.name.map(norm)) == target }
        guard let match, let personId = match.id else { return nil }
        let person: TMDBPersonDetails? = try? await request(endpoint: "tmdb/person/\(personId)", queryItems: [])
        return person?.biography.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Structured cast (Insights)

    /// Structured cast for movie or show. Returns [] on any failure —
    /// callers treat empty as "fall back to Plex roles".
    func castCredits(tmdbId: Int, type: TMDBMediaType) async -> [TMDBCredit] {
        let credits: TMDBCreditsResponse? = try? await request(endpoint: "tmdb/credits/\(tmdbId)", type: type)
        return credits?.cast ?? []
    }

    /// Episode-level cast: season regulars followed by episode's guest
    /// stars. Requires proxy's `episode_credits` route; returns nil when
    /// unavailable so callers can fall back show-level `castCredits`.
    func episodeCastCredits(showTmdbId: Int, season: Int, episode: Int) async -> [TMDBCredit]? {
        let response: TMDBEpisodeCreditsResponse? = try? await request(
            endpoint: "tmdb/episode_credits/\(showTmdbId)",
            queryItems: [
                URLQueryItem(name: "season", value: String(season)),
                URLQueryItem(name: "episode", value: String(episode)),
            ])
        guard let response else { return nil }
        let merged = Self.mergedEpisodeCast(response)
        return merged.isEmpty ? nil : merged
    }

    /// Regulars first, guests; dedupe by person id (a regular also
    /// appear in guest_stars for some shows).
    static func mergedEpisodeCast(_ response: TMDBEpisodeCreditsResponse) -> [TMDBCredit] {
        let cast = response.cast ?? []
        let guests = response.guestStars ?? []
        let regularIds = Set(cast.compactMap { $0.id })
        let unique = cast + guests.filter { !regularIds.contains($0.id ?? -1) }
        return unique
    }
}
