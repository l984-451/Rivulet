// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Favorites.swift
//  Rivulet
//
//  Marking a movie or show a favorite, and the Favorites page's list: every server's
//  favorites, composed from `MediaProvider.favorites(in:limit:)` over its movie and show
//  libraries (the same call Home's favorites rows make).
//

import Foundation

nonisolated enum FavoritesOrder {
    /// Title order across servers, as a library sorts by title: sort title first, numbers by value.
    static func byTitle(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
    }

    private static func key(_ item: MediaItem) -> String {
        item.sortTitle?.isEmpty == false ? item.sortTitle! : item.title
    }
}

@MainActor
enum FavoritesFeed {
    /// Per library; a favorites list is hand-picked, far below this.
    static let limit = 500

    /// Whether any of these servers keeps favorites: the page and its setting show only then.
    static func isAvailable(_ providers: [any MediaProvider]) -> Bool {
        PersonalRows.offersFavorites(providers)
    }

    /// Every server's favorite movies and shows, by title. A server or library that fails drops out.
    /// The same title on two servers appears twice.
    static func load(from providers: [any MediaProvider]) async -> [MediaItem] {
        let limit = Self.limit
        let found = await withTaskGroup(of: [MediaItem].self) { group in
            for provider in providers where provider.supportsFavorites {
                group.addTask {
                    let libraries = ((try? await provider.libraries()) ?? [])
                        .filter { PersonalRows.favoriteKinds.contains($0.kind) }
                    var items: [MediaItem] = []
                    for library in libraries {
                        items += (try? await provider.favorites(in: library, limit: limit)) ?? []
                    }
                    return items
                }
            }
            return await group.reduce(into: [MediaItem]()) { $0 += $1 }
        }
        return FavoritesOrder.byTitle(found)
    }

    /// Whether a menu or the detail page offers the heart for this item.
    static func canFavorite(_ item: MediaItem) -> Bool {
        guard item.kind == .movie || item.kind == .show else { return false }
        return MediaProviderRegistry.shared.provider(for: item.ref.providerID)?.supportsFavorites == true
    }

    /// Marks or clears the favorite on the item's server. Callers then post `.plexDataNeedsRefresh`
    /// (tvOS) or refresh the browse store (iOS), which refetch Home's favorites rows and the page.
    static func set(_ favorite: Bool, for item: MediaItem) async throws {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            throw MediaProviderError.notFound
        }
        try await provider.setFavorite(favorite, for: item.ref)
    }
}
