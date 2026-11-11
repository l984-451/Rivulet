// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What the iOS player asks of the server behind a title: the Plex session for Plex items
/// (downloads, offline progress, the dashboard session), `ProviderBackend` for any other
/// provider. The player holds one of these and never learns which.
@MainActor
protocol PlayerBackend: AnyObject {
    /// The next title's playback (Up Next, a playlist entry): `quality` is the player's pick,
    /// `previous` lends its fresh throughput reading.
    func upNextPlayback(for item: PlexMetadata, quality: StreamingQuality?,
                        previous: PlexPlaybackRequest?) async throws -> PlexPlaybackRequest
    /// The movie after its trailers: from the start, on the version the viewer picked.
    func featurePlayback(for item: PlexMetadata, version: VersionChoice,
                         previous: PlexPlaybackRequest?) async throws -> PlexPlaybackRequest
    /// The playing title again at `time`: a quality change, a step-down, a fallback, a track
    /// change on a transcode (`streams` are the picks as the player's stream ids).
    func reloadedPlayback(of request: PlexPlaybackRequest, quality: StreamingQuality, plan: StreamPlan?,
                          at time: TimeInterval, streams: TrackPicks?) async throws -> PlexPlaybackRequest
    /// After a subtitle download: the playing title with the server's track list as it is now and
    /// the new subtitle's id, nil if the server never listed one `known` lacks. The player loads it at `time`.
    func requestWithNewSubtitle(_ request: PlexPlaybackRequest, known: Set<Int>,
                                at time: TimeInterval) async throws -> (request: PlexPlaybackRequest, trackID: Int)?
    /// Returns the server's reason when it has ended this play session.
    @discardableResult
    func reportProgress(for request: PlexPlaybackRequest, time: TimeInterval, state: String) async -> String?
    func markWatched(_ request: PlexPlaybackRequest) async
    func nextEpisode(after episode: PlexMetadata, in request: PlexPlaybackRequest) async -> PlexMetadata?
    /// Frees the server's transcoder; a reload or exit leaves it running otherwise.
    func stopTranscode(_ request: PlexPlaybackRequest) async
    /// Opens the server's play session before the player asks for media.
    func openPlaySession(_ request: PlexPlaybackRequest) async
    /// Sets the audio or subtitle stream a new transcode session reads.
    func selectStream(_ picks: TrackPicks, in request: PlexPlaybackRequest) async
    func artworkURL(for item: PlexMetadata, kind: PlexSession.ArtworkKind, width: Int, height: Int) -> URL?
    func imageURL(path: String?, width: Int, height: Int, serverID: String?) -> URL?
    /// Repaint what shows watch state.
    func watchStateDidChange() async
}

extension PlexSession: PlayerBackend {
    func upNextPlayback(for item: PlexMetadata, quality: StreamingQuality?,
                        previous: PlexPlaybackRequest?) async throws -> PlexPlaybackRequest {
        try await playback(for: item, quality: quality, previous: previous)
    }

    func featurePlayback(for item: PlexMetadata, version: VersionChoice,
                         previous: PlexPlaybackRequest?) async throws -> PlexPlaybackRequest {
        try await playback(for: item, fromBeginning: true, previous: previous, version: version)
    }

    func reloadedPlayback(of request: PlexPlaybackRequest, quality: StreamingQuality, plan: StreamPlan?,
                          at time: TimeInterval, streams: TrackPicks?) async throws -> PlexPlaybackRequest {
        // Plex reads the part's picks when the session starts, so the player writes them with `selectStream`.
        try await playback(reloading: request, quality: quality, plan: plan, at: time)
    }

    func requestWithNewSubtitle(_ request: PlexPlaybackRequest, known: Set<Int>,
                                at time: TimeInterval) async throws -> (request: PlexPlaybackRequest, trackID: Int)? {
        guard let search = request.subtitleSearch as? PlexSubtitleSearch,
              let (fresh, trackID) = try await search.metadataWithNewSubtitle(known: known, mediaID: request.item.Media?.first?.id)
        else { return nil }
        var next = request
        next.item.Media = fresh.Media
        next.startTime = time
        return (next, trackID)
    }
}

/// What a playback alert says for a failed start.
nonisolated enum PlaybackFailure {
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
