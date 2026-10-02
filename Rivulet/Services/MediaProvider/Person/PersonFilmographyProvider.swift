// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonFilmographyProvider.swift
//  Rivulet
//
//  Turns a MediaPerson into a PersonDetail:
//    - Filmography: the person's titles on the user's Plex server, via the
//      origin library `?actor=` filter (Plex is the filmography source).
//    - Biography + portrait: TMDB (Plex exposes no actor-bio API). Resolved via
//      the originating title's TMDB credits + a name match, then /tmdb/person.
//  The two data sources are injected so the logic unit-tests with fakes.
//

import Foundation

// MARK: - Filter-choice DTO (per-section actor tag list)

/// One entry from a section's actor filter choices
/// (`/library/sections/{key}/actor`): `key` is the section-LOCAL actor tag id,
/// `title` the actor name. Decoded with a minimal DTO because these Directory
/// entries carry far fewer fields than a library `PlexLibrary` Directory.
///
/// Some PMS versions surface the id only in `fastKey` (the full path form,
/// `/library/sections/X/all?actor=49`) and put a non-numeric value in `key`, so
/// we accept both and prefer the `actor=` value parsed out of `fastKey` when
/// present. `actorId` is the value to feed back into `?actor=`.
private nonisolated struct PlexFilterChoiceContainer: Codable, Sendable {
    let MediaContainer: Inner
    struct Inner: Codable, Sendable { let Directory: [Choice]? }
    struct Choice: Codable, Sendable {
        let key: String?
        let fastKey: String?
        let title: String

        /// Section-local actor id: the `actor=` query value from `fastKey` if it
        /// carries one, else the raw `key`.
        var actorId: String? {
            if let fastKey,
               let comps = URLComponents(string: fastKey),
               let v = comps.queryItems?.first(where: { $0.name == "actor" })?.value,
               !v.isEmpty {
                return v
            }
            return (key?.isEmpty == false) ? key : nil
        }
    }
}

// MARK: - Default server filmography (cross-section ?actor= lookup)

/// The actor's titles across the WHOLE server, not just the section we came
/// from. Plex actor tag ids are PER-SECTION (the id parsed from one title's
/// `filter` only matches that title's library), so querying only the origin
/// section returns just that medium — e.g. opening an actor from a movie would
/// never surface their shows. We instead enumerate every movie/show section,
/// resolve the actor's section-local id by NAME via that section's actor filter
/// choices, then `?actor=<localId>` per section. Returns ([],[]) on any failure.
private let _defaultServerFilmography: @Sendable (_ person: MediaPerson) async -> [MediaItem] = { person in
    let (serverURL, token, providerID): (String?, String?, String) = await MainActor.run {
        let url = PlexAuthManager.shared.selectedServerURL
        let tok = PlexAuthManager.shared.selectedServerToken
        let pid = MediaProviderRegistry.shared.plexProvider?.id ?? url.map { "plex:\($0)" } ?? "plex:unknown"
        return (url, tok, pid)
    }
    guard let serverURL, let token else { return [] }
    let headers = await PlexNetworkManager.shared.plexHeaders(authToken: token)
    let targetName = normalizedActorName(person.name)

    // 1. Enumerate movie + show library sections.
    let libraries = (try? await PlexNetworkManager.shared.getLibraries(serverURL: serverURL, authToken: token)) ?? []
    let sections = libraries.filter { $0.type == "movie" || $0.type == "show" }
    guard !sections.isEmpty else { return [] }

    // 2-4. Per section: resolve the actor's local id by name, then ?actor=<id>.
    //      The origin section can skip the name resolve (we already have its id).
    var all: [MediaItem] = []
    var seenItemIDs = Set<String>()
    for section in sections {
        let localActorId: String?
        if section.key == person.originSectionKey, let originId = person.originActorId {
            localActorId = originId
        } else {
            localActorId = await resolveActorId(
                serverURL: serverURL, sectionKey: section.key, name: targetName, headers: headers)
        }
        guard let actorId = localActorId else { continue }
        let items = await sectionItems(
            serverURL: serverURL, sectionKey: section.key, actorId: actorId,
            providerID: providerID, token: token, headers: headers)
        for item in items where seenItemIDs.insert(item.ref.itemID).inserted {
            all.append(item)
        }
    }
    return all
}

/// Case/diacritic-insensitive name key for matching across sections.
private func normalizedActorName(_ s: String) -> String {
    s.folding(options: .diacriticInsensitive, locale: .current)
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Fetch a section's actor filter choices and return the tag `key` whose title
/// matches `name` (already normalized). nil if the section has no such actor.
private func resolveActorId(serverURL: String, sectionKey: String, name: String, headers: [String: String]) async -> String? {
    guard let url = URL(string: "\(serverURL)/library/sections/\(sectionKey)/actor") else { return nil }
    let container: PlexFilterChoiceContainer? = try? await PlexNetworkManager.shared.request(url, headers: headers)
    let choices = container?.MediaContainer.Directory ?? []
    return choices.first { normalizedActorName($0.title) == name }?.actorId
}

/// Query one section by its local actor id and map to on-server MediaItems.
private func sectionItems(serverURL: String, sectionKey: String, actorId: String, providerID: String, token: String, headers: [String: String]) async -> [MediaItem] {
    guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionKey)/all") else { return [] }
    components.queryItems = [URLQueryItem(name: "actor", value: actorId)]
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
