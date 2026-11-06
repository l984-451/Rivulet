// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What the iOS player asks of the server behind a title: the Plex session for Plex items
/// (downloads, offline progress, the dashboard session), `IOSProviderBackend` for any other
/// provider. The player holds one of these and never learns which.
@MainActor
protocol IOSPlayerBackend: AnyObject {
    /// The next title's playback (Up Next, a playlist entry): `quality` is the player's pick,
    /// `previous` lends its fresh throughput reading.
    func upNextPlayback(for item: PlexMetadata, quality: StreamingQuality?,
                        previous: IOSPlexPlaybackRequest?) async throws -> IOSPlexPlaybackRequest
    /// The playing title again at `time`: a quality change, a step-down, a fallback, a track
    /// change on a transcode (`streams` are the picks as the player's stream ids).
    func reloadedPlayback(of request: IOSPlexPlaybackRequest, quality: StreamingQuality, plan: StreamPlan?,
                          at time: TimeInterval, streams: TrackPicks?) async throws -> IOSPlexPlaybackRequest
    /// Returns the server's reason when it has ended this play session.
    @discardableResult
    func reportProgress(for request: IOSPlexPlaybackRequest, time: TimeInterval, state: String) async -> String?
    func markWatched(_ request: IOSPlexPlaybackRequest) async
    func nextEpisode(after episode: PlexMetadata, in request: IOSPlexPlaybackRequest) async -> PlexMetadata?
    /// Frees the server's transcoder; a reload or exit leaves it running otherwise.
    func stopTranscode(_ request: IOSPlexPlaybackRequest) async
    /// Opens the server's play session before the player asks for media.
    func openPlaySession(_ request: IOSPlexPlaybackRequest) async
    /// Sets the audio or subtitle stream a new transcode session reads.
    func selectStream(_ picks: TrackPicks, in request: IOSPlexPlaybackRequest) async
    func artworkURL(for item: PlexMetadata, kind: IOSPlexSession.ArtworkKind, width: Int, height: Int) -> URL?
    func imageURL(path: String?, width: Int, height: Int, serverID: String?) -> URL?
    /// Repaint what shows watch state.
    func watchStateDidChange() async
}

extension IOSPlexSession: IOSPlayerBackend {
    func upNextPlayback(for item: PlexMetadata, quality: StreamingQuality?,
                        previous: IOSPlexPlaybackRequest?) async throws -> IOSPlexPlaybackRequest {
        try await playback(for: item, quality: quality, previous: previous)
    }

    func reloadedPlayback(of request: IOSPlexPlaybackRequest, quality: StreamingQuality, plan: StreamPlan?,
                          at time: TimeInterval, streams: TrackPicks?) async throws -> IOSPlexPlaybackRequest {
        // Plex reads the part's picks when the session starts, so the player writes them with `selectStream`.
        try await playback(reloading: request, quality: quality, plan: plan, at: time)
    }
}
