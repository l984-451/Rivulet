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
    /// Side safe-area insets the artwork runs under: the floating sidebar's.
    var bleed = EdgeInsets()
    @Binding var selection: MediaItemRef?
    /// A page's artwork is on screen.
    var onPageShown: ((MediaItemRef) -> Void)?
    @State private var hovering = false
    @State private var inView = true
    @State private var isPaging = false

    /// Share of the page travel the artwork lags behind, as on iOS and tvOS.
    private static let parallax: CGFloat = 0.3
    @EnvironmentObject private var playback: MacPlaybackController
    @Environment(\.macOpen) private var open
    @Environment(\.heroCopies) private var copies
    @Environment(\.scenePhase) private var scenePhase

    private var height: CGFloat { min(max(width * 0.42, 300), 520) }
    private var pageWidth: CGFloat { Self.pageWidth(width, bleed: bleed) }

    /// One artwork page: the page width plus the side insets it bleeds under, as on iOS.
    static func pageWidth(_ width: CGFloat, bleed: EdgeInsets) -> CGFloat {
        width + bleed.leading + bleed.trailing
    }
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
                // Full bleed under the sidebar, as on iOS: inset by it, the pager's position and
                // its paging step disagreed and a swipe stuttered from page to page.
                .ignoresSafeArea(edges: .horizontal)
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
                        // Pages take the pager's own width, so they always match its paging step.
                        MacItemArtwork(item: item, kind: .backdrop, width: pageWidth, aspectRatio: 16 / 9, swapsTitledBackdrop: true)
                            .environment(\.onArtworkShown, onPageShown.map { report in { report(item.id) } })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .visualEffect { content, proxy in
                                content.offset(x: -proxy.frame(in: .scrollView(axis: .horizontal)).minX * Self.parallax)
                            }
                            .containerRelativeFrame(.horizontal)
                            .frame(height: height)
                            .clipped()
                            // Click and right-click live on the pages, inside the scroll view: a gesture
                            // around the pager hid it from hit testing, so a trackpad swipe never reached it.
                            .contentShape(Rectangle())
                            .onTapGesture { open(.detail(copies[item.ref] ?? item)) }
                            .macContextMenu(copies[item.ref] ?? item)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
                .background { MacHeroSwipeLimit().allowsHitTesting(false) }
            }
            .scrollTargetBehavior(MacHeroPaging())
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
        // The bubble is part of the label, so a click anywhere on it pages, not only on the glyph.
        Button { page(by: step) } label: {
            Image(systemName: symbol).font(.title3.bold()).frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
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

    /// Left and Right page the hero while the page is showing.
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

/// One page per swipe, as on iPad. System paging on the Mac settles on the page nearest where the
/// fingers left it, so a long swipe ran through several pages and a short one sprang back.
private struct MacHeroPaging: ScrollTargetBehavior {
    /// How far the fingers must carry the page to turn it. The Mac reports no swipe velocity here,
    /// so a short flick and a slow nudge look alike.
    static let turnDistance: CGFloat = 50

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let width = context.containerSize.width
        guard width > 0 else { return }
        let start = (context.originalTarget.rect.minX / width).rounded()
        let travel = target.rect.minX - context.originalTarget.rect.minX
        let step: CGFloat = abs(travel) < Self.turnDistance ? 0 : (travel > 0 ? 1 : -1)
        let lastPage = max(0, (context.contentSize.width / width).rounded() - 1)
        target.rect.origin.x = min(max(start + step, 0), lastPage) * width
    }
}

/// Stops a trackpad swipe a page from where it began, so the pager cannot be dragged through
/// several pages before `MacHeroPaging` settles it. Sits inside the pager to find its scroll view.
private struct MacHeroSwipeLimit: NSViewRepresentable {
    func makeNSView(context: Context) -> LimitView { LimitView() }
    func updateNSView(_ view: LimitView, context: Context) {}

    final class LimitView: NSView {
        private var monitor: Any?
        /// The pager's offset when a swipe on it began.
        private var startX: CGFloat?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.filter(event) ?? event
            }
        }

        private func filter(_ event: NSEvent) -> NSEvent? {
            guard let pager = enclosingScrollView, event.window === window else { return event }
            let x = pager.contentView.bounds.origin.x
            switch event.phase {
            case .began:
                startX = pager.bounds.contains(pager.convert(event.locationInWindow, from: nil)) ? x : nil
            case .changed:
                // The page moves against the delta: past a page, drop what would pull it further.
                if let startX, abs(x - startX) >= pager.contentView.bounds.width, (x - startX) * event.scrollingDeltaX < 0 {
                    return nil
                }
            case .ended, .cancelled:
                startX = nil
            default:
                break
            }
            return event
        }
    }
}

/// Logo, metadata and buttons for the shown page; the logo and metadata crossfade between pages.
private struct MacHeroControls: View {
    let item: MediaItem
    @Environment(\.macActions) private var actions
    @Environment(\.macOpen) private var open
    @Environment(\.heroCopies) private var copies

    /// What Play and Details reach: your copy of a Discover title when a server has it.
    private var target: MediaItem { copies[item.ref] ?? item }

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
                if IOSPlaybackGate.canPlay(target.ref) {
                    Button { actions.play(target) } label: {
                        Label(target.isInProgress ? "Resume" : "Play", systemImage: "play.fill")
                            .overlay { if actions.preparingID == target.ref.actionKey { ProgressView().controlSize(.small) } }
                    }
                    .buttonStyle(.borderedProminent)
                } else if target.isMetadataOnly {
                    MacHeroWatchlistButton(item: item)
                }
                Button { open(.detail(target)) } label: { Label("Details", systemImage: "info.circle") }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, MacMetrics.pageMargin)
        .padding(.bottom, 36)
    }
}

extension EnvironmentValues {
    /// Discover: your copy of a hero title (TMDB's), which its Play, Details, click and menu reach. Empty elsewhere.
    @Entry var heroCopies: [MediaItemRef: MediaItem] = [:]
}

/// A TMDB title's main button (Discover's hero): it has nothing to play, as on its page.
private struct MacHeroWatchlistButton: View {
    let item: MediaItem
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.macActions) private var actions
    /// Redraws when the list changes, which is where a TMDB title's answer comes from.
    @ObservedObject private var watchlist = PlexWatchlistService.shared

    var body: some View {
        if browse.supportsWatchlist(item) {
            let onList = browse.isOnWatchlist(item)
            let help: LocalizedStringKey = onList ? "Remove from Watchlist" : "Add to Watchlist"
            Button { actions.setWatchlisted(item, !onList) } label: {
                Label("Watchlist", systemImage: onList ? "checkmark" : "plus")
            }
            .buttonStyle(.borderedProminent)
            .help(help)
            .accessibilityLabel(help)
        }
    }
}
