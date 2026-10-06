// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Home tab root: hero carousel, Continue Watching, then each pinned
/// library's promoted rows. The root supplies the NavigationStack.
struct IOSPlexHomeView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.displayScale) private var displayScale
    /// Same key as the tvOS Home > Hero setting.
    @AppStorage("showHomeHero") private var showHero = true
    /// While the hero sits under the bar, the bar's scroll edge blur stays off.
    @State private var heroUnderBar = true

    private var hasContent: Bool { plex.continueWatching != nil || !plex.shelves.isEmpty }

    var body: some View {
        // No eligible items means no hero, so keep the title and safe area.
        let hero = showHero && !heroItems.isEmpty
        Group {
            if !plex.isConfigured {
                IOSPlexConnectView()
            } else if hasContent {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            if hero {
                                IOSPlexHomeHero(items: heroItems, size: fullSize(proxy))
                            }
                            if let continueWatching = plex.continueWatching {
                                IOSPlexShelfView(hub: continueWatching)
                            }
                            ForEach(plex.shelves) { IOSPlexShelfView(hub: $0) }
                        }
                        .padding(.bottom, 24)
                    }
                    .ignoresSafeArea(edges: hero ? .top : [])
                    .onScrollGeometryChange(for: Bool.self) { scroll in
                        scroll.contentOffset.y + scroll.contentInsets.top < IOSPlexHomeHero.height(for: fullSize(proxy)) - 120
                    } action: { _, under in heroUnderBar = under }
                    .scrollEdgeEffectHidden(hero && heroUnderBar, for: .top)
                    .refreshable { await plex.refresh() }
                    .task(id: hero ? heroItems.map(\.id) + ["\(proxy.size.width)"] : []) {
                        if hero { await prefetchHero(width: proxy.size.width) }
                    }
                }
            } else {
                ScrollView {
                    placeholder.containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await plex.refresh() }
            }
        }
        .navigationTitle(hero ? "" : "Home")
        .navigationBarTitleDisplayMode(hero ? .inline : .large)
        .toolbar(removing: hero ? .title : nil)
        .toolbarBackgroundVisibility(hero ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            IOSAccountToolbarItem()
        }
    }

    /// Warms the hero pages' logos and art at the size the hero requests.
    /// Continue Watching cards warm their own look-ahead as they appear.
    private func prefetchHero(width: CGFloat) async {
        await plex.prefetchArtwork(heroItems.map {
            ($0, IOSPlexArtwork.url(plex, item: $0, kind: .backdrop, width: width, aspectRatio: 16 / 9, scale: displayScale))
        })
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

    /// Up to six featured items, two per row, one per show.
    private var heroItems: [PlexMetadata] {
        var seen = Set<String>()
        return Array(
            plex.shelves
                .flatMap { $0.items.prefix(2) }
                .filter { ($0.art ?? $0.grandparentArt) != nil }
                .filter { seen.insert($0.grandparentRatingKey ?? $0.id).inserted }
                .prefix(6)
        )
    }

    private func fullSize(_ proxy: GeometryProxy) -> CGSize {
        CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top)
    }
}
