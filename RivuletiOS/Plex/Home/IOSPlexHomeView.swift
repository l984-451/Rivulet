// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI

/// Home tab root: hero carousel, Continue Watching, then each pinned
/// library's promoted rows. The root supplies the NavigationStack.
struct IOSPlexHomeView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var browse: IOSBrowseStore
    @Environment(\.displayScale) private var displayScale
    /// Same key as the tvOS Home > Hero setting.
    @AppStorage("showHomeHero") private var showHero = true
    /// Same key as the tvOS hero choice (#414): trending, continueWatching, recentlyAdded, watchlist.
    @AppStorage(IOSHomeSettingsView.heroContentKey) private var heroContent = "trending"
    @State private var trending: [MediaItem] = []
    @State private var watchlist: [MediaItem] = []
    /// While the hero sits under the bar, the bar's scroll edge blur stays off.
    @State private var heroUnderBar = true
    @State private var heroSelection: MediaItemRef?

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
                GeometryReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            if hero {
                                IOSPlexHomeHero(items: heroItems, size: fullSize(proxy), bleed: proxy.safeAreaInsets,
                                                selection: $heroSelection)
                            }
                            ForEach(browse.failedServers) { IOSServerFailureBanner(failure: $0) }
                            if let continueWatching = browse.continueWatchingHub {
                                IOSPlexShelfView(hub: continueWatching)
                            }
                            ForEach(browse.shelves) { IOSPlexShelfView(hub: $0) }
                        }
                        .padding(.bottom, 24)
                    }
                    .ignoresSafeArea(edges: hero ? .top : [])
                    .onScrollGeometryChange(for: Bool.self) { scroll in
                        scroll.contentOffset.y + scroll.contentInsets.top < IOSPlexHomeHero.height(for: fullSize(proxy)) - 120
                    } action: { _, under in heroUnderBar = under }
                    .scrollEdgeEffectHidden(hero && heroUnderBar, for: .top)
                    .refreshable { await browse.refresh() }
                    .task(id: hero ? heroItems.map { "\($0.ref.providerID)|\($0.ref.itemID)" } + ["\(heroPageWidth(proxy))"] : []) {
                        if hero { await prefetchHero(width: heroPageWidth(proxy)) }
                    }
                    .iosPlexAmbient(hero ? heroItems.first { $0.ref == heroSelection } ?? heroItems.first : nil)
                }
            } else {
                ScrollView {
                    placeholder.containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await browse.refresh() }
            }
        }
        .navigationTitle(hero ? "" : "Home")
        .navigationBarTitleDisplayMode(hero ? .inline : .large)
        .toolbar(removing: hero ? .title : nil)
        .toolbarBackgroundVisibility(hero ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            IOSAccountToolbarItem()
        }
        .task(id: [String(showHero), heroContent] + browse.shelves.map(\.id)) {
            guard showHero else { return }
            trending = await browse.trendingHeroItems()
            if heroContent == "watchlist" { watchlist = await browse.watchlistHeroItems() }
        }
        .onReceive(PlexWatchlistService.shared.$watchlistItems.dropFirst()) { _ in
            guard showHero, heroContent == "watchlist" else { return }
            Task { watchlist = await browse.watchlistHeroItems() }
        }
    }

    /// Warms the hero pages' logos and art at the size the hero requests.
    /// Continue Watching cards warm their own look-ahead as they appear.
    private func prefetchHero(width: CGFloat) async {
        await browse.prefetchArtwork(heroItems.map {
            ($0, IOSItemArtwork.url(browse, item: $0, kind: .backdrop, width: width, aspectRatio: 16 / 9, scale: displayScale))
        })
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

    /// The chosen list; an empty one shows trending, and no trending match shows Home's rows.
    private var heroItems: [MediaItem] {
        HomeHero.items(content: heroContent, continueWatching: browse.continueWatching, shelves: browse.shelves,
                       watchlist: watchlist, trending: trending)
    }

    private func heroPageWidth(_ proxy: GeometryProxy) -> CGFloat {
        IOSPlexHomeHero.pageWidth(proxy.size.width, bleed: proxy.safeAreaInsets)
    }

    private func fullSize(_ proxy: GeometryProxy) -> CGSize {
        CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top)
    }
}
