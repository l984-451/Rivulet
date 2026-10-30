// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// One Codable Home or library row of flat `MediaItem`s, as Home renders it.
// Built by `PlexDataStore.projectHomeItems()` / `projectLibraryItems()` and the Jellyfin store,
// cached by `CacheManager.cacheHomeItems`. `id` is the row's `HomeSectionID.raw`.

import Foundation

nonisolated struct CachedHomeHub: Codable, Sendable {
    var id: String
    var title: String
    var isContinueWatching: Bool
    var hubKey: String?
    var hubIdentifier: String?
    var totalSize: Int?
    var items: [MediaItem]
    /// The library the row belongs to, as `LibrarySettingsManager` keys it, so
    /// Home follows the sidebar's order across servers. nil for Continue Watching.
    var libraryKey: String? = nil
    /// Native provider metadata; optional so existing Plex disk caches remain readable.
    var nativeProviderID: String? = nil
    var providerHubID: String? = nil
    var style: MediaHub.HubStyle? = nil
    var nextPage: Page? = nil
    var canBrowse: Bool? = nil
}

/// An ordered list of home/library hub rows — the full projection for one
/// surface (the home, or a single library page).
typealias CachedHomeRail = [CachedHomeHub]
