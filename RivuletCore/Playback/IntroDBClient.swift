// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IntroDBClient.swift
//  Rivulet
//
//  Fallback intro, recap and credits markers from introdb.app, with TheIntroDB
//  (theintrodb.org) filling the kinds introdb.app lacks, both by IMDb id plus
//  season and episode. Opt-in ("useIntroDB"): it sends those to two third parties.
//  Markers are `PlexMarker`s with negative ids, so they never collide with Plex's.
//

import Foundation

nonisolated struct IntroDBClient {

    /// The only host published by the API spec (api.introdb.app/openapi.json).
    /// The `/segments` endpoint returns intro, recap and outro together.
    private static let segmentsURL = "https://api.introdb.app/segments"

    /// TheIntroDB's lookup (api.theintrodb.org/v2/media): no key, 30 requests per 10 seconds.
    private static let theIntroDBURL = "https://api.theintrodb.org/v2/media"

    /// Drop crowd-sourced segments whose submissions don't agree — the API's
    /// `confidence` is 0...1 based on submission agreement. Below this we'd
    /// rather show nothing than skip over real content on a lone bad entry.
    static let minConfidence = 0.5

    /// Synthetic ids for backup markers — negative so the per-id skipped sets
    /// work and Plex ids (positive) can never collide.
    private static let syntheticIds: [String: Int] = [
        "intro": -9001,
        "recap": -9002,
        "credits": -9003,
    ]

    /// Both services at once. `duration` (seconds) ends a TheIntroDB credits marker that runs to the
    /// end of the episode; without it such a marker is dropped.
    func markers(imdbID: String, season: Int, episode: Int, duration: TimeInterval? = nil) async -> [PlexMarker] {
        async let introDB = Self.fetch(Self.segmentsURL, imdbID: imdbID, season: season, episode: episode)
        async let theIntroDB = Self.fetch(Self.theIntroDBURL, imdbID: imdbID, season: season, episode: episode)
        let primary = await introDB.map(Self.decode) ?? []
        let secondary = await theIntroDB.map { Self.decodeTheIntroDB($0, duration: duration) } ?? []
        return Self.combined(primary, secondary)
    }

    private static func fetch(_ base: String, imdbID: String, season: Int, episode: Int) async -> Data? {
        guard var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbID),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode)),
        ]
        guard let url = comps.url else { return nil }
        // Short timeout: a dead community endpoint must not hold the (already
        // off-critical-path) backfill task open for a minute.
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return nil }
        return data
    }

    /// introdb.app's markers, then TheIntroDB's for the kinds introdb.app has none of.
    static func combined(_ primary: [PlexMarker], _ secondary: [PlexMarker]) -> [PlexMarker] {
        let present = Set(primary.compactMap(\.type))
        return primary + secondary.filter { $0.type.map { !present.contains($0) } ?? false }
    }

    /// TheIntroDB's reply: a list per kind of `start_ms`/`end_ms`, where a missing start is the
    /// episode's start and a missing end its end. The first segment of each kind is used.
    static func decodeTheIntroDB(_ data: Data, duration: TimeInterval?) -> [PlexMarker] {
        struct Segment: Decodable { let start_ms: Int?; let end_ms: Int? }
        struct Wire: Decodable { let intro: [Segment]?; let recap: [Segment]?; let credits: [Segment]? }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return [] }
        let durationMs = duration.map { Int($0 * 1000) }

        func marker(_ segments: [Segment]?, _ type: String) -> PlexMarker? {
            guard let seg = segments?.first, let end = seg.end_ms ?? durationMs else { return nil }
            let start = seg.start_ms ?? 0
            guard start >= 0, end > start, end < 10_000_000_000 else { return nil }
            return PlexMarker(id: syntheticIds[type], type: type, startTimeOffset: start, endTimeOffset: end)
        }
        return [
            marker(wire.intro, "intro"),
            marker(wire.recap, "recap"),
            marker(wire.credits, "credits"),
        ].compactMap { $0 }
    }

    static func decode(_ data: Data) -> [PlexMarker] {
        struct Segment: Decodable {
            let start_sec: Double?
            let end_sec: Double?
            let confidence: Double?
        }
        struct Wire: Decodable { let intro: Segment?; let recap: Segment?; let outro: Segment? }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return [] }

        func marker(_ seg: Segment?, _ type: String) -> PlexMarker? {
            guard let s = seg?.start_sec, let e = seg?.end_sec, e > s, s >= 0, e < 1e7 else { return nil }
            // Missing confidence is treated as agreed (older entries); a
            // present-but-low confidence is rejected.
            guard (seg?.confidence ?? 1) >= minConfidence else { return nil }
            return PlexMarker(
                id: syntheticIds[type],
                type: type,
                startTimeOffset: Int(s * 1000),
                endTimeOffset: Int(e * 1000)
            )
        }
        return [
            marker(wire.intro, "intro"),
            marker(wire.recap, "recap"),
            marker(wire.outro, "credits"),   // outro == end credits
        ].compactMap { $0 }
    }
}
