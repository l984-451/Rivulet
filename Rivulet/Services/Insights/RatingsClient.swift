// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RatingsClient.swift
//  Rivulet
//
//  Review scores from the insights-api Worker (MDBList behind it), keyed by
//  TMDB id only. Every failure is soft: an empty list.
//

import Foundation

actor RatingsClient {
    static let shared = RatingsClient()

    private let session: URLSession
    private let baseURL: URL
    /// Answers by "type/tmdbID", so the info popup reuses what the detail page already fetched.
    private var cache: [String: [MediaRating]] = [:]

    init(baseURL: URL = InsightsConfig.apiBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Requests still on the wire, so a read that gave up and the next one share one fetch.
    private var inFlight: [String: Task<[MediaRating]?, Never>] = [:]

    /// Scores for a movie or show; empty for other kinds or without a TMDB id.
    func ratings(for detail: MediaItemDetail) async -> [MediaRating] {
        guard let key = Self.key(for: detail) else { return [] }
        if let cached = cache[key] { return cached }
        return await fetch(key).value ?? []
    }

    /// The fetch runs on its own task: a capped read that gives up does not cancel it, so a
    /// slow answer still lands in the cache. Cancelling it left the cache empty, and every
    /// visit to a title the Worker answers in over a second showed the fallback score.
    private func fetch(_ key: String) -> Task<[MediaRating]?, Never> {
        if let task = inFlight[key] { return task }
        let url = baseURL.appendingPathComponent("v1/ratings/\(key)")
        let session = session
        let task = Task<[MediaRating]?, Never> {
            guard let (data, response) = try? await session.attestedData(for: URLRequest(url: url)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return Self.decode(data)
        }
        inFlight[key] = task
        Task { await self.store(key, task.value) }
        return task
    }

    private func store(_ key: String, _ ratings: [MediaRating]?) {
        inFlight[key] = nil
        // A failed request is not cached: the next read asks again.
        if let ratings { cache[key] = ratings }
    }

    private nonisolated static func key(for detail: MediaItemDetail) -> String? {
        let type: String
        switch detail.item.kind {
        case .movie: type = "movie"
        case .show: type = "show"
        default: return nil
        }
        guard let id = detail.externalIDs["tmdb"], !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return "\(type)/\(id)"
    }

    /// `ratings(for:)`, giving up with an empty list after `seconds`. The fetch carries on.
    func ratings(for detail: MediaItemDetail, within seconds: Double) async -> [MediaRating] {
        guard let key = Self.key(for: detail) else { return [] }
        if let cached = cache[key] { return cached }
        let task = fetch(key)
        return await withTaskGroup(of: [MediaRating]?.self) { group in
            group.addTask { await task.value ?? [] }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    private struct Payload: Decodable {
        struct Entry: Decodable { let source: String; let value: Double }
        let ratings: [Entry]
    }

    /// Maps the Worker's native scales onto `MediaRating`'s 0–10.
    nonisolated static func decode(_ data: Data) -> [MediaRating] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return MediaRating.ordered(payload.ratings.map { entry in
            switch entry.source {
            case "tomatoes": MediaRating(entry.value / 10, source: .rottenTomatoes)
            case "popcorn": MediaRating(entry.value / 10, source: .rottenTomatoesAudience)
            case "imdb": MediaRating(entry.value, source: .imdb)
            case "metacritic": MediaRating(entry.value / 10, source: .metacritic)
            case "letterboxd": MediaRating(entry.value * 2, source: .letterboxd)
            case "tmdb": MediaRating(entry.value / 10, source: .tmdb)
            default: nil
            }
        })
    }
}
