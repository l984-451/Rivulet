// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Edge-to-edge paging hero. Advances every 7 s; a swipe restarts the wait.
struct IOSPlexHomeHero: View {
    let items: [PlexMetadata]
    /// Screen size including the area under the navigation bar.
    let size: CGSize
    @State private var selection: String?

    private var isWide: Bool { size.width > size.height }

    /// Wide: 16:9 capped at 60% of the height. Tall: a slightly cropped frame.
    static func height(for size: CGSize) -> CGFloat {
        size.width > size.height
            ? min(size.width * 9 / 16, size.height * 0.6)
            : min(size.width * 0.92, size.height * 0.46)
    }

    var body: some View {
        if !items.isEmpty {
            TabView(selection: $selection) {
                ForEach(items) { item in
                    IOSPlexHeroPage(item: item, width: size.width, isWide: isWide)
                        .environment(\.plexZoomScope, "hero")
                        .tag(Optional(item.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
            .frame(height: max(Self.height(for: size), 300))
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
}

private struct IOSPlexHeroPage: View {
    let item: PlexMetadata
    let width: CGFloat
    let isWide: Bool
    @Environment(\.plexActions) private var actions

    private var metadataLine: String {
        [item.episodeCode ?? item.year.map(String.init), item.Genre?.first?.tag]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        ZStack(alignment: isWide ? .bottomLeading : .bottom) {
            IOSPlexArtwork(item: item, kind: .backdrop, width: width, aspectRatio: 16 / 9)
                .plexZoomSource(item)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.75), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

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
                if !metadataLine.isEmpty {
                    Text(metadataLine)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
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
    }
}
