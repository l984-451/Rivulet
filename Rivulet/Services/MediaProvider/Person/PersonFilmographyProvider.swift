// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonFilmographyProvider.swift
//  Rivulet
//
//  Turns a MediaPerson into a PersonDetail:
//    - Filmography: the person's titles on the user's Plex server, via a
//      server-wide `?actor=` filter (Plex is the filmography source).
//    - Biography + portrait: TMDB (Plex exposes no actor-bio API). Resolved via
//      the originating title's TMDB credits + a name match, then /tmdb/person.
//  The two data sources are injected so the logic unit-tests with fakes.
//

import Foundation

// MARK: - Default server filmography (server-wide ?actor= lookup)

/// Actor hub entries from `/hubs/search`: `id` is the actor tag id.
private nonisolated struct PlexActorSearchContainer: Codable, Sendable {
    let MediaContainer: Inner
    struct Inner: Codable, Sendable { let Hub: [Hub]? }
    struct Hub: Codable, Sendable {
        let type: String
        let Directory: [Actor]?
    }
    // Optional so a non-actor hub's Directory shape can't fail the decode.
    struct Actor: Codable, Sendable {
        let id: Int?
        let tag: String?
    }
}

/// The actor's titles across the whole server. Actor tag ids are server-wide
/// (the same id in every section), so `/library/all?type=&actor=` covers every
/// library in one call per kind. Returns [] on any failure.
private let _defaultServerFilmography: @Sendable (_ person: MediaPerson) async -> [MediaItem] = { person in
    let (serverURL, token, providerID): (String?, String?, String) = await MainActor.run {
        let url = PlexAuthManager.shared.selectedServerURL
        let tok = PlexAuthManager.shared.selectedServerToken
        let pid = MediaProviderRegistry.shared.plexProvider?.id ?? url.map { "plex:\($0)" } ?? "plex:unknown"
        return (url, tok, pid)
    }
    guard let serverURL, let token else { return [] }
    let headers = await PlexNetworkManager.shared.plexHeaders(authToken: token)

    var actorId = person.originActorId
    if actorId == nil {
        actorId = await searchActorId(serverURL: serverURL, name: person.name, headers: headers)
    }
    guard let actorId else { return [] }

    // Plex type 1 = movie, 2 = show.
    async let movies = libraryItems(serverURL: serverURL, type: 1, actorId: actorId,
                                    providerID: providerID, token: token, headers: headers)
    async let shows = libraryItems(serverURL: serverURL, type: 2, actorId: actorId,
                                   providerID: providerID, token: token, headers: headers)
    return await movies + shows
}

/// Case/diacritic-insensitive name key.
private func normalizedActorName(_ s: String) -> String {
    s.folding(options: .diacriticInsensitive, locale: .current)
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Resolve an actor tag id by name through server search, for cast that
/// arrives without a Plex `filter` id.
private func searchActorId(serverURL: String, name: String, headers: [String: String]) async -> String? {
    guard var components = URLComponents(string: "\(serverURL)/hubs/search") else { return nil }
    components.queryItems = [URLQueryItem(name: "query", value: name), URLQueryItem(name: "limit", value: "10")]
    guard let url = components.url else { return nil }
    let container: PlexActorSearchContainer? = try? await PlexNetworkManager.shared.request(url, headers: headers)
    let target = normalizedActorName(name)
    return container?.MediaContainer.Hub?
        .filter { $0.type == "actor" }
        .flatMap { $0.Directory ?? [] }
        .first { $0.tag.map(normalizedActorName) == target }?
        .id.map(String.init)
}

/// Every title of one Plex type featuring the actor, across all libraries.
private func libraryItems(serverURL: String, type: Int, actorId: String, providerID: String, token: String, headers: [String: String]) async -> [MediaItem] {
    guard var components = URLComponents(string: "\(serverURL)/library/all") else { return [] }
    components.queryItems = [URLQueryItem(name: "type", value: String(type)),
                             URLQueryItem(name: "actor", value: actorId)]
    guard let url = components.url else { return [] }
    let container: PlexMediaContainerWrapper? = try? await PlexNetworkManager.shared.request(url, headers: headers)
    let metadatas = container?.MediaContainer.Metadata ?? []
    return metadatas.compactMap { PlexMediaMapper.item($0, providerID: providerID, serverURL: serverURL, authToken: token) }
}

// MARK: - Default biography lookup (TMDB)

/// TMDB biography only — the portrait stays the Plex role thumb (see
/// TMDBClient.actorBiography). Returns nil if the actor can't be resolved.
private let _defaultBiography: @Sendable (MediaPerson) async -> String? = { person in
    guard let titleTmdbId = person.titleTmdbId else { return nil }
    let type: TMDBMediaType = person.titleIsMovie ? .movie : .tv
    return await TMDBClient.shared.actorBiography(titleTmdbId: titleTmdbId, type: type, actorName: person.name)
}

// MARK: - Provider

@MainActor
final class PersonFilmographyProvider: PersonFilmographyProviding {

    /// Cross-section server filmography for the person (all on-server titles,
    /// any library). Injected for tests.
    private let serverFilmographyItems: @Sendable (_ person: MediaPerson) async -> [MediaItem]
    private let biography: @Sendable (MediaPerson) async -> String?

    nonisolated init(
        serverFilmographyItems: @escaping @Sendable (_ person: MediaPerson) async -> [MediaItem] = _defaultServerFilmography,
        biography: @escaping @Sendable (MediaPerson) async -> String? = _defaultBiography
    ) {
        self.serverFilmographyItems = serverFilmographyItems
        self.biography = biography
    }

    nonisolated func load(person: MediaPerson) async throws -> PersonDetail {
        async let filmTask = serverFilmography(person)
        async let bioTask = biography(person)
        let (movies, shows) = await filmTask
        let bio = await bioTask
        return PersonDetail(
            id: person.tagKey ?? person.id,
            name: person.name,
            biography: bio,
            // Portrait is ALWAYS the Plex role thumb (stable from first paint);
            // we never swap in a TMDB image. See TMDBClient.actorBiography.
            portraitURL: person.imageURL,
            movies: movies,
            shows: shows)
    }

    /// Cross-section server `?actor=` filmography, bucketed by kind. All on-server.
    nonisolated private func serverFilmography(_ person: MediaPerson) async -> (movies: [FilmographyEntry], shows: [FilmographyEntry]) {
        var movies: [FilmographyEntry] = []
        var shows: [FilmographyEntry] = []
        let items = await serverFilmographyItems(person)
        for item in items {
            let entry = FilmographyEntry(item: item, isOnServer: true)
            switch item.kind {
            case .movie: movies.append(entry)
            case .show: shows.append(entry)
            default: break
            }
        }
        return (movies, shows)
    }
}
