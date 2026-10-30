// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension SiloProvider {
    func collections(in library: MediaLibrary) async throws -> [MediaItem] {
        let path = Self.pathComponent(library.id)
        let curated: SiloCuratedCollections = try await client.get("library/\(path)/collections")
        let personal: SiloList<SiloCollection> = try await client.get("library/\(path)/user-collections")
        // Both endpoints already apply profile visibility and server ordering.
        // Imported/synced/manual/smart collections all use their native source.
        return curated.collections.map { collectionItem($0, libraryID: library.id) }
            + personal.items.map { collectionItem($0, libraryID: nil, contextLibraryID: library.id) }
    }

    func collectionItem(_ collection: SiloCollection, libraryID: String?, contextLibraryID: String? = nil) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: id, itemID: SiloCollectionRef(collectionId: collection.id, libraryId: libraryID).itemID),
                  kind: .collection, title: collection.title ?? collection.name ?? "", sortTitle: nil,
                  overview: collection.description, year: nil, runtime: nil,
                  parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
                  childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: collection.posterUrl.flatMap(client.mediaURL),
                                        backdrop: collection.backdropUrl.flatMap(client.mediaURL), thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil, libraryID: contextLibraryID ?? libraryID)
    }

    func watchlistItems() async throws -> [MediaItem] {
        let native: [SiloItem] = try await allItems("watchlist", query: Self.artworkQuery)
        let status: SiloRequestStatus = try await client.get("requests/status")
        guard status.watchlistTitlesSupported else { return map(native) }
        let external: [SiloWatchlistTitle] = try await allItems("watchlist/titles")
        return map(native) + external.map(externalItem)
    }

    func externalItem(_ title: SiloWatchlistTitle) -> MediaItem {
        let poster = title.posterPath.flatMap { path in
            path.hasPrefix("/") ? URL(string: "https://image.tmdb.org/t/p/w780\(path)") : nil
        }
        return MediaItem(
            ref: MediaItemRef(providerID: id, itemID: "external:\(title.mediaType):\(title.tmdbId)"),
            kind: title.mediaType == "series" ? .show : .movie, title: title.title,
            sortTitle: nil, overview: nil, year: title.year, releaseDate: title.releaseDate,
            contentRating: title.contentRating, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: poster, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil,
            identity: ["\(title.mediaType == "series" ? "s" : "m"):tmdb:\(title.tmdbId)"], isAvailable: false
        )
    }

    private func externalTitlePath(_ ref: MediaItemRef) throws -> String? {
        guard ref.itemID.hasPrefix("external:") else { return nil }
        let parts = ref.itemID.split(separator: ":")
        guard parts.count == 3, ["movie", "series"].contains(String(parts[1])), Int(parts[2]) != nil else {
            throw MediaProviderError.notFound
        }
        return "watchlist/titles/\(parts[1])/\(parts[2])"
    }

    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool {
        if ref.itemID.hasPrefix("external:") {
            return (try? await watchlistItems().contains { $0.ref == ref }) ?? false
        }
        let membership: SiloMembership? = try? await client.get("watchlist/\(Self.pathComponent(ref.itemID))/membership")
        return membership?.isMember ?? false
    }

    func addToWatchlist(_ ref: MediaItemRef) async throws {
        let path = try externalTitlePath(ref) ?? "watchlist/\(Self.pathComponent(ref.itemID))"
        try await client.put(path)
    }

    func removeFromWatchlist(_ ref: MediaItemRef) async throws {
        let path = try externalTitlePath(ref) ?? "watchlist/\(Self.pathComponent(ref.itemID))"
        try await client.delete(path)
    }

    func isFavorite(_ ref: MediaItemRef) async -> Bool {
        guard !ref.itemID.hasPrefix("external:") else { return false }
        let membership: SiloMembership? = try? await client.get("favorites/\(Self.pathComponent(ref.itemID))/membership")
        return membership?.isMember ?? false
    }

    func setFavorite(_ ref: MediaItemRef, isFavorite: Bool) async throws {
        guard !ref.itemID.hasPrefix("external:") else { throw MediaProviderError.notFound }
        let path = "favorites/\(Self.pathComponent(ref.itemID))"
        if isFavorite { try await client.put(path) } else { try await client.delete(path) }
    }
}
