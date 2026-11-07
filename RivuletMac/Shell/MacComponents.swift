// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import SwiftUI

// Shared primitives for every Mac feature: artwork, tiles, rails, grids, states.
// Modelled on RivuletiOS/Plex/Components/IOSPlexComponents.swift, with the pointer
// in mind: hover lift, click to open, context menu, header buttons to page a rail.

// MARK: - Artwork

/// Remote image through MacArtworkCache. A cached image is in place on the first frame,
/// so recreated tiles do not flash; a new URL keeps the old image until its replacement arrives.
struct MacImage: View {
    let url: URL?
    @State private var image: NSImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap(MacArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else { return }
                if let cached = MacArtworkCache.shared.cachedImage(for: url) {
                    image = cached
                    return
                }
                guard let loaded = await MacArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

/// A MediaItem's artwork, resized by its server to the pixel size the tile draws at.
struct MacItemArtwork: View {
    let item: MediaItem
    let kind: BrowseStore.ArtworkKind
    /// Display width in points.
    let width: CGFloat
    /// Width over height of the requested image.
    let aspectRatio: CGFloat
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        MacImage(url: Self.url(browse, item: item, kind: kind, width: width, aspectRatio: aspectRatio, scale: displayScale))
    }

    /// The exact URL this view requests, so a prefetch warms the same cache entry.
    /// Widths round up to 120px steps so nearby tile sizes share one cache entry.
    static func url(_ browse: BrowseStore, item: MediaItem, kind: BrowseStore.ArtworkKind,
                    width: CGFloat, aspectRatio: CGFloat, scale: CGFloat) -> URL? {
        let pixels = max(1, Int((width * scale / 120).rounded(.up))) * 120
        return browse.artworkURL(for: item, kind: kind, width: pixels, height: Int(CGFloat(pixels) / aspectRatio))
    }
}

/// Clear logo with a text fallback. Always drawn over a dark scrim, so white.
struct MacResolvedLogo: View {
    let item: MediaItem
    let fallbackTitle: String
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    var fallbackFont: Font = .title3.bold()
    var alignment: Alignment = .center
    var textAlignment: TextAlignment = .center
    /// Sizes the logo to this area by its own aspect so wide and tall logos read the same weight.
    var targetArea: CGFloat?

    @EnvironmentObject private var browse: BrowseStore
    @State private var loaded: (identity: String, image: NSImage)?

    private var sourceIdentity: String {
        "\(item.logoOwner.providerID)|\(item.logoOwner.itemID)|\(item.artwork.logo?.absoluteString ?? "")"
    }

    var body: some View {
        let cached = browse.cachedLogoURL(for: item).flatMap(MacArtworkCache.shared.cachedImage(for:))
        let logo = cached ?? (loaded?.identity == sourceIdentity ? loaded?.image : nil)
        ZStack(alignment: alignment) {
            if let logo {
                let size = logoSize(logo)
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: size.width, maxHeight: size.height)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .transition(.opacity)
            } else {
                Text(fallbackTitle)
                    .font(fallbackFont)
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
        .animation(.easeInOut(duration: 0.2), value: logo != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fallbackTitle)
        .accessibilityAddTraits(.isHeader)
        .task(id: sourceIdentity) {
            let identity = sourceIdentity
            guard let url = await browse.logoURL(for: item), !Task.isCancelled,
                  let image = await MacArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
            loaded = (identity, image)
        }
    }

    private func logoSize(_ image: NSImage) -> CGSize {
        guard let targetArea, image.size.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let ratio = image.size.width / image.size.height
        return CGSize(width: min((targetArea * ratio).squareRoot(), maxWidth),
                      height: min((targetArea / ratio).squareRoot(), maxHeight))
    }
}

// MARK: - Watch state and hover

/// A thin white bar on a translucent track.
struct MacProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(.white).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 2)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Progress bar along the bottom, or the watched check when there is no bar.
    func macWatchState(_ item: MediaItem) -> some View {
        overlay(alignment: .bottom) {
            if let fraction = item.progressBarFraction {
                MacProgressBar(fraction: fraction).padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.progressBarFraction == nil, item.isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(6)
            }
        }
    }

    /// The pointer's lift over a tile: a small scale and a soft shadow.
    func macTileHover() -> some View { modifier(MacTileHover()) }

