// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

struct MusicPlaylist: Identifiable, Hashable, Sendable {
    var id: MediaItemRef { ref }
    let ref: MediaItemRef
    let title: String
    let artworkURL: URL?
    let trackCount: Int
    let duration: TimeInterval
    /// Smart playlists are rule-driven: the server rejects added tracks.
    let isSmart: Bool
}
