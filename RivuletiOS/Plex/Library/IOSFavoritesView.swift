// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Every server's favorite movies and shows as one poster grid, by title (`FavoritesFeed`).
/// The tvOS sidebar's Favorites page, as a Library tab row.
struct IOSFavoritesView: View {
    @EnvironmentObject private var browse: IOSBrowseStore
    /// Nil until the first load lands.
    @State private var items: [MediaItem]?

    var body: some View {
        Group {
            if let items, items.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "heart")
                } description: {
                    Text("Touch and hold a movie or show, then choose Add to Favorites.")
                }
            } else if let items {
                ScrollView {
                    IOSPlexPosterGrid(items: items, loadMore: nil)
                        .padding(.vertical)
                }
                .refreshable { await load() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Favorites")
        // Each favorite change and playback bumps the revision, so the grid follows.
        .task(id: browse.watchStateRevision) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: FavoritesFeed.didChange)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        items = await FavoritesFeed.load()
    }
}
