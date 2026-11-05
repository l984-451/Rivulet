// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Plex `ProgressReporter` over `/:/timeline` (state strings, ms times), returned by
// `MediaProvider.progressReporter(for:)`. Separate from the player's throttled `PlexProgressReporter`.
// `start` opens a direct-play session so the dashboard shows its bandwidth (#423); a transcode's
// decision is the HLS player's to send before it fetches the playlist (tvOS's preflight does).
// `stopped` frees a transcoder and ends the provider's record of the session.

import Foundation

struct PlexTimelineReporter: ProgressReporter {
    let serverURL: String
    let authToken: String
    let ratingKey: String
    let networkManager: PlexNetworkManager
    var playSessionID: String?
    var session: PlexPlaySession?
    var onEnd: @Sendable () -> Void = {}

    /// A direct-play file's timeline carries the session id; a transcode's does not.
    private var timelineSession: String? { session?.isTranscode == true ? nil : playSessionID }

    func start(position: TimeInterval) async {
        guard let session, !session.isTranscode, let playSessionID else { return }
        await networkManager.openDirectPlaySession(
            serverURL: serverURL, authToken: authToken, ratingKey: ratingKey,
            mediaIndex: session.mediaIndex, sessionIdentifier: playSessionID)
    }

    func progress(position: TimeInterval) async { await report(position, "playing") }

    func paused(at position: TimeInterval) async { await report(position, "paused") }

    func stopped(at position: TimeInterval) async {
        await report(position, "stopped")
        onEnd()
        guard session?.isTranscode == true, let playSessionID else { return }
        await networkManager.stopTranscodeSession(serverURL: serverURL, authToken: authToken, sessionId: playSessionID)
    }

    private func report(_ position: TimeInterval, _ state: String) async {
        _ = try? await networkManager.reportProgress(
            serverURL: serverURL, authToken: authToken, ratingKey: ratingKey, timeMs: Int(position * 1000),
            state: state, duration: session?.durationMs, sessionIdentifier: timelineSession
        )
    }
}
