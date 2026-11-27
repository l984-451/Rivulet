// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Every server's favorite movies, then shows (`FavoritesFeed`), under a hero of them and filtered to
/// All, Unwatched or Watched. Parity source:
/// RivuletiOS/Plex/Library/IOSFavoritesView.swift.
struct MacFavoritesView: View {
    @EnvironmentObject private var browse: BrowseStore
    /// Nil until the first load lands.
    @State private var items: [MediaItem]?
    /// All, Unwatched or Watched; the key the tvOS page reads (`FavoritesWatchFilter`).
    @AppStorage(FavoritesWatchFilter.storageKey) private var filterRaw = FavoritesWatchFilter.all.rawValue
    /// Same key as the library pages' hero setting.
    @AppStorage("showLibraryHero") private var showHero = true
    @State private var heroSelection: MediaItemRef?
    @State private var width: CGFloat = 1200
    /// The sidebar's side inset, which the hero's artwork runs under.
    @State private var bleed = EdgeInsets()

    private var filter: FavoritesWatchFilter { FavoritesWatchFilter(rawValue: filterRaw) ?? .all }

    var body: some View {
        let shown = items.map(filter.apply)
        let heroItems = showHero ? HomeHero.favoriteItems(shown ?? []) : []
        Group {
            if let items, items.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "heart")
                } description: {
                    Text("Right-click a movie or show, then choose Add to Favorites.")
                }
            } else if let shown {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !heroItems.isEmpty {
                            MacHomeHero(items: heroItems, width: width, bleed: bleed, selection: $heroSelection)
                        }
                        if shown.isEmpty {
                            Text("No favorites match this filter.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, MacMetrics.pageMargin)
                        }
                        section("Movies", shown.filter { $0.kind == .movie })
                        section("Shows", shown.filter { $0.kind != .movie })
                    }
                    .padding(heroItems.isEmpty ? .vertical : .bottom, 20)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .onGeometryChange(for: EdgeInsets.self) {
                    EdgeInsets(top: 0, leading: $0.safeAreaInsets.leading, bottom: 0, trailing: $0.safeAreaInsets.trailing)
                } action: { bleed = $0 }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Favorites")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Filter", selection: $filterRaw) {
                    ForEach(FavoritesWatchFilter.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                .help("Show all favorites, the unwatched ones or the watched ones")
            }
        }
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
