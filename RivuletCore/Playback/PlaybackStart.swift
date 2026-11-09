// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// What a player session needs to start one title: the request, the backend that reports for it,
/// and a playlist's queue (which replaces Up Next).
struct PreparedPlayback {
    let request: PlexPlaybackRequest
    let backend: any PlayerBackend
    let queue: PlayQueue<PlexMetadata>?
}

/// The routing every app's `play(item)` shares. A show or season plays the episode Play means;
/// `sourceID` picks a version; `startOffset` overrides a title's resume point (a show or season ignores it).
/// Plex, the selected server's or another's, keeps the Plex session; any other provider goes through
/// `ProviderBackend`. A downloaded title plays its file.
@MainActor
enum PlaybackStart {
    static func prepare(_ item: MediaItem, fromBeginning: Bool, sourceID: String?,
                        queue: PlayQueue<PlaylistEntry>?, plex: PlexSession?,
                        startOffset: TimeInterval? = nil) async throws -> PreparedPlayback {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            throw MediaProviderError.notFound
        }
        var target = item
        var startOffset = startOffset
        if item.kind == .show || item.kind == .season {
            target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider) ?? item
            startOffset = nil
        }
        let entries = queue.map { q in (queue: q, items: q.entries.map(\.item)) }

        // Plex keeps the Plex session: downloads, offline progress, the dashboard's
        // direct-play session and the server's stop reason.
        if try ProviderPlayback.route(for: provider, hasPlexSession: plex != nil) == .plexSession, let plex {
            let serverID = target.ref.isPlex ? nil : String(item.ref.providerID.dropFirst("plex:".count))
            func shim(_ item: MediaItem) -> PlexMetadata {
                var metadata = ProviderPlaybackMetadata.listing(item: item)
                metadata.serverID = serverID
                return metadata
            }
            let request = try await plex.playback(
                for: shim(target), fromBeginning: fromBeginning, version: sourceID.map(VersionChoice.source) ?? .best,
                startOffset: startOffset)
            let plexQueue = entries.flatMap { PlayQueue(entries: $0.items.map(shim), startingAt: $0.queue.index) }
            return PreparedPlayback(request: request, backend: plex, queue: plexQueue)
        }

        let backend = ProviderBackend(provider: provider, onWatchStateChange: { [weak plex] in
            await plex?.watchStateDidChange()
        })
        backend.register(entries?.items ?? [])
        let request: PlexPlaybackRequest
        if var local = ClientHost.offline.localPlayback(for: target), sourceID == nil {
            if fromBeginning { local.startTime = nil }
            if let startOffset { local.startTime = startOffset }
            request = local
        } else {
            request = try await backend.firstPlayback(of: target, fromBeginning: fromBeginning, sourceID: sourceID,
                                                      startOffset: startOffset)
        }
        let shimQueue = entries.flatMap {
            PlayQueue(entries: $0.items.map(ProviderPlaybackMetadata.listing(item:)), startingAt: $0.queue.index)
        }
        return PreparedPlayback(request: request, backend: backend, queue: shimQueue)
    }
}
