// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Video playlists on every server, read only: browse and play in order.
extension IOSPlexSession {
    /// Every server's video playlists, by `serverID ?? ""`. A server that fails keeps its last answer.
    func fetchVideoPlaylists() async -> [String: [PlexPlaylist]] {
        let ids: [String?] = [nil] + PlexExtraServers.shared.current.map(\.machineID)
        let servers = ids.map { ($0 ?? "", try? configuration(serverID: $0)) }
        let previous = videoPlaylists
        let network = network
        return await withTaskGroup(of: (String, [PlexPlaylist]?).self) { group in
            for (key, server) in servers {
                group.addTask {
                    guard let server else { return (key, nil) }
                    return (key, try? await network.getPlaylists(serverURL: server.serverURL, authToken: server.token, type: "video"))
                }
            }
            return await group.reduce(into: [:]) { result, answer in
                let lists = (answer.1 ?? previous[answer.0])?.sorted {
                    ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending
                }
                if let lists, !lists.isEmpty { result[answer.0] = lists }
            }
        }
    }

    func playlists(serverID: String?) -> [PlexPlaylist] { videoPlaylists[serverID ?? ""] ?? [] }

    /// A playlist's rows, stamped with their server.
    func playlistItems(_ playlist: PlexPlaylist, serverID: String?) async throws -> [PlexMetadata] {
        let (serverURL, token) = try configuration(serverID: serverID)
        let items = try await network.getAllPlaylistItems(serverURL: serverURL, authToken: token, ratingKey: playlist.ratingKey).items
        return Self.onServer(items, serverID)
    }
}

// MARK: - Editing

extension IOSPlexSession {
    /// The kinds a playlist takes; a show or season adds its episodes.
    static func canAddToPlaylist(_ item: PlexMetadata) -> Bool {
        item.ratingKey != nil && ["movie", "episode", "season", "show"].contains(item.type ?? "")
    }

    /// Regular playlists on the item's server, by title: the Add to Playlist choices.
    func addTargets(for item: PlexMetadata) -> [PlexPlaylist] {
        PlaylistRules.addTargets(playlists(serverID: item.serverID), isSmart: { $0.smart == true }, title: { $0.title ?? "" })
    }

    func createPlaylist(title: String, seededWith item: PlexMetadata) async throws {
        let (serverURL, token) = try configuration(serverID: item.serverID)
        let uri = PlexNetworkManager.libraryURI(
            machineIdentifier: try await machineIdentifier(serverID: item.serverID), ratingKeys: [item.ratingKey ?? ""])
        _ = try await network.createPlaylist(serverURL: serverURL, authToken: token, type: "video", title: title, uri: uri)
        await refreshPlaylists()
    }

    func addToPlaylist(_ playlist: PlexPlaylist, item: PlexMetadata) async throws {
        guard let key = item.ratingKey else { return }
        let (serverURL, token) = try configuration(serverID: item.serverID)
        try await network.addToPlaylist(
            serverURL: serverURL, authToken: token, playlistRatingKey: playlist.ratingKey,
            machineIdentifier: try await machineIdentifier(serverID: item.serverID), ratingKeys: [key])
        await refreshPlaylists()
    }

    func removeFromPlaylist(_ playlist: PlexPlaylist, entry: PlexMetadata, serverID: String?) async throws {
        guard let entryID = entry.playlistItemID else { return }
        let (serverURL, token) = try configuration(serverID: serverID)
        try await network.removePlaylistItem(
            serverURL: serverURL, authToken: token, playlistRatingKey: playlist.ratingKey, playlistItemID: String(entryID))
        await refreshPlaylists()
    }

    /// Moves `entry` to `toIndex` in `entries` (the list before the move).
    func movePlaylistEntry(_ playlist: PlexPlaylist, entry: PlexMetadata, toIndex: Int,
                           in entries: [PlexMetadata], serverID: String?) async throws {
        guard let entryID = entry.playlistItemID.map(String.init) else { return }
        let after = PlexNetworkManager.moveAfter(
            entryID: entryID, toIndex: toIndex, in: entries.compactMap { $0.playlistItemID.map(String.init) })
        let (serverURL, token) = try configuration(serverID: serverID)
        try await network.movePlaylistItem(
            serverURL: serverURL, authToken: token, playlistRatingKey: playlist.ratingKey,
            playlistItemID: entryID, after: after)
    }

    func renamePlaylist(_ playlist: PlexPlaylist, to title: String, serverID: String?) async throws {
        let (serverURL, token) = try configuration(serverID: serverID)
        try await network.renamePlaylist(serverURL: serverURL, authToken: token, playlistRatingKey: playlist.ratingKey, title: title)
        await refreshPlaylists()
    }

    func deletePlaylist(_ playlist: PlexPlaylist, serverID: String?) async throws {
        let (serverURL, token) = try configuration(serverID: serverID)
        try await network.deletePlaylist(serverURL: serverURL, authToken: token, playlistRatingKey: playlist.ratingKey)
        await refreshPlaylists()
    }

    /// The `uri` host: another server's id is its machineIdentifier already.
    private func machineIdentifier(serverID: String?) async throws -> String {
        if let serverID { return serverID }
        if let known = auth.selectedServerMachineID { return known }
        let (serverURL, token) = try configuration()
        return try await network.getMachineIdentifier(serverURL: serverURL, authToken: token)
    }
}
