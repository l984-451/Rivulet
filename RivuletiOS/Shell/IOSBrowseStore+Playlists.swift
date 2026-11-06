// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Video playlists on every server that has them: browse, play and edit through the provider.
extension IOSBrowseStore {
    /// A playlist's rows, in the server's order.
    func playlistContents(_ playlist: MediaPlaylist) async throws -> PlaylistContents {
        try await provider(for: playlist.item.ref).playlistEntries(playlist.item.ref)
    }

    /// The kinds a playlist takes; a show or season adds its episodes.
    static func canAddToPlaylist(_ item: MediaItem) -> Bool {
        item.kind.plexType != nil && !item.ref.itemID.isEmpty
    }

    func supportsPlaylists(_ item: MediaItem) -> Bool {
        Self.canAddToPlaylist(item) && provider(for: item.ref.providerID)?.supportsPlaylists == true
    }

    /// Regular playlists on the item's server, by title: the Add to Playlist choices.
    func addTargets(for item: MediaItem) -> [MediaPlaylist] {
        PlaylistRules.addTargets(playlists(providerID: item.ref.providerID), isSmart: \.isSmart, title: \.item.title)
    }

    func createPlaylist(title: String, seededWith item: MediaItem) async throws {
        _ = try await provider(for: item.ref).createPlaylist(title: title, seededWith: [item.ref])
        await refreshPlaylists()
    }

    func addToPlaylist(_ playlist: MediaPlaylist, item: MediaItem) async throws {
        try await provider(for: playlist.item.ref).addToPlaylist(playlist.item.ref, items: [item.ref])
        await refreshPlaylists()
    }

    func removeFromPlaylist(_ playlist: MediaPlaylist, entry: PlaylistEntry) async throws {
        try await provider(for: playlist.item.ref).removeFromPlaylist(playlist.item.ref, entryID: entry.entryID)
        await refreshPlaylists()
    }

    /// Moves `entry` to `toIndex` in `entries` (the list before the move).
    func movePlaylistEntry(_ playlist: MediaPlaylist, entry: PlaylistEntry, toIndex: Int, in entries: [PlaylistEntry]) async throws {
        try await provider(for: playlist.item.ref).movePlaylistEntry(playlist.item.ref, entryID: entry.entryID,
                                                                     toIndex: toIndex, in: entries)
    }

    func renamePlaylist(_ playlist: MediaPlaylist, to title: String) async throws {
        try await provider(for: playlist.item.ref).renamePlaylist(playlist.item.ref, title: title)
        await refreshPlaylists()
    }

    func deletePlaylist(_ playlist: MediaPlaylist) async throws {
        try await provider(for: playlist.item.ref).deletePlaylist(playlist.item.ref)
        HomePlaylistPins.unpinEverywhere(playlist.item.ref)
        await refreshPlaylists()
    }
}
