// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Hero carousel over a stack of rows: Home, and a library's Recommended page.
/// The hero features the leading items of `featured`; the caller applies
/// `iosPlexHeroChrome` with the same `heroItems` so the bar steps aside for it.
struct IOSPlexHeroFeed: View {
    let rows: [PlexHub]
    let heroItems: [PlexMetadata]
    let refresh: () async -> Void
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.displayScale) private var displayScale
    /// While the hero sits under the bar, the bar's scroll edge blur stays off.
    @State private var heroUnderBar = true
    @State private var heroSelection: String?

    var body: some View {
        let hero = !heroItems.isEmpty
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if hero {
                        IOSPlexHomeHero(items: heroItems, size: fullSize(proxy), bleed: proxy.safeAreaInsets,
                                        selection: $heroSelection)
                    }
                    ForEach(rows) { IOSPlexShelfView(hub: $0) }
                }
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: hero ? .top : [])
            .onScrollGeometryChange(for: Bool.self) { scroll in
                scroll.contentOffset.y + scroll.contentInsets.top < IOSPlexHomeHero.height(for: fullSize(proxy)) - 120
            } action: { _, under in heroUnderBar = under }
            .scrollEdgeEffectHidden(hero && heroUnderBar, for: .top)
            .refreshable { await refresh() }
            .task(id: hero ? heroItems.map(\.id) + ["\(heroPageWidth(proxy))"] : []) {
                if hero { await prefetchHero(width: heroPageWidth(proxy)) }
            }
            .iosPlexAmbient(hero ? heroItems.first { $0.id == heroSelection } ?? heroItems.first : nil)
        }
    }

    /// Up to six featured items, two per row, one per show.
    static func heroItems(from hubs: [PlexHub]) -> [PlexMetadata] {
        var seen = Set<String>()
        return Array(
            hubs
                .filter { !$0.isContinueWatching }
                .flatMap { $0.items.prefix(2) }
                .filter { ($0.art ?? $0.grandparentArt) != nil }
                .filter { seen.insert($0.grandparentRatingKey ?? $0.id).inserted }
                .prefix(6)
        )
    }

    /// Warms the hero pages' logos and art at the size the hero requests.
    /// Continue Watching cards warm their own look-ahead as they appear.
    private func prefetchHero(width: CGFloat) async {
        await plex.prefetchArtwork(heroItems.map {
            ($0, IOSPlexArtwork.url(plex, item: $0, kind: .backdrop, width: width, aspectRatio: 16 / 9, scale: displayScale))
        })
    }

    private func heroPageWidth(_ proxy: GeometryProxy) -> CGFloat {
        IOSPlexHomeHero.pageWidth(proxy.size.width, bleed: proxy.safeAreaInsets)
    }

    private func fullSize(_ proxy: GeometryProxy) -> CGSize {
        CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top)
    }
}

extension View {
    /// With a hero the title goes and the bar turns clear over the artwork.
    func iosPlexHeroChrome(hero: Bool, title: String) -> some View {
        navigationTitle(hero ? "" : title)
            .navigationBarTitleDisplayMode(hero ? .inline : .large)
            .toolbar(removing: hero ? .title : nil)
            .toolbarBackgroundVisibility(hero ? .hidden : .automatic, for: .navigationBar)
    }
}