    /// Small outlined badge, e.g. a rating.
    func macPill() -> some View {
        font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 1))
    }
}

private struct MacTileHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.03 : 1)
            .shadow(color: .black.opacity(hovering ? 0.3 : 0), radius: 10, y: 4)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Tiles

/// Opens a title's detail on click or Return, with the item menu on right-click.
struct MacTileButton<Content: View>: View {
    let item: MediaItem
    @ViewBuilder let content: () -> Content
    @Environment(\.macOpen) private var open

    var body: some View {
        Button { open(.detail(item)) } label: { content() }
            .buttonStyle(.plain)
            .macContextMenu(item)
    }
}

struct MacPosterCard: View {
    let item: MediaItem
    /// Fixed tile width, or nil to fill what the parent offers.
    var width: CGFloat? = nil
    var showsCaption = true

    private var ratio: CGFloat { item.isMusicItem ? 1 : 2 / 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacItemArtwork(item: item, kind: item.isMusicItem ? .thumb : .poster, width: width ?? 180, aspectRatio: ratio)
                .aspectRatio(ratio, contentMode: .fit)
                .macWatchState(item)
                .overlay(alignment: .topLeading) { editionBadge }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .macTileHover()

            if showsCaption {
                Text(item.kind == .episode ? item.showTitle : item.displayTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let caption = item.kind == .episode ? item.episodeCode : item.subtitle {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.showTitle, item.kind == .episode ? item.episodeCode : nil, edition]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(item.watchStateDescription)
    }

    /// Plex edition ("Director's Cut"), so two editions sharing a poster tell apart.
    private var edition: String? { item.editionTitle?.isEmpty == false ? item.editionTitle : nil }

    @ViewBuilder
    private var editionBadge: some View {
        if let edition {
            Text(edition)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
    }
}

/// Continue Watching: art at the tvOS card's 357:277, the logo placed as on tvOS, and progress with
/// "S2, E5 · 12 min left" along the bottom over a soft blur band.
struct MacContinueCard: View {
    static let aspectRatio: CGFloat = 357 / 277

    let item: MediaItem
    let width: CGFloat

    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    /// The art already shows the title, keyed by the art it was read from.
    @State private var artShowsTitle: (art: URL, shows: Bool)?
    @State private var signals = ContinueWatchingCardCompositor.Signals.none
    @State private var logoSize: CGSize?

    private var height: CGFloat { width / Self.aspectRatio }

    /// The title rests leading on the floor and moves clear of faces and busy art, as on tvOS.
    private var placedLogo: some View {
        let size = logoSize ?? browse.cachedLogoURL(for: item).flatMap(MacArtworkCache.shared.cachedImage(for:))?.size
        let placed = ContinueWatchingTitlePlacer.titleRect(card: CGSize(width: width, height: height), signals: signals, logoSize: size)
        return MacResolvedLogo(item: item, fallbackTitle: item.showTitle, maxWidth: placed.rect.width, maxHeight: placed.rect.height,
                               alignment: placed.side == .leading ? .leading : .trailing,
                               textAlignment: placed.side == .leading ? .leading : .trailing)
            .frame(width: placed.rect.width, height: placed.rect.height)
            .offset(x: placed.rect.minX, y: placed.rect.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(hidesLogo ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: hidesLogo)
    }

    private var checkedArt: URL? { browse.artworkURL(for: item, kind: .backdrop, width: 900, height: 506) }

    private var hidesLogo: Bool {
        guard let art = checkedArt else { return false }
        if let checked = artShowsTitle, checked.art == art { return checked.shows }
        return ArtworkTitleCheck.known(ArtworkTitleCheck.key(still: art, title: item.showTitle)) ?? false
    }

    private var info: String {
        [item.episodeCode, item.timeLeftText ?? item.runtimeText ?? item.year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            MacItemArtwork(item: item, kind: .backdrop, width: width, aspectRatio: Self.aspectRatio)
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.45)))
                .frame(height: height * 0.25)
                .frame(maxHeight: .infinity, alignment: .bottom)
            placedLogo
            infoBar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .macTileHover()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.showTitle, item.episodeCode].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(item.watchStateDescription)
        .task(id: checkedArt) { await checkArt() }
        .task(id: checkedArt) { await analyseArt() }
    }

    private func analyseArt() async {
        guard let art = checkedArt else { return }
        if let logo = await browse.logoURL(for: item) { logoSize = await MacArtworkCache.shared.image(for: logo)?.size }
        let found = await ContinueWatchingTitlePlacer.signals(key: art.absoluteString) {
            await MacArtworkCache.shared.image(for: art)?.cgImageRepresentation
        }
        guard !Task.isCancelled else { return }
        signals = found
    }

    private func checkArt() async {
        guard let art = checkedArt else { return }
        let logo = await browse.logoURL(for: item)
        let title = item.showTitle
        let shows = await ArtworkTitleCheck.answer(ArtworkTitleCheck.key(still: art, title: title), title: title) {
            guard let still = await MacArtworkCache.shared.image(for: art)?.cgImageRepresentation else { return nil }
            guard let logo else { return (still, nil) }
            guard let image = await MacArtworkCache.shared.image(for: logo)?.cgImageRepresentation else { return nil }
            return (still, image)
        }
        guard !Task.isCancelled else { return }
        artShowsTitle = (art, shows)
    }

    private var infoBar: some View {
        HStack(spacing: 6) {
            if let fraction = item.progressBarFraction {
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: 32, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 32 * fraction) }
            }
            Text(info)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .shadow(color: .black.opacity(0.3), radius: 2)
    }
}

