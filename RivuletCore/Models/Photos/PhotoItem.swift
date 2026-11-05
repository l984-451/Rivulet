// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoItem.swift
//  Rivulet
//
//  One tile of a photo library. Its own type, never a MediaItem, so a photo
//  cannot reach a shelf, the detail page, Search or Top Shelf.
//

import Foundation

nonisolated struct PhotoItem: Hashable, Sendable {
    enum Kind: Sendable { case folder, photo, clip }

    let ref: MediaItemRef
    let kind: Kind
    let title: String
    /// Date taken, else the file's date.
    let date: Date?
    /// Folders, when the server says.
    let childCount: Int?
    /// Cover-sized for a grid tile.
    let thumbnail: URL?
    /// Fit inside the screen; nil for folders. Never the original file.
    let full: URL?
    /// Clips: what the player takes.
    let playable: MediaItem?

    /// Pixel side of a tile request, and the box a full-screen request fits in.
    static let thumbnailSide = 520
    static let fullSize = (width: 3840, height: 2160)
}

nonisolated struct PhotoPage: Sendable {
    let folders: [PhotoItem]
    /// Photos and clips, in the server's order.
    let media: [PhotoItem]
    let nextPage: Page?
}
