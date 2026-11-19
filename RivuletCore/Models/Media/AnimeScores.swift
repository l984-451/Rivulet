// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

// MyAnimeList scores for anime, shown beside the rating on a detail page. The scores come from
// a file bundled with the app at build time; nothing is asked of any server. A title found in
// the file is anime. No file means no feature: no row in Settings, no mark, no error.

import Foundation
import os

/// The bundled file's shape. At file level so its conformance is not main-actor isolated.
nonisolated private struct AnimeScoreFile: Decodable {
    let format: Int
    let built: String
    let source: String?
    let tvdb: [String: Int]?        // "<tvdb series id>:<season>"
    let tmdbShow: [String: Int]?    // "<tmdb tv id>:<season>"
    let tmdbMovie: [String: Int]?   // "<tmdb movie id>"
    let imdbMovie: [String: Int]?   // "tt1234567", lowercase
}

/// The bundled table: one score per key, in hundredths (854 = 8.54).
nonisolated struct AnimeScoreTable: Sendable {
    static let format = 1

    let built: String
    let source: String?
    private let tvdb: [String: Int]
    private let tmdbShow: [String: Int]
    private let tmdbMovie: [String: Int]
    private let imdbMovie: [String: Int]

    /// Nil for anything but a well-formed file of the format this build reads.
    init?(data: Data) {
        guard let file = try? JSONDecoder().decode(AnimeScoreFile.self, from: data),
              file.format == Self.format else { return nil }
        built = file.built
        source = file.source
        tvdb = file.tvdb ?? [:]
        tmdbShow = file.tmdbShow ?? [:]
        tmdbMovie = file.tmdbMovie ?? [:]
        imdbMovie = file.imdbMovie ?? [:]
    }

    /// A show's season, by the SHOW's ids. `season` nil (the show's own page) reads season 1;
    /// specials (0) have none.
    func showScore(ids: [String: String], season: Int?) -> Double? {
        let number = season ?? 1
        guard number > 0 else { return nil }
        var raw: Int?
        if let id = ids["tvdb"] { raw = tvdb["\(id):\(number)"] }
        if raw == nil, let id = ids["tmdb"] { raw = tmdbShow["\(id):\(number)"] }
        return Self.value(raw)
    }

    /// A film, by TMDB id, else IMDb id. Never the show maps: the id numbers overlap.
    func movieScore(ids: [String: String]) -> Double? {
        var raw: Int?
        if let id = ids["tmdb"] { raw = tmdbMovie[id] }
        if raw == nil, let id = ids["imdb"] { raw = imdbMovie[id.lowercased()] }
        return Self.value(raw)
    }

    private static func value(_ raw: Int?) -> Double? {
        guard let raw, raw > 0, raw <= 1000 else { return nil }
        return Double(raw) / 100
    }
}

nonisolated enum AnimeScores {

    /// Bool; absent = on.
    static let enabledKey = "animeScoresEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static let resourceName = "AnimeScores"

    private static func fileURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: resourceName, withExtension: "json")
            ?? bundle.url(forResource: resourceName, withExtension: "json", subdirectory: "Resources")
    }

    /// Whether this build carries the file at all (the Settings row shows only then).
    static let isBundled = fileURL(in: .main) != nil

    private static let table = OSAllocatedUnfairLock<AnimeScoreTable?>(initialState: nil)

    static var loaded: AnimeScoreTable? { table.withLock { $0 } }

    /// Reads the bundled file once, off the main thread. No file: nothing happens.
    static func loadAtLaunch(bundle: Bundle = .main) {
        guard let url = fileURL(in: bundle) else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? Data(contentsOf: url), let read = AnimeScoreTable(data: data) else { return }
            table.withLock { $0 = read }
        }
    }

    /// Tests install their own table (the test host is the app, which may carry the real file).
    static func install(_ new: AnimeScoreTable?) { table.withLock { $0 = new } }

    /// What a page shows; nil when off, not loaded yet, or the title is not in the file.
    /// `ids` are the film's own, or the SHOW's for a show, season or episode.
    static func score(kind: MediaKind, ids: [String: String], season: Int?) -> Double? {
        guard isEnabled, !ids.isEmpty, let table = loaded else { return nil }
        switch kind {
        case .movie: return table.movieScore(ids: ids)
        case .show: return table.showScore(ids: ids, season: nil)
        case .season, .episode: return table.showScore(ids: ids, season: season)
        default: return nil
        }
    }
}
