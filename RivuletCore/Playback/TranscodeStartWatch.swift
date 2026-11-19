// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation

/// A Plex transcode that shows nothing for `deadline` gets a log line and a notice saying why (#677).
/// One rule for all three apps; each player only says when it started and whether it has played.
nonisolated enum TranscodeStartWatch {
    static let deadline: Duration = .seconds(15)

    /// What an AVPlayer holds at the deadline, for the log: playing is not proof of a picture or sound (#677).
    @MainActor
    static func describe(_ item: AVPlayerItem, player: AVPlayer) async -> String {
        var tracks: [String] = []
        for track in item.tracks {
            guard let asset = track.assetTrack else { continue }
            let formats = (try? await asset.load(.formatDescriptions)) ?? []
            let codecs = formats.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }.joined(separator: "/")
            tracks.append("\(asset.mediaType.rawValue) \(codecs)\(track.isEnabled ? "" : " off")")
        }
        let loaded = item.loadedTimeRanges.first.map { String(format: "%.1f", $0.timeRangeValue.duration.seconds) } ?? "0"
        let size = item.presentationSize
        let error = item.errorLog()?.events.last.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? "none"
        return "status=\(item.status.rawValue) rate=\(player.rate) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "none")"
            + " at=\(String(format: "%.1f", item.currentTime().seconds))s loaded=\(loaded)s"
            + " video=\(Int(size.width))x\(Int(size.height)) tracks=[\(tracks.joined(separator: ", "))]"
            + " segments=\(item.accessLog()?.events.last?.numberOfMediaRequests ?? 0) error=\(error)"
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
    }

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
