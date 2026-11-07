// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// One server's video playlists. Parity source: RivuletiOS/Plex/Library/IOSPlexPlaylistViews.swift.
struct MacPlaylistsView: View {
    let providerID: String
    @EnvironmentObject private var browse: BrowseStore

    var body: some View {
        MacFeaturePlaceholder(title: "Playlists", symbol: "list.and.film",
                              source: "RivuletiOS/Plex/Library/IOSPlexPlaylistViews.swift")
            .navigationTitle(browse.labels.title(String(localized: "Playlists"), providerID: providerID))
    }
}

/// One playlist: play, shuffle, reorder, rename, delete. Pushed by `MacRoute.playlist`.
struct MacPlaylistView: View {
    let playlist: MediaPlaylist

    var body: some View {
        MacFeaturePlaceholder(title: LocalizedStringKey(playlist.item.title), symbol: "list.and.film",
                              source: "RivuletiOS/Plex/Library/IOSPlexPlaylistViews.swift")
            .navigationTitle(playlist.item.title)
    }
}
