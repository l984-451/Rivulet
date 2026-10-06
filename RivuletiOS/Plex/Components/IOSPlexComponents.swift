// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

// MARK: - Artwork

/// Remote image through IOSArtworkCache. A cached image is in place on the
/// first frame, so recreated tiles do not flash; a new URL keeps the old
/// image until its replacement arrives.
struct IOSPlexImage: View {
    let url: URL?
    @State private var image: UIImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap(IOSArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else { return }
                if let cached = IOSArtworkCache.shared.cachedImage(for: url) {
                    image = cached
                    return
                }
                guard let loaded = await IOSArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

/// An item's artwork, transcoded to the pixel size the tile draws at. Widths
/// round up to 120px steps so nearby tile sizes share one cache entry.
struct IOSPlexArtwork: View {
    let item: PlexMetadata
    let kind: IOSPlexSession.ArtworkKind
    /// Display width in points.
    let width: CGFloat
    /// Width over height of the requested image.
    let aspectRatio: CGFloat
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        IOSPlexImage(url: Self.url(plex, item: item, kind: kind, width: width, aspectRatio: aspectRatio, scale: displayScale))
    }

    /// The exact URL this view requests, so a prefetch warms the same cache entry.
    static func url(_ plex: IOSPlexSession, item: PlexMetadata, kind: IOSPlexSession.ArtworkKind,
                    width: CGFloat, aspectRatio: CGFloat, scale: CGFloat) -> URL? {
        let pixels = max(1, Int((width * scale / 120).rounded(.up))) * 120
        return plex.artworkURL(for: item, kind: kind, width: pixels, height: Int(CGFloat(pixels) / aspectRatio))
    }
}

/// Clear logo with a text fallback. Always drawn over a dark scrim, so white.
/// A logo already in the caches draws on the first frame, with no fade.
struct IOSPlexResolvedLogo: View {
    let item: PlexMetadata
    let fallbackTitle: String
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let fallbackFont: Font
    let alignment: Alignment
    let textAlignment: TextAlignment
    /// Sizes the logo to this area by its own aspect, as tvOS cards do, so wide
    /// and tall logos read the same weight. Nil fills the max box.
    var targetArea: CGFloat?

    @EnvironmentObject private var plex: IOSPlexSession
    @State private var loaded: (identity: String, image: UIImage)?

    private var sourceIdentity: String {
        let key = item.type == "episode"
            ? item.grandparentRatingKey
            : (item.type == "season" ? item.parentRatingKey : item.ratingKey)
        return "\(key ?? item.id)|\(item.clearLogoPath ?? "")"
    }

    var body: some View {
        let cached = plex.cachedLogoURL(for: item).flatMap(IOSArtworkCache.shared.cachedImage(for:))
        let logo = cached ?? (loaded?.identity == sourceIdentity ? loaded?.image : nil)
        ZStack(alignment: alignment) {
            if let logo {
                let size = logoSize(logo)
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: size.width, maxHeight: size.height)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .transition(.opacity)
            } else {
                // Leaves at once, so it never shows under the logo fading in.
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
            guard let url = await plex.logoURL(for: item),
                  !Task.isCancelled,
                  let image = await IOSArtworkCache.shared.image(for: url),
                  !Task.isCancelled else { return }
            loaded = (identity, image)
        }
    }

