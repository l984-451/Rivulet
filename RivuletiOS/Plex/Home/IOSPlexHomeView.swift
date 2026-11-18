// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI

/// Home tab root: hero carousel, Continue Watching, then each pinned
/// library's promoted rows. The root supplies the NavigationStack.
struct IOSPlexHomeView: View {
    @EnvironmentObject private var plex: PlexSession
    @EnvironmentObject private var browse: BrowseStore
    @State private var trending: [MediaItem] = []
    @State private var watchlist: [MediaItem] = []
    /// The hero's own lists have been fetched once, so an empty hero means none.
    @State private var heroFetched = false
    @Environment(\.launchHeroReady) private var launchHeroReady

    /// The hero's settings are `HeroSources`, as on tvOS; `browse.homeSettingsRevision` redraws on a change.
    private var showHero: Bool { HeroSources.isEnabled }

    var body: some View {
        // No eligible items means no hero, so keep the title and safe area.
        let hero = showHero && !heroItems.isEmpty
        Group {
            if !browse.hasServers {
                IOSPlexConnectView()
            } else if browse.hasHomeContent {
                IOSPlexHeroFeed(rows: browse.homeRows, heroItems: hero ? heroItems : [],
                                banners: browse.failedServers, refresh: { await browse.refresh() },
                                heroSettled: heroFetched)
            } else {
                ScrollView {
                    placeholder.containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await browse.refresh() }
            }
        }
        .iosPlexHeroChrome(hero: hero, title: String(localized: "Home"))
        .toolbar {
            IOSAccountToolbarItem()
        }
        .task(id: heroTaskID) {
            guard showHero else { return }
            // Trending is matched against Home's rows, so a fetch before they arrive settles nothing.
            let withRows = browse.hasHomeContent
            trending = await browse.trendingHeroItems()
            if HeroSources.isOn(.watchlist) { watchlist = await browse.watchlistHeroItems() }
            if withRows, !Task.isCancelled { heroFetched = true }
        }
        // Home settled with no hero to show: the launch splash has nothing to wait for.
        .onChange(of: showHero && heroFetched && browse.hasHomeContent && !browse.isLoadingContent && heroItems.isEmpty,
                  initial: true) { _, none in
            if none { launchHeroReady() }
        }
        .onReceive(PlexWatchlistService.shared.$watchlistItems.dropFirst()) { _ in
            guard showHero, HeroSources.isOn(.watchlist) else { return }
            Task { watchlist = await browse.watchlistHeroItems() }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if browse.isLoadingContent {
            ProgressView()
        } else if let error = browse.contentError ?? browse.failedServers.first?.message {
            IOSPlexErrorView(title: "Couldn't Load Home", message: error, offersDownloads: true) { await browse.refresh() }
        } else {
            ContentUnavailableView(
                "Nothing on Home Yet",
                systemImage: "rectangle.stack",
                description: Text("Pin a library to Home in Plex, then pull to refresh.")
            )
        }
    }

    /// The chosen lists mixed; with nothing in them, trending, and with no trending match, Home's rows.
    /// What the trending and watchlist lookups depend on; a change asks again.
    private var heroTaskID: [String] {
        var id = [String(showHero), String(browse.hasHomeContent)]
        id += HeroSources.sources.map(\.rawValue)
        id += browse.shelves.map(\.id)
        id += browse.hiddenSidebarLibraries.sorted()
        id += HeroLibraries.excluded.sorted()
        return id
    }

    private var heroItems: [MediaItem] {
        HomeHero.items(sources: HeroSources.sources, continueWatching: browse.continueWatching, shelves: browse.shelves,
                       watchlist: watchlist, trending: trending, personal: browse.personalRows,
                       heroPins: HomePlaylistPins.pins(in: .hero), isRowHidden: browse.isHomeRowHidden,
                       allows: HeroLibraries.allows)
    }
}
