// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonFilmographyProvider.swift
//  Rivulet
//
//  Turns a MediaPerson into a PersonDetail:
//    - Filmography: the person's titles on the user's Plex server, via a
//      server-wide `?actor=` filter.
//    - Known For: Plex Discover's list for the person, minus titles already on
//      the server, as metadata-only items.
//    - Biography: the Discover person's summary, else TMDB.
//  The data sources are injected so the logic unit-tests with fakes.
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
private let _defaultServerFilmography: @Sendable (_ person: MediaPerson) async -> [FilmographyEntry] = { person in
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
private func libraryItems(serverURL: String, type: Int, actorId: String, providerID: String, token: String, headers: [String: String]) async -> [FilmographyEntry] {
    guard var components = URLComponents(string: "\(serverURL)/library/all") else { return [] }
    components.queryItems = [URLQueryItem(name: "type", value: String(type)),
                             URLQueryItem(name: "actor", value: actorId),
                             URLQueryItem(name: "includeGuids", value: "1")]
    guard let url = components.url else { return [] }
    let container: PlexMediaContainerWrapper? = try? await PlexNetworkManager.shared.request(url, headers: headers)
    let metadatas = container?.MediaContainer.Metadata ?? []
    return metadatas.map { meta in
        FilmographyEntry(item: PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token),
                         isOnServer: true, guid: meta.guid, tmdbId: meta.tmdbId)
    }
}

// MARK: - Plex Discover (bio + Known For)

/// Minimal Discover metadata: serves the person, the Known For hub, and the
/// batch metadata lookup.
private nonisolated struct DiscoverContainer: Codable, Sendable {
    let MediaContainer: Inner
    struct Inner: Codable, Sendable { let Metadata: [Item]? }
    struct Item: Codable, Sendable {
        let ratingKey: String?
        let guid: String?
        let type: String?
        let title: String?
        let year: Int?
        let thumb: String?
        let summary: String?
        let Guid: [Tag]?
    }
    struct Tag: Codable, Sendable { let id: String }
}

/// Discover needs the account token, not the server token.
private func discoverItems(_ path: String) async -> [DiscoverContainer.Item] {
    guard let token = await MainActor.run(body: { PlexAuthManager.shared.authToken }),
          let url = URL(string: "https://discover.provider.plex.tv\(path)") else { return [] }
    let headers = await PlexNetworkManager.shared.plexHeaders(authToken: token)
    let container: DiscoverContainer? = try? await PlexNetworkManager.shared.request(url, headers: headers)
    return container?.MediaContainer.Metadata ?? []
}

/// The person's Known For titles as metadata-only items keyed by TMDB id.
/// The hub carries no TMDB ids, so they come from a batch metadata fetch
/// (Discover caps a batch at 20 keys).
private let _defaultKnownFor: @Sendable (MediaPerson) async -> [FilmographyEntry] = { person in
    guard let tagKey = person.tagKey else { return [] }
    let titles = await discoverItems("/library/people/\(tagKey)/person_known_for")
        .filter { $0.type == "movie" || $0.type == "show" }
    let keys = titles.compactMap(\.ratingKey)
    let chunks = stride(from: 0, to: keys.count, by: 20).map { Array(keys[$0..<min($0 + 20, keys.count)]) }
    let tmdbByKey = await withTaskGroup(of: [DiscoverContainer.Item].self) { group in
        for chunk in chunks {
            group.addTask { await discoverItems("/library/metadata/\(chunk.joined(separator: ","))?includeGuids=1") }
        }
        var map: [String: Int] = [:]
        for await items in group {
            for item in items {
                guard let key = item.ratingKey,
                      let id = item.Guid?.lazy.compactMap({ PlexMetadata.extractTmdbId(from: $0.id) }).first else { continue }
                map[key] = id
            }
        }
        return map
    }
    return titles.compactMap { t in
        guard let key = t.ratingKey, let tmdbId = tmdbByKey[key], let title = t.title else { return nil }
        let item = PersonItemMapper.metadataOnlyItem(
            tmdbId: tmdbId, isMovie: t.type == "movie", title: title, year: t.year,
            posterURL: t.thumb.flatMap(URL.init(string:)), overview: t.summary)
        return FilmographyEntry(item: item, isOnServer: false, guid: t.guid, tmdbId: tmdbId)
    }
}

// MARK: - Default biography lookup

/// Discover person summary, else TMDB. The portrait stays the Plex role thumb
/// (see TMDBClient.actorBiography). Returns nil if the actor can't be resolved.
private let _defaultBiography: @Sendable (MediaPerson) async -> String? = { person in
    if let tagKey = person.tagKey,
       let summary = await discoverItems("/library/people/\(tagKey)").first?.summary,
       !summary.isEmpty {
        return summary
    }
    guard let titleTmdbId = person.titleTmdbId else { return nil }
    let type: TMDBMediaType = person.titleIsMovie ? .movie : .tv
    return await TMDBClient.shared.actorBiography(titleTmdbId: titleTmdbId, type: type, actorName: person.name)
}

// MARK: - Provider

@MainActor
final class PersonFilmographyProvider: PersonFilmographyProviding {

    /// Cross-section server filmography for the person (all on-server titles,
    /// any library). Injected for tests.
    private let serverFilmographyItems: @Sendable (_ person: MediaPerson) async -> [FilmographyEntry]
    private let biography: @Sendable (MediaPerson) async -> String?
    private let knownForTitles: @Sendable (MediaPerson) async -> [FilmographyEntry]

    nonisolated init(
        serverFilmographyItems: @escaping @Sendable (_ person: MediaPerson) async -> [FilmographyEntry] = _defaultServerFilmography,
        biography: @escaping @Sendable (MediaPerson) async -> String? = _defaultBiography,
        knownFor: @escaping @Sendable (MediaPerson) async -> [FilmographyEntry] = _defaultKnownFor
    ) {
        self.serverFilmographyItems = serverFilmographyItems
        self.biography = biography
        self.knownForTitles = knownFor
    }

    nonisolated func load(person: MediaPerson) async throws -> PersonDetail {
        async let serverTask = serverFilmographyItems(person)
        async let bioTask = biography(person)
        let (movies, shows) = Self.bucket(await serverTask)
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

    nonisolated func knownFor(person: MediaPerson) async -> [FilmographyEntry] {
        await knownForTitles(person)
    }

    /// Server filmography bucketed by kind. All on-server.
    nonisolated private static func bucket(_ titles: [FilmographyEntry]) -> (movies: [FilmographyEntry], shows: [FilmographyEntry]) {
        var movies: [FilmographyEntry] = []
        var shows: [FilmographyEntry] = []
        for entry in titles {
            switch entry.item.kind {
            case .movie: movies.append(entry)
            case .show: shows.append(entry)
            default: break
            }
        }
        return (movies, shows)
    }
}
