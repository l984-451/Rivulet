// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyProvider+Playlists.swift
//  Rivulet
//
//  Video playlists. A playlist is private to its owner in listings, so every write here
//  targets one the signed-in user owns. A Series id added to one expands to its episodes
//  server-side.
//

import Foundation

extension EmbyProvider {
    var supportsPlaylists: Bool { true }

    private static let pageSize = 200

    private static func playlist(_ dto: EmbyItem, providerID: String, baseURL: URL) -> MediaPlaylist {
        MediaPlaylist(item: EmbyMediaMapper.item(dto, providerID: providerID, baseURL: baseURL), isSmart: false)
    }

    /// The playlist DTO has no `MediaType`, so audio is whatever a music library lists under its
    /// `ParentId` (measured: that returns only audio playlists) and video is the rest. An empty
    /// playlist shows under no library, so an empty audio one lists here as video.
    func videoPlaylists() async throws -> [MediaPlaylist] {
        let views: EmbyQueryResult = try await client.get("Users/\(userID)/Views")
        let everything = try await playlists(under: nil)
        var audio = Set<String>()
        for view in views.items ?? [] where view.collectionType == "music" {
            audio.formUnion(try await playlists(under: view.id.value).map(\.id.value))
        }
        return everything.filter { !audio.contains($0.id.value) }
            .map { Self.playlist($0, providerID: id, baseURL: baseURL) }
            .sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
    }

    private func playlists(under parentID: String?) async throws -> [EmbyItem] {
        var params = [
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            URLQueryItem(name: "Recursive", value: "true"),
            Self.listFields
        ]
        if let parentID { params.append(URLQueryItem(name: "ParentId", value: parentID)) }
        let result: EmbyQueryResult = try await client.get(itemsPath, params)
        return result.items ?? []
    }

    /// The server's own `PlaylistItemId` is the entry id. Ids renumber after every add and remove,
    /// so callers refetch and nothing here caches them. A row without one cannot be removed or
    /// moved (a media id in its place removes nothing, or the wrong entry), so it is left out.
    func playlistEntries(_ playlist: MediaItemRef) async throws -> PlaylistContents {
        var entries: [PlaylistEntry] = []
        var fetched = 0
        while true {
            let page: EmbyQueryResult = try await client.get("Playlists/\(playlist.itemID)/Items", [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "StartIndex", value: String(fetched)),
                URLQueryItem(name: "Limit", value: String(Self.pageSize)),
                Self.listFields
            ])
            let rows = page.items ?? []
            fetched += rows.count
            entries += rows.compactMap { dto in
                dto.playlistItemId.map {
                    PlaylistEntry(entryID: $0.value, item: EmbyMediaMapper.item(dto, providerID: id, baseURL: baseURL))
                }
            }
            if rows.isEmpty || fetched >= (page.totalRecordCount ?? fetched) {
                return PlaylistContents(entries: entries, isSmart: false)
            }
        }
    }

    /// `Ids` is a comma string in the query (a JSON array is a 500). The reply has no item, so it is read back.
    func createPlaylist(title: String, seededWith items: [MediaItemRef]) async throws -> MediaPlaylist {
        var query = [URLQueryItem(name: "Name", value: title), URLQueryItem(name: "MediaType", value: "Video"),
                     URLQueryItem(name: "UserId", value: userID)]
        if !items.isEmpty { query.append(Self.idsQuery(items)) }
        let created: EmbyCreatedPlaylist = try await client.post("Playlists", query: query)
        let dto: EmbyItem = try await client.get("\(itemsPath)/\(created.id.value)", [Self.listFields])
        return Self.playlist(dto, providerID: id, baseURL: baseURL)
    }

    func addToPlaylist(_ playlist: MediaItemRef, items: [MediaItemRef]) async throws {
        guard !items.isEmpty else { return }
        try await client.post("Playlists/\(playlist.itemID)/Items", query: [
            Self.idsQuery(items), URLQueryItem(name: "UserId", value: userID)
        ])
    }

    func removeFromPlaylist(_ playlist: MediaItemRef, entryID: String) async throws {
        try await client.delete("Playlists/\(playlist.itemID)/Items", query: [URLQueryItem(name: "EntryIds", value: entryID)])
    }

    /// Emby's `newIndex` is the entry's final 0-based index, so `toIndex` goes through, kept inside
    /// the list: out of range is a 400.
    func movePlaylistEntry(_ playlist: MediaItemRef, entryID: String, toIndex: Int, in entries: [PlaylistEntry]) async throws {
        let last = entries.isEmpty ? toIndex : entries.count - 1
        let index = min(max(toIndex, 0), max(last, 0))
        try await client.post(Self.movePath(playlist: playlist.itemID, entryID: entryID, toIndex: index))
    }

    nonisolated static func movePath(playlist: String, entryID: String, toIndex: Int) -> String {
        "Playlists/\(playlist)/Items/\(entryID)/Move/\(toIndex)"
    }

    /// There is no playlist route for it: the item update takes `ProviderIds` too (400 without).
    func renamePlaylist(_ playlist: MediaItemRef, title: String) async throws {
        try await client.post("Items/\(playlist.itemID)", body: EmbyRenameItem(name: title))
    }

    /// `CanDelete` is false on playlists for everyone, so the owner-only listing is the gate.
    func deletePlaylist(_ playlist: MediaItemRef) async throws {
        try await client.delete("Items/\(playlist.itemID)")
    }

    private static func idsQuery(_ items: [MediaItemRef]) -> URLQueryItem {
        URLQueryItem(name: "Ids", value: items.map(\.itemID).joined(separator: ","))
    }
}
