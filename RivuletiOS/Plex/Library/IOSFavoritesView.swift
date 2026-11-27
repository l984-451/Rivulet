// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Every server's favorite movies, then shows, each by title (`FavoritesFeed`), under a hero of them
/// and filtered to All, Unwatched or Watched. The tvOS sidebar's Favorites page, as a Library tab row.
struct IOSFavoritesView: View {
    @EnvironmentObject private var browse: BrowseStore
    /// Nil until the first load lands.
    @State private var items: [MediaItem]?
    /// All, Unwatched or Watched; the key the tvOS page reads (`FavoritesWatchFilter`).
    @AppStorage(FavoritesWatchFilter.storageKey) private var filterRaw = FavoritesWatchFilter.all.rawValue
    /// Same key as the library pages' hero setting.
    @AppStorage("showLibraryHero") private var showHero = true
    @State private var heroSelection: MediaItemRef?

    private var filter: FavoritesWatchFilter { FavoritesWatchFilter(rawValue: filterRaw) ?? .all }

    var body: some View {
        let shown = items.map(filter.apply)
        let heroItems = showHero ? HomeHero.favoriteItems(shown ?? []) : []
        Group {
            if let items, items.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "heart")
                } description: {
                    Text("Touch and hold a movie or show, then choose Add to Favorites.")
                }
            } else if let shown {
                GeometryReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !heroItems.isEmpty {
                                IOSPlexHomeHero(items: heroItems,
                                                size: CGSize(width: proxy.size.width,
                                                             height: proxy.size.height + proxy.safeAreaInsets.top),
                                                bleed: proxy.safeAreaInsets, selection: $heroSelection)
                            }
                            if shown.isEmpty {
                                Text("No favorites match this filter.")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                            }
                            section("Movies", shown.filter { $0.kind == .movie })
                            section("Shows", shown.filter { $0.kind != .movie })
                        }
                        .padding(heroItems.isEmpty ? .vertical : .bottom)
                    }
                    .ignoresSafeArea(edges: heroItems.isEmpty ? [] : .top)
                    .refreshable { await load() }
                }
            } else {
                ProgressView()
            }
        }
        .iosPlexHeroChrome(hero: !heroItems.isEmpty, title: String(localized: "Favorites"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $filterRaw) {
                        ForEach(FavoritesWatchFilter.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    Label(filter.title, systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
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