    private func logoSize(_ image: UIImage) -> CGSize {
        guard let targetArea, image.size.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let ratio = image.size.width / image.size.height
        return CGSize(width: min((targetArea * ratio).squareRoot(), maxWidth),
                      height: min((targetArea / ratio).squareRoot(), maxHeight))
    }
}

// MARK: - Watch state

extension View {
    /// Progress bar along the bottom, or the watched check when there is no bar.
    func plexWatchState(_ item: PlexMetadata) -> some View {
        overlay(alignment: .bottom) {
            if let fraction = item.progressBarFraction {
                ProgressView(value: fraction)
                    .tint(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(6)
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
}

extension PlexMetadata {
    /// VoiceOver value for a tile's watch state.
    var watchStateDescription: String {
        if let left = timeLeftText { return left }
        if let fraction = progressBarFraction { return "\(Int(fraction * 100)) percent watched" }
        return isWatched ? "Watched" : ""
    }

    /// PlexMetadata's `==` compares only ratingKey, so SwiftUI skips a tile whose
    /// watch state changed. Tiles store this so the change reaches their body.
    var watchStamp: [Int] { [viewOffset ?? 0, viewCount ?? 0, viewedLeafCount ?? 0, lastViewedAt ?? 0] }
}

// MARK: - Tiles

/// Sizes a tile from a known width, or keeps the aspect ratio when the
/// parent decides the width (grid columns, search rows).
struct TileSize: ViewModifier {
    let width: CGFloat?
    let ratio: CGFloat

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, height: width / ratio)
        } else {
            content.aspectRatio(ratio, contentMode: .fit)
        }
    }
}

struct IOSPlexPosterCard: View {
    let item: PlexMetadata
    /// Fixed tile width, or nil to fill what the parent offers.
    var width: CGFloat? = nil
    var showsCaption = true
    private let watchStamp: [Int]

    init(item: PlexMetadata, width: CGFloat? = nil, showsCaption: Bool = true) {
        self.item = item
        self.width = width
        self.showsCaption = showsCaption
        watchStamp = item.watchStamp
    }

    private var ratio: CGFloat { item.isMusic ? 1 : 2 / 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IOSPlexArtwork(
                item: item,
                kind: item.isMusic ? .thumb : .poster,
                width: width ?? 180,
                aspectRatio: ratio
            )
            .modifier(TileSize(width: width, ratio: ratio))
            .plexWatchState(item)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .plexZoomSource(item)

            if showsCaption {
                Text(item.type == "episode" ? item.showTitle : item.displayTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let caption = item.type == "episode" ? item.episodeCode : item.subtitle {
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
        .accessibilityLabel([item.showTitle, item.type == "episode" ? item.episodeCode : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(item.watchStateDescription)
    }
}

/// Continue Watching, the tvOS card: art at the Apple TV app's ~1.29:1, the
/// logo centred, and a play icon, progress and "S2, E5 · 12 min left" along
/// the bottom over a soft blur band.
struct IOSPlexContinueCard: View {
    /// tvOS `MediaRowMetrics` cwWidth / cwHeight (357 x 277).
    static let aspectRatio: CGFloat = 357 / 277

    let item: PlexMetadata
    let width: CGFloat
    private let watchStamp: [Int]

    init(item: PlexMetadata, width: CGFloat) {
        self.item = item
        self.width = width
        watchStamp = item.watchStamp
    }

    private var height: CGFloat { width / Self.aspectRatio }

    private var info: String {
        [item.episodeCode, item.timeLeftText ?? item.runtimeText ?? item.year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            IOSPlexArtwork(item: item, kind: .backdrop, width: width, aspectRatio: Self.aspectRatio)
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.45)))
                .frame(height: height * 0.25)
                .frame(maxHeight: .infinity, alignment: .bottom)
            // tvOS: 18000 pt² on a 357pt card, at most 75% wide and 45% tall.
            IOSPlexResolvedLogo(
                item: item,
                fallbackTitle: item.showTitle,
                maxWidth: width * 0.75,
                maxHeight: height * 0.45,
                fallbackFont: .title3.bold(),
                alignment: .center,
                textAlignment: .center,
                targetArea: 18000 * pow(width / 357, 2)
            )
            infoBar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .plexZoomSource(item)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.showTitle, item.episodeCode].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(item.watchStateDescription)
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
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: 32 * fraction)
                    }
            }
            Text(info)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .shadow(color: .black.opacity(0.3), radius: 2)
    }
}

// MARK: - Shelves

/// A See All destination: one hub, paged through its own key.
struct IOSPlexHubRoute: Hashable {
    let hub: PlexHub

