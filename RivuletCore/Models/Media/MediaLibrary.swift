// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaLibrary.swift
//  Rivulet
//
//  A library/section on a media provider.
//

import Foundation

nonisolated struct MediaLibrary: Identifiable, Hashable, Sendable {
    let id: String                  // provider-native (Plex sectionID)
    let providerID: String
    let title: String
    let kind: LibraryKind
    /// Lists the on-disk folder tree (no metadata agent, or unsorted Jellyfin).
    var browsesByFolder: Bool = false
    /// The user pinned the library to the server's home screen (Plex). Jellyfin and Emby have no such setting: always true.
    var isPinnedToHome: Bool = true

    enum LibraryKind: Sendable, Hashable, Codable {
        case movies
        case shows
        case music
        case mixed
        case photos
        case liveTV
    }
}
