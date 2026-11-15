// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

extension PlexPlaybackRequest {
    /// The part's Plex audio (2) or subtitle (3) streams as tracks keyed by
    /// Plex stream id: a transcode carries only the stream the server picked.
    func plexTracks(streamType: Int) -> [AetherPlayer.Track] {
        (item.Media?.first?.Part?.first?.Stream ?? []).filter { $0.streamType == streamType }.map { stream in
            AetherPlayer.Track(
                id: stream.id,
                name: stream.displayTitle ?? stream.extendedDisplayTitle ?? String(localized: "Track \(stream.id)"),
                codec: stream.codec ?? "",
                language: stream.languageCode ?? stream.language,
                channels: stream.channels ?? 0,
                isDefault: stream.default ?? false,
                isForced: stream.forced ?? false,
                isHearingImpaired: stream.hearingImpaired ?? false
            )
        }
    }

    /// The stream Plex marks selected on the part.
    func selectedPlexStreamID(streamType: Int) -> Int? {
        item.Media?.first?.Part?.first?.Stream?.first { $0.streamType == streamType && $0.selected == true }?.id
    }
}
