// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Combine
import SwiftUI

/// Home: hero, Continue Watching, then each pinned library's rows and the personal rows.
/// Port of RivuletiOS/Plex/Home/IOSPlexHomeView.swift and IOSPlexHeroFeed.swift. The signed-out
/// state is the shell's `MacSignInLanding`.
struct MacHomeView: View {
    @EnvironmentObject private var browse: BrowseStore
    @State private var trending: [MediaItem] = []
    @State private var watchlist: [MediaItem] = []

    private var showHero: Bool { HeroSources.isEnabled }

    private var hasContent: Bool {
        browse.continueWatchingHub != nil || !browse.shelves.isEmpty || (!browse.failures.isEmpty && !browse.libraries.isEmpty)
    }

    var body: some View {
        let hero = showHero ? heroItems : []
        Group {
            if hasContent {
                MacHeroFeed(rows: browse.homeRows, heroItems: hero, banners: browse.failedServers)
            } else {
                placeholder
            }
        }
        .navigationTitle("Home")
        .task(id: [String(showHero)] + HeroSources.sources.map(\.rawValue) + browse.shelves.map(\.id)
                   + browse.hiddenSidebarLibraries.sorted()) {
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
            MacErrorView(title: "Couldn't Load Home", message: error) { await browse.refresh() }
        } else {
            ContentUnavailableView("Nothing on Home Yet", systemImage: "rectangle.stack",
                                   description: Text("Pin a library to Home in Plex, then refresh."))
        }
    }

    /// The chosen lists mixed; with nothing in them, trending, and with no trending match, Home's rows.
    private var heroItems: [MediaItem] {
        HomeHero.items(sources: HeroSources.sources, continueWatching: browse.continueWatching, shelves: browse.shelves,
                       watchlist: watchlist, trending: trending, personal: browse.personalRows,
                       heroPins: HomePlaylistPins.pins(in: .hero))
    }
}

/// The hero over a stack of rows, with the ambient wash from the shown title behind both.
struct MacHeroFeed: View {
    let rows: [MediaHub]
    let heroItems: [MediaItem]
    let banners: [BrowseStore.FailedServer]
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    @State private var selection: MediaItemRef?
    @State private var width: CGFloat = 1200

    private var shown: MediaItem? { heroItems.first { $0.ref == selection } ?? heroItems.first }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !heroItems.isEmpty {
                    MacHomeHero(items: heroItems, width: width, selection: $selection)
                }
                ForEach(banners) { MacServerFailureBanner(failure: $0) }
                ForEach(rows) { MacShelfView(hub: $0) }
            }
            .padding(.bottom, 28)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background { if let shown { MacAmbientBackdrop(item: shown, width: width) } }
        .task(id: heroItems.map { "\($0.ref.providerID)|\($0.ref.itemID)" } + ["\(Int(width / 120))"]) {
            await browse.prefetchArtwork(heroItems.map {
                ($0, MacItemArtwork.url(browse, item: $0, kind: .backdrop, width: width, aspectRatio: 16 / 9, scale: displayScale))
            })
        }
    }
}

/// One artwork stretched behind the page, diffused by the system material, with a vignette
/// that keeps the lower half dark in dark mode. Crossfades when the art changes.
private struct MacAmbientBackdrop: View {
    let item: MediaItem
    let width: CGFloat
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let url = MacItemArtwork.url(browse, item: item, kind: .backdrop, width: width, aspectRatio: 16 / 9, scale: displayScale)
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            MacImage(url: url).opacity(0.85).id(url).transition(.opacity)
            Rectangle().fill(.regularMaterial)
            if colorScheme == .dark {
                LinearGradient(stops: [.init(color: .black.opacity(0.10), location: 0),
                                       .init(color: .black.opacity(0.25), location: 0.55),
                                       .init(color: .black.opacity(0.50), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: url)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
