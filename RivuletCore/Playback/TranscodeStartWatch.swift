// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A Plex transcode that shows nothing for `deadline` gets a log line and a notice saying why (#677).
/// One rule for all three apps; each player only says when it started and whether it has played.
nonisolated enum TranscodeStartWatch {
    static let deadline: Duration = .seconds(15)

    /// Asks the server about the session, logs it beside the player's state, and returns the notice.
    static func report(serverURL: String, authToken: String, sessionId: String, playerState: String) async -> PlaybackNotice {
        let status = await PlexNetworkManager.shared.transcodeSessionStatus(
            serverURL: serverURL, authToken: authToken, sessionId: sessionId)
        DiagLog.error(.playback, "Transcode shows nothing after \(deadline.components.seconds) s: player \(playerState);"
            + " server \(status?.summary ?? "has no such session")")
        return notice(for: status)
    }

    static func notice(for status: PlexTranscodeStatus?) -> PlaybackNotice {
        let detail: String
        if let status, status.isBehind, let speed = status.speed {
            detail = String(localized: "The server is converting this at \(String(format: "%.1f", speed))×, slower than it plays.")
        } else if status == nil {
            detail = String(localized: "The server stopped converting this.")
        } else {
            detail = String(localized: "The server is converting this, but it is slow to arrive.")
        }
        return PlaybackNotice(title: String(localized: "Still Waiting on the Server"), detail: detail, symbol: "hourglass")
    }
}
