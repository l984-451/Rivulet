// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Builds a PersonDetail: filmography from the person's own server (`MediaProvider.filmography`),
// Known For from Plex Discover minus titles on the server, biography from Discover, else the
// server, else TMDB.

import Foundation

// MARK: - Default server filmography

/// The server a person's titles come from: their own, else (a TMDB person) the selected Plex
/// server, else the first other server.
@MainActor
func personServer(for person: MediaPerson) -> (any MediaProvider)? {
    let registry = MediaProviderRegistry.shared
    if let id = person.providerID { return registry.provider(for: id) }
    return registry.plexProvider ?? registry.secondaryProviders.first
}

/// The person's titles on their server. Returns [] on any failure.
private let _defaultServerFilmography: @Sendable (_ person: MediaPerson) async -> [FilmographyEntry] = { person in
    guard let provider = await personServer(for: person) else { return [] }
    return (try? await provider.filmography(of: person)) ?? []
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

/// Discover person summary, else the server's, else TMDB. The portrait stays the server's
/// (see TMDBClient.actorBiography). Returns nil if the person can't be resolved.
private let _defaultBiography: @Sendable (MediaPerson) async -> String? = { person in
    if let tagKey = person.tagKey,
       let summary = await discoverItems("/library/people/\(tagKey)").first?.summary,
       !summary.isEmpty {
        return summary
    }
    if let provider = await personServer(for: person),
       let summary = await provider.biography(of: person), !summary.isEmpty {
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
