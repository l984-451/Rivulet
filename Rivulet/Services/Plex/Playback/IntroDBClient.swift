//
//  IntroDBClient.swift
//  Rivulet
//
//  Fallback marker source backed by the community intro databases
//  (introdb.app + theintrodb.org), ported from PlexGuide/Flume. When Plex has
//  no intro/credit markers for an episode we query by the show's IMDB id +
//  season/episode. Reads are anonymous (no key). These DBs also provide RECAP
//  segments, which Plex never emits.
//
//  Markers come back as `PlexMarker` values (type "intro" / "recap" /
//  "credits") with NEGATIVE synthetic ids, so they flow through the existing
//  marker check/skip machinery untouched and can never collide with Plex's
//  own (positive) marker ids.
//

import Foundation

nonisolated struct IntroDBClient {

    /// Tried in order; the first DB with data for a given segment kind wins.
    private static let bases = [
        "https://api.introdb.app/segments",
        "https://api.theintrodb.org/segments",
    ]

    /// Synthetic ids for backup markers — negative so the per-id skipped sets
    /// work and Plex ids (positive) can never collide.
    private static let syntheticIds: [String: Int] = [
        "intro": -9001,
        "recap": -9002,
        "credits": -9003,
    ]

    func markers(imdbID: String, season: Int, episode: Int) async -> [PlexMarker] {
        var byType: [String: PlexMarker] = [:]
        for base in Self.bases {
            let found = await fetch(base: base, imdbID: imdbID, season: season, episode: episode)
            for marker in found {
                if let type = marker.type, byType[type] == nil {
                    byType[type] = marker
                }
            }
        }
        return Array(byType.values)
    }

    private func fetch(base: String, imdbID: String, season: Int, episode: Int) async -> [PlexMarker] {
        guard var comps = URLComponents(string: base) else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbID),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode)),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return Self.decode(data)
    }

    static func decode(_ data: Data) -> [PlexMarker] {
        struct Segment: Decodable { let start_sec: Double?; let end_sec: Double? }
        struct Wire: Decodable { let intro: Segment?; let recap: Segment?; let outro: Segment? }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return [] }

        func marker(_ seg: Segment?, _ type: String) -> PlexMarker? {
            guard let s = seg?.start_sec, let e = seg?.end_sec, e > s else { return nil }
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
