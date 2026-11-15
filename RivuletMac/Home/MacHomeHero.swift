// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import SwiftUI

/// Full-width paging hero. Advances every 7 s unless the pointer is over it; the arrow buttons,
/// the dots and the Left and Right keys page it. The artwork slides; the title crossfades and the buttons stay put.
/// Port of RivuletiOS/Plex/Home/IOSPlexHomeHero.swift.
struct MacHomeHero: View {
    let items: [MediaItem]
    /// Width of the page the hero sits in.
    let width: CGFloat
    @Binding var selection: MediaItemRef?
    @State private var hovering = false
    @State private var inView = true
    @State private var isPaging = false

    /// Share of the page travel the artwork lags behind, as on iOS and tvOS.
    private static let parallax: CGFloat = 0.3
    @EnvironmentObject private var playback: MacPlaybackController
    @Environment(\.macOpen) private var open
    @Environment(\.scenePhase) private var scenePhase

    private var height: CGFloat { min(max(width * 0.42, 300), 520) }
    private var index: Int { items.firstIndex { $0.ref == selection } ?? 0 }
    private var current: MediaItem? { items[safe: index] }

    var body: some View {
        if let current {
            ZStack(alignment: .bottomLeading) {
                Group {
                    artworkPager
                    MacThemeVideoBackdrop(item: current.ref, isActive: inView && !isPaging, isCovered: playback.isPresented)
                        .allowsHitTesting(false)
                    LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.75), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
                .frame(width: width, height: height)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { open(.detail(current)) }
                // Fades out at the bottom into the page's ambient wash.
                .mask {
                    LinearGradient(stops: [.init(color: .white, location: 0.8), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                MacHeroControls(item: current)
                if items.count > 1 {
                    arrows
                    dots
                }
                pagingKeys
            }
            .frame(width: width, height: height)
            .environment(\.colorScheme, .dark)
            .macContextMenu(current)
            .onHover { hovering = $0 }
            .onScrollVisibilityChange(threshold: 0.3) { inView = $0 }
            // Keyed on the shown page, so any move restarts the wait and a refresh that drops it re-seats.
            .task(id: "\(current.ref.providerID)|\(current.ref.itemID)|\(items.count)|\(hovering)|\(autoAdvances)") {
                if selection == nil || !items.contains(where: { $0.id == selection }) { selection = items.first?.id }
                guard !hovering, autoAdvances else { return }
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                page(by: 1)
            }
        }
    }

    /// Rotation waits while the hero is out of view, under the player, or the app is not active.
    private var autoAdvances: Bool { inView && !playback.isPresented && scenePhase == .active }

    private func page(by step: Int) {
        guard items.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            selection = items[(index + step + items.count) % items.count].id
        }
    }

    /// Pages slide with a parallax lag, as on iOS; a trackpad swipe pages too.
    private var artworkPager: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                // Eager: a lazy stack blanked the outgoing page mid-scroll on iOS.
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        MacItemArtwork(item: item, kind: .backdrop, width: width, aspectRatio: 16 / 9, swapsTitledBackdrop: true)
                            .frame(width: width, height: height)
                            .clipped()
                            .visualEffect { content, proxy in
                                content.offset(x: -proxy.frame(in: .scrollView(axis: .horizontal)).minX * Self.parallax)
                            }
                            .frame(width: width, height: height)
                            .clipped()
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.never)
            .scrollPosition(id: $selection)
            .onScrollPhaseChange { _, phase in isPaging = phase != .idle }
            // A window resize keeps the old offset; re-seat the shown page.
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, _ in
                if let selection { reader.scrollTo(selection, anchor: .leading) }
            }
        }
        .accessibilityHidden(true)
    }

    private var arrows: some View {
        HStack {
            arrow("chevron.left", label: "Previous", step: -1)
            Spacer()
            arrow("chevron.right", label: "Next", step: 1)
        }
        .padding(.horizontal, MacMetrics.pageMargin)
        .frame(maxHeight: .infinity)
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func arrow(_ symbol: String, label: LocalizedStringKey, step: Int) -> some View {
        Button { page(by: step) } label: {
            Image(systemName: symbol).font(.title3.bold()).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: .circle)
        .accessibilityLabel(label)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                Button { withAnimation(.easeInOut(duration: 0.5)) { selection = item.id } } label: {
                    Circle().fill(.white.opacity(item.id == current?.id ? 1 : 0.4)).frame(width: 7, height: 7)
                        .padding(4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.displayTitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, MacMetrics.pageMargin)
        .padding(.bottom, 40)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// Left and Right page the hero while Home is showing.
    private var pagingKeys: some View {
        Group {
            Button("Previous") { page(by: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next") { page(by: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// Logo, metadata and buttons for the shown page; the logo and metadata crossfade between pages.
private struct MacHeroControls: View {
    let item: MediaItem
    @Environment(\.macActions) private var actions
    @Environment(\.macOpen) private var open

    private var metadataLine: String {
        [item.episodeCode ?? item.year.map(String.init), item.genres?.first].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    MacResolvedLogo(item: item, fallbackTitle: item.showTitle, maxWidth: 340, maxHeight: 110,
                                    fallbackFont: .largeTitle.bold(), alignment: .bottomLeading, textAlignment: .leading,
                                    targetArea: 17000)
                    Text(metadataLine.isEmpty ? " " : metadataLine)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .id(item.id)
                .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.35), value: item.id)
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                if IOSPlaybackGate.canPlay(item.ref) {
                    Button { actions.play(item) } label: {
                        Label(item.isInProgress ? "Resume" : "Play", systemImage: "play.fill")
                            .overlay { if actions.preparingID == item.ref.actionKey { ProgressView().controlSize(.small) } }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button { open(.detail(item)) } label: { Label("Details", systemImage: "info.circle") }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, MacMetrics.pageMargin)
        .padding(.bottom, 36)
    }
}
