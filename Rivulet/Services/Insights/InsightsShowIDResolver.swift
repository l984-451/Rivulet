// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Resolves a show's TMDB id when Plex gives no tmdb:// guid: episodes carry a plex:// or tvdb://
// grandparent guid, so tvdb/imdb ids go through `tmdb/find` (`TMDBTransport`), cached per show.

import Foundation

actor InsightsShowIDResolver {
    static let shared = InsightsShowIDResolver()

    private let session: URLSession
    private let baseURL: URL
    // Cache keyed by the external id we looked up ("tvdb:409104" / "imdb:tt...")
    // so repeated episodes of the same show don't re-hit the network. nil is
    // cached too (a negative result) to avoid hammering find for an unmatchable
    // show every episode.
    private var cache: [String: Int?] = [:]

    init(baseURL: URL = TMDBConfig.proxyBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Best show TMDB id from the given external ids: a direct tmdb id wins
    /// (no network), else resolve tvdb -> tmdb, else imdb -> tmdb. `nil` if none
    /// resolve.
    func resolve(_ ids: ShowExternalIDs) async -> Int? {
        if let tmdb = ids.tmdb { return tmdb }
        if let tvdb = ids.tvdb, let id = await find(external: String(tvdb), source: "tvdb_id", cacheKey: "tvdb:\(tvdb)") {
            return id
        }
        if let imdb = ids.imdb, let id = await find(external: imdb, source: "imdb_id", cacheKey: "imdb:\(imdb)") {
            return id
        }
        return nil
    }

    /// Hit `/tmdb/find/{externalId}?source={source}` and return the first TV
    /// result's TMDB id. Result (including nil) cached per external id.
    private func find(external: String, source: String, cacheKey: String) async -> Int? {
        if let cached = cache[cacheKey] { return cached }
        let id = await performFind(external: external, source: source)
        cache[cacheKey] = id
        return id
    }

    private func performFind(external: String, source: String) async -> Int? {
        guard let encoded = external.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let data = try? await TMDBTransport.data("tmdb/find/\(encoded)", query: [URLQueryItem(name: "source", value: source)],
                                                       session: session, baseURL: baseURL),
              let decoded = try? JSONDecoder().decode(FindResponse.self, from: data) else {
            return nil
        }
        return decoded.tvResults.first?.id
    }

    private struct FindResponse: Decodable {
        let tvResults: [Result]
        struct Result: Decodable { let id: Int }
        enum CodingKeys: String, CodingKey { case tvResults = "tv_results" }
    }
}
