// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlaylistEntry.swift
//  Rivulet
//
//  A video playlist and its rows, across backends.
//

import Foundation

/// One row of a playlist. `entryID` names the row, not the title, so the same
/// title twice is two entries (Plex `playlistItemID`, Jellyfin `PlaylistItemId`).
nonisolated struct PlaylistEntry: Hashable, Sendable {
    let entryID: String
    let item: MediaItem
}

/// A playlist's rows, and whether the server builds it from rules (no editing).
nonisolated struct PlaylistContents: Sendable {
    let entries: [PlaylistEntry]
    let isSmart: Bool
}

extension PlayQueue where Entry == PlaylistEntry {
    static func continuePoint(in entries: [PlaylistEntry]) -> Int? {
        continuePoint(in: entries, isPlayed: \.item.userState.isPlayed, isStarted: \.item.userState.isInProgress)
    }
}

struct MediaPlaylist: Hashable, Sendable {
    let item: MediaItem
    let isSmart: Bool

    /// Pixel size of the 16:9 card art (`artwork.backdrop`) on the playlists grid.
    static let cardSize = (width: 1280, height: 720)
}
