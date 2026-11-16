// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A playback failure the server caused, with the sentence to show. One mapping for all three apps.
/// Never a Rivulet bug, so it is a log and never a captured error.
nonisolated struct ServerRefusal: Error, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// Decision 2013: remote playback needs Plex Pass or a Remote Watch Pass.
        case plexPassRequired
        /// Decision 2000 or transcode 4005: the server can neither play nor convert it.
        case cannotConvert
        /// The file is gone from the server's disk.
        case fileMissing
        /// The server answered the transcode start with an error status.
        case transcodeRefused
        /// A Jellyfin or Emby server with no stream to offer this device.
        case cannotStream
        case notAllowed
        case streamLimit
        /// Another decision error: the server's own sentence.
        case other(String?)
    }

    let reason: Reason

    var message: String {
        switch reason {
        case .plexPassRequired: String(localized: "Playing away from home needs a Plex Pass or Remote Watch Pass.")
        case .cannotConvert: String(localized: "The server can't play or convert this video for this device.")
        case .fileMissing: String(localized: "The server can't find this video's file. It may have been moved or deleted.")
        case .transcodeRefused: String(localized: "The server wouldn't start a stream for this video.")
        case .cannotStream: String(localized: "This server can't stream this title to this device.")
        case .notAllowed: String(localized: "The server doesn't let this account play this video.")
        case .streamLimit: String(localized: "The server is at its stream limit. Try again in a moment.")
        case .other(let text?) where !text.isEmpty: String(localized: "The server can't play this video: \(text)")
        case .other: String(localized: "The server can't play this video.")
        }
    }

    /// A transcode would fail too, so none is worth starting.
    var blocksTranscode: Bool {
        switch reason {
        case .plexPassRequired, .cannotConvert: true
        default: false
        }
    }

    // MARK: - Sources

    /// A Plex decision's codes: 1xxx plays; 2004 is our own malformed request; the rest is the server saying no.
    static func decision(general: Int?, generalText: String?, transcode: Int?, transcodeText: String?) -> ServerRefusal? {
        guard let general, general >= 2000, general != 2004 else { return nil }
        if general == 2013 { return ServerRefusal(reason: .plexPassRequired) }
        if general == 2000 || transcode == 4005 { return ServerRefusal(reason: .cannotConvert) }
        return ServerRefusal(reason: .other(generalText ?? transcodeText))
    }

    /// Jellyfin and Emby `PlaybackInfo.ErrorCode`. NoCompatibleStream is the provider's own transcode-required path.
    init?(playbackErrorCode code: String?) {
        switch code {
        case "NotAllowed": self.init(reason: .notAllowed)
        case "RateLimitExceeded": self.init(reason: .streamLimit)
        default: return nil
        }
    }

    /// A provider error that is the server's answer, not a fault.
    init?(error: Error) {
        switch error {
        case let refusal as ServerRefusal: self = refusal
        case MediaProviderError.transcodeRequired: self.init(reason: .cannotStream)
        default: return nil
        }
    }

    init(reason: Reason) { self.reason = reason }
}

extension ServerRefusal: LocalizedError {
    var errorDescription: String? { message }
}