// MARK: - Rails

/// "Title ›" heading that pushes the full grid.
struct MacShelfHeader: View {
    let title: String
    var hub: MediaHub?
    /// The row's server, named while more than one is signed in.
    var badge: String?
    @Environment(\.macOpen) private var open

    var body: some View {
        HStack(spacing: 4) {
            if let hub {
                Button { open(.hub(hub)) } label: { label(chevron: true) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows all")
            } else {
                label(chevron: false)
            }
        }
    }

    private func label(chevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.title3.bold())
            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
                    .padding(.leading, 4)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Shared page metrics.
enum MacMetrics {
    static let pageMargin: CGFloat = 28
    static let tileGap: CGFloat = 14
    static let posterWidth: CGFloat = 150
    static let landscapeWidth: CGFloat = 300
}

/// A horizontal row of tiles under a header, with chevron buttons that page it for a mouse.
/// `tile` receives the item and the tile width.
struct MacRail<Tile: View>: View {
    enum Kind { case poster, landscape }

    let title: String
    var hub: MediaHub?
    var kind: Kind = .poster
    let items: [MediaItem]
    var badge: String?
    @ViewBuilder let tile: (MediaItem, CGFloat) -> Tile
    @State private var leading = 0

    private var width: CGFloat { kind == .poster ? MacMetrics.posterWidth : MacMetrics.landscapeWidth }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    MacShelfHeader(title: title, hub: hub, badge: badge)
                    Spacer()
                    pager(proxy)
                }
                .padding(.horizontal, MacMetrics.pageMargin)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: MacMetrics.tileGap) {
                        ForEach(items) { tile($0, width).id($0.id) }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, MacMetrics.pageMargin, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func pager(_ proxy: ScrollViewProxy) -> some View {
        let step = kind == .poster ? 5 : 3
        HStack(spacing: 4) {
            Button { page(proxy, by: -step) } label: { Image(systemName: "chevron.left") }
                .disabled(leading == 0)
                .accessibilityLabel("Previous")
            Button { page(proxy, by: step) } label: { Image(systemName: "chevron.right") }
                .disabled(leading + step >= items.count)
                .accessibilityLabel("Next")
        }
        .buttonStyle(.borderless)
        .opacity(items.count > step ? 1 : 0)
    }

    private func page(_ proxy: ScrollViewProxy, by step: Int) {
        leading = min(max(0, leading + step), max(0, items.count - 1))
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(items[leading].id, anchor: .leading) }
    }
}

/// One Home hub as a titled row: Continue Watching as cards, anything else as posters.
struct MacShelfView: View {
    let hub: MediaHub
    @EnvironmentObject private var browse: BrowseStore

    private var items: [MediaItem] { Array(hub.items.prefix(HomeFeed.railLimit)) }
    private var isMergedContinueWatching: Bool { hub.id == BrowseStore.continueWatchingID && hub.providerID.isEmpty }

