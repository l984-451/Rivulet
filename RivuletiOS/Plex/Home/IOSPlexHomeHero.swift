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
    @State private var selection: String?

    /// Share of the page travel the artwork lags behind, as in `PreviewCarouselLayout`.
    private static let parallax: CGFloat = 0.3

    private var isWide: Bool { size.width > size.height }
    private var heroHeight: CGFloat { max(Self.height(for: size), 300) }
    private var current: PlexMetadata? { items.first { $0.id == selection } ?? items.first }

    /// Wide: 16:9 capped at 60% of the height. Tall: a slightly cropped frame.
    static func height(for size: CGSize) -> CGFloat {
        size.width > size.height
            ? min(size.width * 9 / 16, size.height * 0.6)
            : min(size.width * 0.92, size.height * 0.46)
    }

    var body: some View {
        if let current {
            ZStack(alignment: isWide ? .bottomLeading : .bottom) {
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
        ScrollView(.horizontal) {
            // Eager on purpose: a lazy stack blanked the outgoing page mid-scroll.
            HStack(spacing: 0) {
                ForEach(items) { item in
                    IOSPlexArtwork(item: item, kind: .backdrop, width: size.width, aspectRatio: 16 / 9)
                        .frame(width: size.width, height: heroHeight)
                        .clipped()
                        .visualEffect { content, proxy in
                            content.offset(x: -proxy.frame(in: .scrollView(axis: .horizontal)).minX * Self.parallax)
                        }
                        .frame(width: size.width, height: heroHeight)
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
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
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
