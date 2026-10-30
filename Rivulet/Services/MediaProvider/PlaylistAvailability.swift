// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlaylistAvailability.swift
//  Rivulet
//
//  Which servers have video playlists: the sidebar shows a Playlists row for each.
//

import Foundation

@MainActor @Observable
final class PlaylistAvailability {
    static let shared = PlaylistAvailability()

    /// Each server's video playlists, by provider id. Only servers with at least one.
    private(set) var playlistsByProvider: [String: [MediaPlaylist]] = [:]
    private(set) var providerIDs: Set<String> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Asks the selected Plex server and the other signed-in servers.
    func refresh() async {
        let registry = MediaProviderRegistry.shared
        await refresh(from: [registry.plexProvider].compactMap { $0 }
            + ServerDataStore.shared.sources.compactMap { registry.provider(for: $0.providerID) })
    }

    /// Each call cancels the one before, so a slow older answer never overwrites a newer one.
    /// A server that fails keeps its last answer, so a blip does not drop its row.
    func refresh(from providers: [any MediaProvider]) async {
        refreshTask?.cancel()
        let task = Task {
            var next: [String: [MediaPlaylist]] = [:]
            await withTaskGroup(of: (String, [MediaPlaylist]?).self) { group in
                for provider in providers where provider.supportsPlaylists {
                    let id = provider.id
                    group.addTask { (id, try? await provider.videoPlaylists()) }
                }
                for await (id, lists) in group {
                    if let lists = lists ?? playlistsByProvider[id], !lists.isEmpty { next[id] = lists }
                }
            }
            guard !Task.isCancelled else { return }
            playlistsByProvider = next
            let ids = Set(next.keys)
            if ids != providerIDs { providerIDs = ids }
        }
        refreshTask = task
        await task.value
    }
}
