// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The same movie or episode in the account's other Plex libraries and servers, with their
/// files: what the detail page's Versions button lists beside the item on screen.
@MainActor
enum TitleCopies {
    /// Which server holds each plex:// guid. `PlexOwnedLookup.owners` outside tests.
    typealias Owners = @Sendable ([String], [PlexOwnedLookup.Server]) async -> [String: [PlexOwnedLookup.Match]]

    /// The copies other than `subject`, and the library `subject` itself was found in.
    struct Result {
        var copies: [VersionPicker.Copy] = []
        var library: String?
    }

    /// A movie: its copies found by guid or confirmed external id, each with its files.
    static func movie(_ subject: MediaItem, guid: String, externalIDs: [String: String],
                      on servers: [PlexOwnedLookup.Server], registry: MediaProviderRegistry = .shared,
                      owners: Owners = PlexOwnedLookup.owners(of:on:)) async -> Result {
        var result = Result()
        for (ref, library) in await titles(guid: guid, of: subject, externalIDs: externalIDs,
                                           on: servers, registry: registry, owners: owners) {
            if ref == subject.ref { result.library = library; continue }
            guard let copy = await copy(ref, library: library, registry: registry) else { continue }
            result.copies.append(copy)
        }
        return result
    }

    /// An episode: `/library/all?guid=` matches only movies and shows, never an episode, so find
    /// the show on each server and walk to the same season and episode number there.
    static func episode(_ episode: MediaItem, of show: MediaItem, showDetail: MediaItemDetail,
                        on servers: [PlexOwnedLookup.Server], registry: MediaProviderRegistry = .shared,
                        owners: Owners = PlexOwnedLookup.owners(of:on:)) async -> Result {
        var result = Result()
        guard let seasonNumber = episode.seasonNumber, let episodeNumber = episode.episodeNumber else { return result }
        for (showRef, library) in await titles(guid: showDetail.plexGUID, of: show, externalIDs: showDetail.externalIDs,
                                               on: servers, registry: registry, owners: owners) {
            if showRef == show.ref { result.library = library; continue }
            guard let provider = registry.provider(for: showRef.providerID),
                  let seasons = try? await provider.children(of: showRef),
                  let season = seasons.first(where: { $0.seasonNumber == seasonNumber }),
                  let episodes = try? await provider.children(of: season.ref),
                  let match = episodes.first(where: { $0.episodeNumber == episodeNumber }),
                  let copy = await copy(match.ref, library: library, registry: registry)
            else { continue }
            result.copies.append(copy)
        }
        return result
    }

    /// Every server's copy of `title` (the shown one included): by plex guid, then by a title
    /// search confirmed on a shared tmdb/tvdb/imdb id. The search runs on every server, the
    /// shown one too: a library using a legacy agent stores that agent's own guid, which a
    /// plex:// lookup cannot match, and it can sit beside a modern library on the same server.
    static func titles(guid: String?, of title: MediaItem, externalIDs: [String: String],
                       on servers: [PlexOwnedLookup.Server], registry: MediaProviderRegistry = .shared,
                       owners: Owners = PlexOwnedLookup.owners(of:on:)) async -> [(ref: MediaItemRef, library: String?)] {
        var found: [(ref: MediaItemRef, library: String?)] = []
        if let guid {
            for match in await owners([guid], servers)[guid] ?? [] {
                guard let ratingKey = match.item.ratingKey else { continue }
                found.append((MediaItemRef(providerID: match.server.id, itemID: ratingKey),
                              match.item.librarySectionTitle))
            }
        }
        guard !externalIDs.isEmpty else { return found }
        for server in servers {
            guard let provider = registry.provider(for: server.id),
                  let results = try? await provider.search(title.title) else { continue }
            let known = Set(found.map(\.ref)).union([title.ref])
            // A handful at most: the search ranks the exact title first.
            for candidate in results.filter({ $0.kind == title.kind && !known.contains($0.ref) }).prefix(4) {
                guard let detail = try? await provider.fullDetail(for: candidate.ref),
                      PlexOwnedLookup.sharesExternalID(detail.externalIDs, externalIDs) else { continue }
                found.append((candidate.ref, nil))
            }
        }
        return found
    }

    /// The item at `ref` with its files, named by its server; nil when it has none.
    static func copy(_ ref: MediaItemRef, library: String?,
                     registry: MediaProviderRegistry = .shared) async -> VersionPicker.Copy? {
        guard let provider = registry.provider(for: ref.providerID),
              let detail = try? await provider.fullDetail(for: ref),
              !detail.mediaSources.isEmpty else { return nil }
        return .init(item: detail.item, server: provider.displayName, sources: detail.mediaSources,
                     library: library ?? detail.library)
    }
}
