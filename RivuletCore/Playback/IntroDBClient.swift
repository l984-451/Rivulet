// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IntroDBClient.swift
//  Rivulet
//
//  Fallback marker source backed by the community intro database
//  (introdb.app). When Plex has no intro / credits markers for an episode we
//  query by the show's IMDB id + season/episode. These DBs also provide RECAP
//  segments, which Plex never emits. Reads are anonymous (no key).
//
//  The lookup is OPT-IN (SettingsStore "useIntroDB"): it sends the show's
//  IMDB id + S/E to a third party, so it only runs when the user turns it on.
//
//  Markers come back as `PlexMarker` values (type "intro" / "recap" /
//  "credits") with NEGATIVE synthetic ids, so they flow through the existing
//  marker check/skip machinery untouched and can never collide with Plex's
//  own (positive) marker ids.
//

import Foundation

nonisolated struct IntroDBClient {

    /// The only host published by the API spec (api.introdb.app/openapi.json).
    /// The `/segments` endpoint returns intro, recap and outro together.
    private static let segmentsURL = "https://api.introdb.app/segments"

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

    func markers(imdbID: String, season: Int, episode: Int) async -> [PlexMarker] {
        guard var comps = URLComponents(string: Self.segmentsURL) else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbID),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode)),
        ]
        guard let url = comps.url else { return [] }
        // Short timeout: a dead community endpoint must not hold the (already
        // off-critical-path) backfill task open for a minute.
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        return Self.decode(data)
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
            guard let s = seg?.start_sec, let e = seg?.end_sec, e > s else { return nil }
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
