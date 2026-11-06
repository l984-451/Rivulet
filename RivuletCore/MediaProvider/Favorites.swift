// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Favorites.swift
//  Rivulet
//
//  Favorite movies and shows across every signed-in Jellyfin and Emby server,
//  for the tvOS sidebar's Favorites page and the iOS Favorites list. Each
//  server keeps its own flag. Plex has the watchlist instead, so it has none.
//

import Foundation

enum FavoritesOrder {
    /// Title order across servers, as a library sorts by title: sort title first, numbers by value.
    nonisolated static func byTitle(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
    }

    nonisolated private static func key(_ item: MediaItem) -> String {
        item.sortTitle?.isEmpty == false ? item.sortTitle! : item.title
    }
}

@MainActor
enum FavoritesFeed {
    /// Posted after a favorite is added or removed, with the item's ref as the object.
    static let didChange = Notification.Name("favoritesDidChange")

    /// Per server; a favorites list is a hand-picked set, far below this.
    static let limit = 500

    /// The servers that keep favorites (Jellyfin, Emby), in sidebar order.
    static func providers(in registry: MediaProviderRegistry = .shared) -> [any MediaProvider] {
        ([registry.plexProvider].compactMap { $0 } + registry.secondaryProviders).filter(\.supportsFavorites)
    }

    /// Whether any signed-in server keeps favorites: the Favorites row shows only then.
    static var isAvailable: Bool { !providers().isEmpty }

    /// Every server's favorites, merged by title. A server that fails drops out on its own.
    static func load(from providers: [any MediaProvider]? = nil) async -> [MediaItem] {
        let servers = providers ?? Self.providers()
        let limit = Self.limit
        let found = await withTaskGroup(of: [MediaItem].self) { group in
            for provider in servers {
                group.addTask { (try? await provider.favorites(limit: limit)) ?? [] }
            }
            return await group.reduce(into: [MediaItem]()) { $0 += $1 }
        }
        return FavoritesOrder.byTitle(found)
    }

    /// Whether the item's server keeps favorites, so a menu offers the action.
    static func canFavorite(_ item: MediaItem) -> Bool {
        guard item.kind == .movie || item.kind == .show else { return false }
        return MediaProviderRegistry.shared.provider(for: item.ref.providerID)?.supportsFavorites == true
    }

    /// Adds or removes a favorite on the item's server, then tells every surface.
    static func set(_ favorite: Bool, for item: MediaItem) async throws {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            throw MediaProviderError.notFound
        }
        try await provider.setFavorite(favorite, for: item.ref)
        NotificationCenter.default.post(name: didChange, object: item.ref)
    }
}
