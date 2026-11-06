// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Every server's favorite movies, then shows, each by title (`FavoritesFeed`).
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
                    VStack(alignment: .leading, spacing: 16) {
                        section("Movies", items.filter { $0.kind == .movie })
                        section("Shows", items.filter { $0.kind != .movie })
                    }
                    .padding(.vertical)
                }
                .refreshable { await load() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Favorites")
        // A favorite change and playback both bump the revision, so the page follows.
        .task(id: browse.watchStateRevision) { await load() }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ items: [MediaItem]) -> some View {
        if !items.isEmpty {
            Text(title).font(.title3.bold()).padding(.horizontal)
            IOSPlexPosterGrid(items: items, loadMore: nil)
        }
    }

    private func load() async {
        items = await FavoritesFeed.load(from: browse.allProviders)
    }
}