    var body: some View {
        if isMergedContinueWatching || hub.isContinueWatchingFamily {
            // The merged row spans every server, so no badge.
            MacRail(title: hub.title, hub: hub.pagingKey != nil ? hub : nil, kind: .landscape, items: items,
                    badge: isMergedContinueWatching ? nil : browse.labels.badge(providerID: hub.providerID)) { item, width in
                MacTileButton(item: item) { MacContinueCard(item: item, width: width) }
            }
        } else {
            MacRail(title: hub.title, hub: hub.pagingKey != nil ? hub : nil, kind: .poster, items: items,
                    badge: browse.labels.badge(providerID: hub.providerID)) { item, width in
                MacTileButton(item: item) { MacPosterCard(item: item, width: width) }
            }
        }
    }
}

// MARK: - Grid

/// Adaptive poster grid for libraries and See All. A nil slot is an item not fetched yet and
/// draws as a placeholder; `slotAppeared` reports each index shown.
struct MacPosterGrid: View {
    let slots: [MediaItem?]
    var slotAppeared: ((Int) -> Void)?

    init(slots: [MediaItem?], slotAppeared: ((Int) -> Void)?) {
        self.slots = slots
        self.slotAppeared = slotAppeared
    }

    /// A fully loaded list that pages by calling `loadMore` when the last tile appears.
    init(items: [MediaItem], loadMore: (() -> Void)?) {
        slots = items
        slotAppeared = { [count = items.count] index in
            if index == count - 1 { loadMore?() }
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MacMetrics.posterWidth), spacing: MacMetrics.tileGap, alignment: .top)],
                  spacing: 20) {
            ForEach(slots.indices, id: \.self) { index in
                Group {
                    if let item = slots[index] {
                        MacTileButton(item: item) { MacPosterCard(item: item) }
                    } else {
                        MacPosterPlaceholder()
                    }
                }
                .onAppear { slotAppeared?(index) }
            }
        }
        .padding(.horizontal, MacMetrics.pageMargin)
    }
}

/// A poster tile's shape while its item loads, captions included, so the grid doesn't shift.
private struct MacPosterPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(2 / 3, contentMode: .fit)
            Text(" ").font(.footnote.weight(.semibold))
            Text(" ").font(.caption)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - States

/// A server that failed to load, named, above the rows of the servers that answered.
struct MacServerFailureBanner: View {
    let failure: BrowseStore.FailedServer
    @EnvironmentObject private var browse: BrowseStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't load \(failure.name)").font(.subheadline.weight(.semibold))
                Text(failure.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Retry") { Task { await browse.refresh() } }
                .controlSize(.small)
        }
        .padding(.horizontal, MacMetrics.pageMargin)
        .accessibilityElement(children: .combine)
    }
}

/// Error state with Retry, used by every content surface.
struct MacErrorView: View {
    let title: LocalizedStringKey
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await retry() } }
        }
    }
}

// MARK: - Account

struct MacAccountAvatar: View {
    let url: URL?
    var size: CGFloat = 28

    var body: some View {
        MacImage(url: url)
            .overlay {
                if url == nil {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

extension PlexHomeUser {
    /// plex.tv serves Home avatars as absolute URLs.
    var avatarURL: URL? { thumb.flatMap(URL.init(string:)) }
}

/// The avatar every page puts at the trailing end of its toolbar; opens the account sheet.
struct MacAccountButton: View {
    @Environment(\.macOpenAccount) private var openAccount
    @EnvironmentObject private var plex: PlexSession
    /// Its libraries change on every Jellyfin or Emby sign-in and sign-out, which re-reads the name.
    @EnvironmentObject private var browse: BrowseStore
    @ObservedObject private var profiles = PlexUserProfileManager.shared

    var body: some View {
        Button(action: openAccount) {
            MacAccountAvatar(url: profiles.selectedUser?.avatarURL ?? plex.profileImageURL)
        }
        .buttonStyle(.plain)
        .help("Account")
        .accessibilityLabel("Account")
        .accessibilityValue(AccountName.resolve(plexProfile: profiles.selectedUser?.displayName,
                                                plexUser: plex.profileDisplayName,
                                                otherServerUsers: AccountName.otherServerUsers) ?? "")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// What a feature stub shows until its feature is built; names the iOS file it ports.
struct MacFeaturePlaceholder: View {
    let title: LocalizedStringKey
    let symbol: String
    let source: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text("Not built yet. Parity source: \(source)")
        }
    }
}
