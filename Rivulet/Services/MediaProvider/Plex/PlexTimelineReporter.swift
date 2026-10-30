// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Plex `ProgressReporter` over `/:/timeline` (state strings, ms times), returned by
// `MediaProvider.progressReporter(for:)`. Separate from the player's throttled `PlexProgressReporter`.

import Foundation

struct PlexTimelineReporter: ProgressReporter {
    let serverURL: String
    let authToken: String
    let ratingKey: String
    let networkManager: PlexNetworkManager

    func start(position: TimeInterval) async {
        // Plex doesn't have a separate "start" call — first progress doubles as start.
    }

    func progress(position: TimeInterval) async {
        _ = try? await networkManager.reportProgress(
            serverURL: serverURL, authToken: authToken,
            ratingKey: ratingKey, timeMs: Int(position * 1000), state: "playing"
        )
    }

    func paused(at position: TimeInterval) async {
        _ = try? await networkManager.reportProgress(
            serverURL: serverURL, authToken: authToken,
            ratingKey: ratingKey, timeMs: Int(position * 1000), state: "paused"
        )
    }

    func stopped(at position: TimeInterval) async {
        _ = try? await networkManager.reportProgress(
            serverURL: serverURL, authToken: authToken,
            ratingKey: ratingKey, timeMs: Int(position * 1000), state: "stopped"
        )
    }
}
