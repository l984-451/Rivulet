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
                playbackError = PlaybackFailure.message(for: error)
            }
        }
    }

    private func startItem(_ item: MediaItem, fromBeginning: Bool, sourceID: String?,
                       queue: PlayQueue<PlaylistEntry>?) async throws {
        let prepared = try await PlaybackStart.prepare(
            item, fromBeginning: fromBeginning, sourceID: sourceID, queue: queue, plex: plex)
        start(IOSPlexPlayback(request: prepared.request, plex: prepared.backend, queue: prepared.queue))
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
        let backend = ProviderBackend(provider: provider, onWatchStateChange: { [weak plex] in
            await plex?.watchStateDidChange()
        })
        backend.register([record.item])
        start(IOSPlexPlayback(request: request, plex: backend, queue: nil))
    }
}
