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
    /// The hero's own lists have been fetched once, so an empty hero means none.
    @State private var heroFetched = false
    @Environment(\.macLaunchHeroReady) private var launchHeroReady

    private var showHero: Bool { HeroSources.isEnabled }

    var body: some View {
        let hero = showHero ? heroItems : []
        Group {
            if browse.hasHomeContent {
                MacHeroFeed(rows: browse.homeRows, heroItems: hero, banners: browse.failedServers,
                            onHeroShown: launchHeroReady, heroSettled: heroFetched)
            } else {
                placeholder
            }
        }
        .navigationTitle("Home")
        .task(id: heroTaskID) {
            guard showHero else { return }
            // Trending is matched against Home's rows, so a fetch before they arrive settles nothing.
            let withRows = browse.hasHomeContent
            trending = await browse.trendingHeroItems()
            if HeroSources.isOn(.watchlist) { watchlist = await browse.watchlistHeroItems() }
            if withRows, !Task.isCancelled { heroFetched = true }
            // Home settled with nothing for the hero: the launch splash has no artwork to wait for.
            if !Task.isCancelled, browse.hasHomeContent, heroItems.isEmpty { launchHeroReady() }
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

/// The hero over a stack of rows, with the ambient wash from the shown title behind both.
struct MacHeroFeed: View {
    let rows: [MediaHub]
    let heroItems: [MediaItem]
    let banners: [BrowseStore.FailedServer]
    /// Called once the first page's artwork is on screen (Home tells the launch splash).
    var onHeroShown: (() -> Void)?
    /// The hero's own lists (trending, watchlist) have arrived, so its first page will not change.
    var heroSettled = true
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    @State private var selection: MediaItemRef?
    @State private var width: CGFloat = 1200
    /// Hero pages drawn so far, until the launch splash has been told.
    @State private var shownHeroPages: Set<MediaItemRef> = []
    @State private var toldLaunch = false

    private var shown: MediaItem? { heroItems.first { $0.ref == selection } ?? heroItems.first }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !heroItems.isEmpty {
                    MacHomeHero(items: heroItems, width: width, selection: $selection,
                                onPageShown: onHeroShown == nil || toldLaunch ? nil : { _ = shownHeroPages.insert($0) })
                }
                ForEach(banners) { MacServerFailureBanner(failure: $0) }
                ForEach(rows) { hub in
                    if hub.id == FavoriteChannelsRow.identifier {
                        MacFavoriteChannelsRow()
                    } else {
                        MacShelfView(hub: hub)
                    }
                }
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
        // The launch splash leaves once the hero it reveals is drawn, not merely downloaded.
        .onChange(of: heroSettled && heroItems.first.map { shownHeroPages.contains($0.id) } == true, initial: true) { _, drawn in
            guard drawn, !toldLaunch, let onHeroShown else { return }
            toldLaunch = true
            onHeroShown()
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
