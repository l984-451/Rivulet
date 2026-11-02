// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI

/// Home tab root: hero carousel, Continue Watching, then each pinned
/// library's promoted rows. The root supplies the NavigationStack.
struct IOSPlexHomeView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    /// Same key as the tvOS Home > Hero setting.
    @AppStorage("showHomeHero") private var showHero = true
    /// Same key as the tvOS hero choice (#414): trending, continueWatching, recentlyAdded, watchlist.
    @AppStorage(IOSHomeSettingsView.heroContentKey) private var heroContent = "trending"
    @State private var trending: [PlexMetadata] = []
    @State private var watchlist: [PlexMetadata] = []

    private var hasContent: Bool { plex.continueWatching != nil || !plex.shelves.isEmpty }

    var body: some View {
        // No eligible items means no hero, so keep the title and safe area.
        let featured = showHero ? heroItems : []
        Group {
            if !plex.isConfigured {
                IOSPlexConnectView()
            } else if hasContent {
                IOSPlexHeroFeed(rows: [plex.continueWatching].compactMap { $0 } + plex.shelves,
                                heroItems: featured) { await plex.refresh() }
            } else {
                ScrollView {
                    placeholder.containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await plex.refresh() }
            }
        }
        .iosPlexHeroChrome(hero: !featured.isEmpty, title: String(localized: "Home"))
        .toolbar {
            IOSAccountToolbarItem()
        }
        .task(id: [String(showHero), heroContent] + plex.shelves.map(\.id)) {
            guard showHero else { return }
            trending = await plex.trendingHeroItems()
            if heroContent == "watchlist" { watchlist = await plex.watchlistHeroItems() }
        }
        .onReceive(PlexWatchlistService.shared.$watchlistItems.dropFirst()) { _ in
            guard showHero, heroContent == "watchlist" else { return }
            Task { watchlist = await plex.watchlistHeroItems() }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if plex.isLoadingContent {
            ProgressView()
        } else if let error = plex.contentError {
            IOSPlexErrorView(title: "Couldn't Load Home", message: error, offersDownloads: true) { await plex.refresh() }
        } else {
            ContentUnavailableView(
                "Nothing on Home Yet",
                systemImage: "rectangle.stack",
                description: Text("Pin a library to Home in Plex, then pull to refresh.")
            )
        }
    }

    /// The chosen list; an empty one shows trending, and no trending match shows Home's rows.
    private var heroItems: [PlexMetadata] {
        let chosen: [PlexMetadata] = switch heroContent {
        case "continueWatching": (plex.continueWatching?.items ?? []).filter { ($0.art ?? $0.grandparentArt) != nil }
        case "recentlyAdded": recentlyAdded
        case "watchlist": watchlist
        default: []
        }
        if !chosen.isEmpty { return Array(chosen.prefix(10)) }
        return trending.isEmpty ? IOSPlexHeroFeed.heroItems(from: plex.shelves) : trending
    }

    /// One item from each recently added row in turn, so no library's additions bury another's.
    private var recentlyAdded: [PlexMetadata] {
        let rows = plex.shelves.filter { ($0.hubIdentifier ?? "").lowercased().contains("recentlyadded") }.map(\.items)
        let mixed = (0..<(rows.map(\.count).max() ?? 0)).flatMap { i in rows.compactMap { i < $0.count ? $0[i] : nil } }
        return mixed.filter { ($0.art ?? $0.grandparentArt) != nil }
    }
}
