// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Every server's favorite movies, then shows (`FavoritesFeed`). Parity source:
/// RivuletiOS/Plex/Library/IOSFavoritesView.swift.
struct MacFavoritesView: View {
    @EnvironmentObject private var browse: BrowseStore
    /// Nil until the first load lands.
    @State private var items: [MediaItem]?

    var body: some View {
        Group {
            if let items, items.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "heart")
                } description: {
                    Text("Right-click a movie or show, then choose Add to Favorites.")
                }
            } else if let items {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        section("Movies", items.filter { $0.kind == .movie })
                        section("Shows", items.filter { $0.kind != .movie })
                    }
                    .padding(.vertical, 20)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Favorites")
        .macPageRefresh { Task { await load() } }
        // A favorite change and playback both bump the revision, so the page follows.
        .task(id: browse.watchStateRevision) { await load() }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ items: [MediaItem]) -> some View {
        if !items.isEmpty {
            Text(title).font(.title3.bold()).padding(.horizontal, MacMetrics.pageMargin)
            MacPosterGrid(items: items, loadMore: nil)
        }
    }

    private func load() async {
        items = await FavoritesFeed.load(from: browse.allProviders)
    }
}
