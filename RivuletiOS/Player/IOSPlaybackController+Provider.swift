// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension IOSPlaybackController {
    /// The one way to play a title from any server. A show or season plays the episode Play
    /// means; `sourceID` picks a version; a `queue` (a playlist) replaces Up Next. Failure
    /// shows in the host's alert (`playbackError`); a second call while one prepares is ignored.
    func play(_ item: MediaItem, fromBeginning: Bool = false, sourceID: String? = nil,
              queue: PlayQueue<PlaylistEntry>? = nil) {
        guard !isPreparing else { return }
        setPreparing(true)
        Task {
            defer { setPreparing(false) }
            do {
                try await startItem(item, fromBeginning: fromBeginning, sourceID: sourceID, queue: queue)
            } catch is CancellationError {
            } catch {
                playbackError = Self.message(for: error)
            }
        }
    }

    private func startItem(_ item: MediaItem, fromBeginning: Bool, sourceID: String?,
                       queue: PlayQueue<PlaylistEntry>?) async throws {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            throw MediaProviderError.notFound
        }
        var target = item
        if item.kind == .show || item.kind == .season {
            target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider) ?? item
        }
        let entries = queue.map { q in (queue: q, items: q.entries.map(\.item)) }

        // Plex, the selected server's or another's, keeps the Plex session: downloads, offline
        // progress, the dashboard's direct-play session and the server's stop reason.
        if try ProviderPlayback.route(for: provider, hasPlexSession: plex != nil) == .plexSession, let plex {
            let serverID = target.ref.isPlex ? nil : String(item.ref.providerID.dropFirst("plex:".count))
            func shim(_ item: MediaItem) -> PlexMetadata {
                var metadata = ProviderPlaybackMetadata.listing(item: item)
                metadata.serverID = serverID
                return metadata
            }
            let request = try await plex.playback(
                for: shim(target), fromBeginning: fromBeginning, version: sourceID.map(VersionChoice.source) ?? .best)
            let plexQueue = entries.flatMap { PlayQueue(entries: $0.items.map(shim), startingAt: $0.queue.index) }
            self.play(request, queue: plexQueue)
            return
        }

        let backend = IOSProviderBackend(provider: provider, onWatchStateChange: { [weak plex] in
            await plex?.watchStateDidChange()
        })
        backend.register(entries?.items ?? [])
        // A downloaded title plays its file, online or not.
        let request: IOSPlexPlaybackRequest
        if var local = IOSDownloadCenter.shared.localPlayback(for: target), sourceID == nil {
            if fromBeginning { local.startTime = nil }
            request = local
        } else {
            request = try await backend.firstPlayback(of: target, fromBeginning: fromBeginning, sourceID: sourceID)
        }
        let shimQueue = entries.flatMap {
            PlayQueue(entries: $0.items.map(ProviderPlaybackMetadata.listing(item:)), startingAt: $0.queue.index)
        }
        start(IOSPlexPlayback(request: request, plex: backend, queue: shimQueue))
    }

    /// Plays a finished download from its file, with the reports of the server it came from.
    func play(download record: DownloadRecord) {
        guard let request = IOSDownloadCenter.shared.localPlayback(record: record) else { return }
        if record.isPlex {
            play(request)
            return
        }
        guard let provider = MediaProviderRegistry.shared.provider(for: record.providerID) else {
            playbackError = String(localized: "Sign in to the server to play this download.")
            return
        }
        let backend = IOSProviderBackend(provider: provider, onWatchStateChange: { [weak plex] in
            await plex?.watchStateDidChange()
        })
        backend.register([record.item])
        start(IOSPlexPlayback(request: request, plex: backend, queue: nil))
    }

    /// What the alert says for a failed start.
    static func message(for error: Error) -> String {
        switch error as? MediaProviderError {
        case .transcodeRequired: String(localized: "This server can't stream this title to this device.")
        case .unreachable: String(localized: "Couldn't reach the server.")
        case .unauthorized: String(localized: "The server didn't accept your sign-in.")
        case .none: (error as? LocalizedError)?.errorDescription ?? String(localized: "Something went wrong starting playback.")
        default: String(localized: "Something went wrong starting playback.")
        }
    }
}
