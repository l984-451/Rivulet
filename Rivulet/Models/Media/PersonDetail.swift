// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// One title in a person's filmography, plus whether it exists on the user's server.
struct FilmographyEntry: Hashable, Sendable {
    let item: MediaItem        // playable (plex provider) when isOnServer, else metadata-only ("tmdb")
    let isOnServer: Bool
    var guid: String? = nil    // plex://movie/... or plex://show/..., for matching across server and Discover
    var tmdbId: Int? = nil

    /// `titles` minus any already in `onServer`, matched by plex guid or by TMDB
    /// id within the same kind (movie and TV TMDB ids share a number space).
    static func excluding(_ onServer: [FilmographyEntry], from titles: [FilmographyEntry]) -> [FilmographyEntry] {
        func tmdbKey(_ e: FilmographyEntry) -> String? { e.tmdbId.map { "\(e.item.kind)-\($0)" } }
        let guids = Set(onServer.compactMap(\.guid))
        let tmdbKeys = Set(onServer.compactMap(tmdbKey))
        return titles.filter { title in
            !(title.guid.map(guids.contains) ?? false) && !(tmdbKey(title).map(tmdbKeys.contains) ?? false)
        }
    }
}

/// Fully resolved data backing the person detail page.
struct PersonDetail: Hashable, Sendable {
    let id: String             // Discover person key (role tagKey) or a synthetic fallback id
    let name: String
    let biography: String?
    let portraitURL: URL?
    let movies: [FilmographyEntry]   // server entries sorted first
    let shows: [FilmographyEntry]    // server entries sorted first
}

/// Seam the view controller depends on. The concrete Plex/Discover wiring lives behind it.
protocol PersonFilmographyProviding: Sendable {
    func load(person: MediaPerson) async throws -> PersonDetail
    /// Plex Discover's Known For titles, unfiltered. Loaded separately so it
    /// never holds up the server rows.
    func knownFor(person: MediaPerson) async -> [FilmographyEntry]
}

extension PersonFilmographyProviding {
    func knownFor(person: MediaPerson) async -> [FilmographyEntry] { [] }
}
