// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Audio and subtitle picks as server stream ids (Plex's, or a provider's through the shim),
/// which survive a route change. A nil field leaves the server's choice alone.
struct TrackPicks: Equatable, Sendable {
    var audio: Int?
    var subtitle: SubtitlePick?
}

/// A subtitle pick. Off is its own case because Jellyfin and Emby number a real stream 0;
/// each server's wire form for Off is applied only where the request is built.
enum SubtitlePick: Equatable, Sendable {
    case off
    case track(Int)

    /// nil is Off.
    init(_ trackID: Int?) {
        self = trackID.map(SubtitlePick.track) ?? .off
    }

    var trackID: Int? {
        if case .track(let id) = self { id } else { nil }
    }

    /// Plex's form: stream 0 turns subtitles off. A Plex stream id is never 0.
    var plexStreamID: Int { trackID ?? 0 }

    /// A provider's form: -1 turns subtitles off.
    var providerStreamIndex: Int { trackID ?? -1 }
}