    /// Continue Watching is the cache-busted fetch, and a literal id list is a
    /// fixed set, so neither pages.
    var pages: Bool {
        guard !hub.isContinueWatching, let key = hub.key ?? hub.hubKey else { return false }
        return !key.hasPrefix("/library/metadata/")
    }
}

/// "Title ›" heading that pushes the full grid.
struct IOSPlexShelfHeader: View {
    let title: String
    var route: IOSPlexHubRoute?

    var body: some View {
        Group {
            if let route {
                NavigationLink(value: route) { label(chevron: true) }
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
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// The tvOS shelf equation: width = 2*leading + N*tile + (N-1)*gap with N odd,
/// so the middle tile is centred and every snap shows a (leading - gap) peek
/// of each neighbour. Tiles take their width from the row's container.
struct IOSShelfGeometry {
    enum Kind {
        case poster, landscape, person

        /// Smallest tile before the row drops to the next smaller odd count.
        func minimumTile(wide: Bool) -> CGFloat {
            switch self {
            case .poster: wide ? 140 : 105
            case .landscape: wide ? 210 : 280
            case .person: wide ? 96 : 84
            }
        }

        /// Largest share of a phone-width row one tile may take; a capped tile
        /// stays centred with wider, still equal, peeks.
        func maximumShare(wide: Bool) -> CGFloat? {
            self == .landscape && !wide ? 0.64 : nil
        }
    }

    static let gap: CGFloat = 8
    /// The page margin rows, their headers and the hero text all share; the
    /// system large title and toolbar sit on it too.
    static let leading: CGFloat = 20
    let tileWidth: CGFloat
    /// The row's content margin: `leading`, or more when a capped tile is centred.
    let rowLeading: CGFloat

    /// `textScale` grows the minimum with Dynamic Type, so larger text gets fewer, wider tiles.
    init(width: CGFloat, kind: Kind, textScale: CGFloat = 1) {
        let content = width - 2 * Self.leading
        let minimum = kind.minimumTile(wide: width >= 600) * max(1, textScale)
        func tile(_ count: Int) -> CGFloat { (content - CGFloat(count - 1) * Self.gap) / CGFloat(count) }
        // Three smaller tiles, down to 60% of the minimum, beat one oversized tile.
        var count = tile(3) >= minimum * 0.6 ? 3 : 1
        while tile(count + 2) >= minimum { count += 2 }
        var width0 = tile(count)
        if let share = kind.maximumShare(wide: width >= 600) { width0 = min(width0, width * share) }
        tileWidth = max(0, width0)
        let used = CGFloat(count) * tileWidth + CGFloat(count - 1) * Self.gap
        rowLeading = max(Self.leading, (width - used) / 2)
    }
}

/// A horizontal row on the shelf geometry, snapping a tile to the leading margin.
/// `tile` receives the tile width.
struct IOSShelfRow<Items: RandomAccessCollection, Header: View, Tile: View>: View where Items.Element: Identifiable {
    let kind: IOSShelfGeometry.Kind
    let items: Items
    @ViewBuilder let header: () -> Header
    @ViewBuilder let tile: (Items.Element, CGFloat) -> Tile
    /// Item to rest on at the leading margin, e.g. an episode list's next up.
    var initialID: Items.Element.ID?
    @State private var width: CGFloat = 0
    /// Bound so a width change re-anchors on the same tile, on the new pitch.
    @State private var anchor: Items.Element.ID?
    @ScaledMetric private var textScale: CGFloat = 1

    init(kind: IOSShelfGeometry.Kind, items: Items, initialID: Items.Element.ID? = nil,
         @ViewBuilder header: @escaping () -> Header,
         @ViewBuilder tile: @escaping (Items.Element, CGFloat) -> Tile) {
        self.kind = kind
        self.items = items
        self.initialID = initialID
        self.header = header
        self.tile = tile
        _anchor = State(initialValue: initialID)
    }

    var body: some View {
        let geometry = IOSShelfGeometry(width: width, kind: kind, textScale: textScale)
        VStack(alignment: .leading, spacing: 10) {
            header().padding(.horizontal, IOSShelfGeometry.leading)
            if geometry.tileWidth > 0 {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: IOSShelfGeometry.gap) {
                        ForEach(items) { tile($0, geometry.tileWidth) }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, geometry.rowLeading, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $anchor, anchor: .leading)
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: initialID) { anchor = initialID }
    }
}

/// One Home hub as a titled row.
struct IOSPlexShelfView: View {
    let hub: PlexHub
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let route = IOSPlexHubRoute(hub: hub)
        if hub.isContinueWatching {
            IOSPlexRail(title: hub.displayTitle, route: route, kind: .landscape, items: hub.items) { item, width in
                IOSPlexContinueCard(item: item, width: width)
                    .task(id: width) { await prefetchAhead(of: item, width: width) }
            }
        } else {
            IOSPlexRail(title: hub.displayTitle, route: route, kind: .poster, items: hub.items) {
                IOSPlexPosterCard(item: $0, width: $1)
            }
        }
    }

    /// Warms the logos and art of the next few cards past one that just
    /// appeared, so they are drawn before they scroll in. A window, not the
    /// whole hub, so the prefetch never evicts the cards on screen.
    private func prefetchAhead(of item: PlexMetadata, width: CGFloat) async {
        guard let index = hub.items.firstIndex(where: { $0.id == item.id }) else { return }
        await plex.prefetchArtwork(hub.items.dropFirst(index + 1).prefix(6).map {
            ($0, IOSPlexArtwork.url(plex, item: $0, kind: .backdrop, width: width,
                                    aspectRatio: IOSPlexContinueCard.aspectRatio, scale: displayScale))
        })
    }
}

/// Titled row of Plex items; each tile pushes its detail and has the item menu.
struct IOSPlexRail<Tile: View>: View {
    let title: String
    var route: IOSPlexHubRoute?
    let kind: IOSShelfGeometry.Kind
    let items: [PlexMetadata]
    @ViewBuilder let tile: (PlexMetadata, CGFloat) -> Tile

    /// Each rail owns its zoom sources; an item can sit in several rows.
    private var zoomScope: String { route?.hub.hubIdentifier ?? title }

    var body: some View {
        IOSShelfRow(kind: kind, items: items) {
            IOSPlexShelfHeader(title: title, route: route)
        } tile: { item, width in
            NavigationLink(value: IOSPlexDetailRoute(item: item, scope: zoomScope)) { tile(item, width) }
                .buttonStyle(.plain)
                .plexContextMenu(item)
        }
        .environment(\.plexZoomScope, zoomScope)
    }
}

/// Adaptive poster grid for libraries and See All. Calls `loadMore` when the
/// last tile appears.
struct IOSPlexPosterGrid: View {
    let items: [PlexMetadata]
    var loadMore: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var minimumWidth: CGFloat = 104

    var body: some View {
        let minimum = min(minimumWidth * (sizeClass == .regular ? 1.4 : 1), 260)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 12, alignment: .top)], spacing: 18) {
            ForEach(items) { item in
                NavigationLink(value: item) { IOSPlexPosterCard(item: item) }
                    .buttonStyle(.plain)
                    .plexContextMenu(item)
                    .onAppear {
                        if item.id == items.last?.id { loadMore?() }
                    }
            }
        }
        .padding(.horizontal, IOSShelfGeometry.leading)
    }
}

/// Error state with Retry, used by every content surface. Home and Library
/// also offer the Downloads list when there is something in it.
struct IOSPlexErrorView: View {
    let title: String
    let message: String
    var offersDownloads = false
    let retry: () async -> Void
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @Environment(\.openDownloads) private var openDownloads

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await retry() } }
                .buttonStyle(.bordered)
            if offersDownloads, !downloads.visibleRecords.isEmpty {
                Button("Go to Downloads", action: openDownloads)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

extension View {
    func plexPill() -> some View {
        font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 1))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
