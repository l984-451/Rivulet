// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Edge-to-edge paging hero. Advances every 7 s; a swipe restarts the wait.
/// Only the artwork pages, with a parallax lag like the tvOS detail carousel; the title
/// crossfades and the buttons stay put.
struct IOSPlexHomeHero: View {
    let items: [PlexMetadata]
    /// Screen size including the area under the navigation bar.
    let size: CGSize
    /// Side safe-area insets the artwork runs under, such as iPhone Duo's side bars.
    var bleed = EdgeInsets()
    @State private var selection: String?
    /// iPhone Duo's fold runs down the middle, so the dots sit at the leading margin.
    @State private var dotsLeading = false

    /// Share of the page travel the artwork lags behind, as in `PreviewCarouselLayout`.
    private static let parallax: CGFloat = 0.3

    private var isWide: Bool { size.width > size.height }
    private var pageWidth: CGFloat { Self.pageWidth(size.width, bleed: bleed) }
    private var heroHeight: CGFloat { max(Self.height(for: size), 300) }
    private var current: PlexMetadata? { items.first { $0.id == selection } ?? items.first }

    /// Wide: 16:9 capped at 60% of the height. Tall: a slightly cropped frame.
    static func height(for size: CGSize) -> CGFloat {
        size.width > size.height
            ? min(size.width * 9 / 16, size.height * 0.6)
            : min(size.width * 0.92, size.height * 0.46)
    }

    /// One artwork page: the content width plus the side insets it bleeds under.
    static func pageWidth(_ width: CGFloat, bleed: EdgeInsets) -> CGFloat {
        width + bleed.leading + bleed.trailing
    }

    var body: some View {
        if let current {
            ZStack(alignment: isWide ? .bottomLeading : .bottom) {
                // Full bleed, so no neighbouring page shows under a side bar.
                Group {
                    artworkPager
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.35),
                            .init(color: .black.opacity(0.75), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea(edges: .horizontal)
                IOSPlexHeroControls(item: current, isWide: isWide)
                if items.count > 1 {
                    pageDots
                }
            }
            .frame(height: heroHeight)
            .environment(\.colorScheme, .dark)
            // Keyed on the items too, so a refresh that drops the shown page restarts the rotation.
            .task(id: items.map(\.id) + [selection ?? ""]) {
                if selection == nil || !items.contains(where: { $0.id == selection }) {
                    selection = items.first?.id
                }
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled, items.count > 1,
                      let index = items.firstIndex(where: { $0.id == selection }) else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    selection = items[(index + 1) % items.count].id
                }
            }
        }
    }

    private var artworkPager: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                // Eager on purpose: a lazy stack blanked the outgoing page mid-scroll.
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        // Pages take the pager's own width, so they always match its paging step.
                        IOSPlexArtwork(item: item, kind: .backdrop, width: pageWidth, aspectRatio: 16 / 9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .visualEffect { content, proxy in
                                content.offset(x: -proxy.frame(in: .scrollView(axis: .horizontal)).minX * Self.parallax)
                            }
                            .containerRelativeFrame(.horizontal)
                            .frame(height: heroHeight)
                            .clipped()
                            .plexZoomSource(item)
                            .environment(\.plexZoomScope, "hero")
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $selection)
            // A resize (rotation, opening or closing iPhone Duo) keeps the old offset; re-seat the shown page.
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, _ in
                if let selection { reader.scrollTo(selection, anchor: .leading) }
            }
        }
        .accessibilityHidden(true)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                Circle()
                    .fill(.white.opacity(item.id == current?.id ? 1 : 0.4))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: dotsLeading ? .leading : .center)
        .padding(.horizontal, IOSShelfGeometry.leading)
        .padding(.bottom, 14)
        // Inactive folds count too, so the dots don't jump as the device folds.
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.duoFold(includeInactive: true).map { $0.height > $0.width } ?? false
        } action: { dotsLeading = $0 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Title, metadata and buttons for the shown page. The buttons never move; the title
/// and metadata crossfade when the page changes.
private struct IOSPlexHeroControls: View {
    let item: PlexMetadata
    let isWide: Bool
    @Environment(\.plexActions) private var actions

    private var metadataLine: String {
        [item.episodeCode ?? item.year.map(String.init), item.Genre?.first?.tag]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: isWide ? .leading : .center, spacing: 10) {
            ZStack(alignment: isWide ? .bottomLeading : .bottom) {
                title
                    .id(item.id)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.35), value: item.id)
            // Swipes on the title reach the artwork pager underneath.
            .allowsHitTesting(false)

            HStack(spacing: 12) {
                Button { actions.play(item) } label: {
                    Label(item.isInProgress ? "Resume" : "Play", systemImage: "play.fill")
                        .overlay { if actions.preparingID == item.id { ProgressView() } }
                }
                .buttonStyle(.glassProminent)
                NavigationLink(value: IOSPlexDetailRoute(item: item, scope: "hero")) {
                    Label("Details", systemImage: "info.circle")
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.horizontal, IOSShelfGeometry.leading)
        .padding(.bottom, 44)
    }

    private var title: some View {
        VStack(alignment: isWide ? .leading : .center, spacing: 10) {
            IOSPlexResolvedLogo(
                item: item,
                fallbackTitle: item.showTitle,
                maxWidth: isWide ? 380 : 260,
                maxHeight: isWide ? 110 : 80,
                fallbackFont: .largeTitle.bold(),
                alignment: isWide ? .bottomLeading : .bottom,
                textAlignment: isWide ? .leading : .center
            )
            Text(metadataLine.isEmpty ? " " : metadataLine)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }
}
