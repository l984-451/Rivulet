// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI

/// Home tab root: hero carousel, Continue Watching, then each pinned
/// library's promoted rows. The root supplies the NavigationStack.
struct IOSPlexHomeView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var browse: IOSBrowseStore
    @State private var trending: [MediaItem] = []
    @State private var watchlist: [MediaItem] = []

    /// The hero's settings are `HeroSources`, as on tvOS; `browse.homeSettingsRevision` redraws on a change.
    private var showHero: Bool { HeroSources.isEnabled }

    private var hasContent: Bool {
        browse.continueWatchingHub != nil || !browse.shelves.isEmpty || (!browse.failures.isEmpty && !browse.libraries.isEmpty)
    }

    var body: some View {
        // No eligible items means no hero, so keep the title and safe area.
        let hero = showHero && !heroItems.isEmpty
        Group {
            if !browse.hasServers {
                IOSPlexConnectView()
            } else if hasContent {
                IOSPlexHeroFeed(rows: browse.homeRows, heroItems: hero ? heroItems : [],
                                banners: browse.failedServers) { await browse.refresh() }
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
        .task(id: [String(showHero)] + HeroSources.sources.map(\.rawValue) + browse.shelves.map(\.id)) {
            guard showHero else { return }
            trending = await browse.trendingHeroItems()
            if HeroSources.isOn(.watchlist) { watchlist = await browse.watchlistHeroItems() }
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
    private var heroItems: [MediaItem] {
        HomeHero.items(sources: HeroSources.sources, continueWatching: browse.continueWatching, shelves: browse.shelves,
                       watchlist: watchlist, trending: trending, personal: browse.personalRows,
                       heroPins: HomePlaylistPins.pins(in: .hero))
    }
}
