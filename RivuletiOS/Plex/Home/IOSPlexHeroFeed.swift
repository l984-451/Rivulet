// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// A hero carousel over a stack of rows: Home, and a library's Recommended page.
/// The caller applies `iosPlexHeroChrome` with the same `heroItems` so the bar steps aside for the hero.
struct IOSPlexHeroFeed: View {
    let rows: [MediaHub]
    let heroItems: [MediaItem]
    var banners: [BrowseStore.FailedServer] = []
    let refresh: () async -> Void
    /// The hero's own lists (trending, watchlist) have arrived, so its first page will not change.
    var heroSettled = true
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    @Environment(\.launchHeroReady) private var launchHeroReady
    /// While the hero sits under the bar, the bar's scroll edge blur stays off.
    @State private var heroUnderBar = true
    @State private var heroSelection: MediaItemRef?
    /// Hero pages drawn so far, until the launch splash has been told.
    @State private var shownHeroPages: Set<MediaItemRef> = []
    @State private var toldLaunch = false

    var body: some View {
        let hero = !heroItems.isEmpty
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if hero {
                        IOSPlexHomeHero(items: heroItems, size: fullSize(proxy), bleed: proxy.safeAreaInsets,
                                        selection: $heroSelection,
                                        onPageShown: toldLaunch ? nil : { _ = shownHeroPages.insert($0) })
                    }
                    ForEach(banners) { IOSServerFailureBanner(failure: $0) }
                    ForEach(rows) { hub in
                        if hub.id == FavoriteChannelsRow.identifier {
                            IOSFavoriteChannelsRow()
                        } else {
                            IOSPlexShelfView(hub: hub)
                        }
                    }
                }
                .padding(.bottom, 24)
                .background(RefreshSpinnerOffset(offset: hero ? proxy.safeAreaInsets.top : 0))
            }
            .ignoresSafeArea(edges: hero ? .top : [])
            .onScrollGeometryChange(for: Bool.self) { scroll in
                scroll.contentOffset.y + scroll.contentInsets.top < IOSPlexHomeHero.height(for: fullSize(proxy)) - 120
            } action: { _, under in heroUnderBar = under }
            .scrollEdgeEffectHidden(hero && heroUnderBar, for: .top)
            .refreshable { await refresh() }
            .task(id: hero ? heroItems.map { "\($0.ref.providerID)|\($0.ref.itemID)" } + ["\(heroPageWidth(proxy))"] : []) {
                if hero { await prefetchHero(width: heroPageWidth(proxy)) }
            }
            // The launch splash leaves once the hero it reveals is drawn, not merely downloaded.
            .onChange(of: heroSettled && heroItems.first.map { shownHeroPages.contains($0.id) } == true, initial: true) { _, drawn in
                guard drawn, !toldLaunch else { return }
                toldLaunch = true
                launchHeroReady()
            }
            .iosPlexAmbient(hero ? heroItems.first { $0.ref == heroSelection } ?? heroItems.first : nil)
        }
    }

    /// Warms the hero pages' logos and art at the size the hero requests.
    /// Continue Watching cards warm their own look-ahead as they appear.
    private func prefetchHero(width: CGFloat) async {
        await browse.prefetchArtwork(heroItems.map {
            ($0, IOSItemArtwork.url(browse, item: $0, kind: .backdrop, width: width, aspectRatio: 16 / 9, scale: displayScale))
        })
    }

    private func heroPageWidth(_ proxy: GeometryProxy) -> CGFloat {
        IOSPlexHomeHero.pageWidth(proxy.size.width, bleed: proxy.safeAreaInsets)
    }

    private func fullSize(_ proxy: GeometryProxy) -> CGSize {
        CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top)
    }
}

/// Under a hero the scroll view runs to the top of the screen, and pull to refresh draws its
/// spinner there, behind the bar. This lowers the spinner by `offset` and draws it in front of
/// the content, since the hero now sits where it lands. SwiftUI offers no placement for it.
private struct RefreshSpinnerOffset: UIViewRepresentable {
    let offset: CGFloat

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.offset = offset
    }

    final class Probe: UIView {
        var offset: CGFloat = 0 {
            didSet { if offset != oldValue { apply() } }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // The refresh control is attached in the same update, so look once it has finished.
            Task { @MainActor [weak self] in self?.apply() }
        }

        private func apply() {
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let control = (view as? UIScrollView)?.refreshControl else { return }
            control.layer.sublayerTransform = CATransform3DMakeTranslation(0, offset, 0)
            control.layer.zPosition = offset > 0 ? 1 : 0
        }
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
