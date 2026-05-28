//
//  WatchlistHubRow.swift
//  Rivulet
//
//  Renders the user's Plex Watchlist as a horizontal row on Home. Mirrors the
//  visual style of MediaRow / MediaPosterCard so it blends with other hubs.
//

import SwiftUI
import os.log

private let watchlistRowLog = Logger(subsystem: "com.rivulet.app", category: "WatchlistHubRow")

struct WatchlistHubRow: View {
    @ObservedObject var watchlist: PlexWatchlistService

    /// Called when the user taps a tile to open the carousel preview. When
    /// nil, tap falls back to the legacy per-kind handlers below.
    var onPreviewRequested: ((PreviewRequest) -> Void)?
    /// Legacy direct-select fallbacks — library-matched vs. TMDB-only.
    /// Only invoked when `onPreviewRequested` is nil.
    let onSelectPlex: (PlexMetadata) -> Void
    let onSelectTMDB: (TMDBListItem) -> Void
    var onRowFocused: (() -> Void)?

    @Environment(\.uiScale) private var scale

    private var titleSize: CGFloat { ScaledDimensions.sectionTitleSize * scale }
    private var horizontalPadding: CGFloat { ScaledDimensions.rowHorizontalPadding }
    private var itemSpacing: CGFloat { ScaledDimensions.rowItemSpacing * scale }

    private let rowID = "home.watchlist"

    @FocusState private var focusedItemId: String?

    var body: some View {
        if watchlist.watchlistItems.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Watchlist")
                    .font(.system(size: titleSize, weight: .bold))
                    .padding(.horizontal, horizontalPadding)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: itemSpacing) {
                        ForEach(Array(watchlist.watchlistItems.prefix(20).enumerated()), id: \.element.id) { index, item in
                            Button {
                                tap(item: item, index: index)
                            } label: {
                                WatchlistTile(item: item)
                            }
                            .buttonStyle(CardButtonStyle())
                            .focused($focusedItemId, equals: item.id)
                            .previewSourceAnchor(rowID: rowID, itemID: item.id)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 32)
                }
                .scrollClipDisabled()
            }
            .focusSection()
            .defaultFocus($focusedItemId, watchlist.watchlistItems.first?.id)
            .onChange(of: focusedItemId) { oldValue, newValue in
                if oldValue == nil && newValue != nil {
                    onRowFocused?()
                }
            }
        }
    }

    /// On tap: if a preview handler is wired, open the carousel with all
    /// watchlist items as MediaItems. Each entry is first probed against
    /// `LibraryGUIDIndex` so library-matched items route through their
    /// Plex provider (getting real Play actions + Plex artwork), and
    /// non-matched items stay TMDB-backed.
    private func tap(item: PlexWatchlistItem, index: Int) {
        guard let onPreviewRequested else {
            Task { await legacySelect(item) }
            return
        }
        // Resolve the carousel asynchronously so we can do the library-match
        // round-trip + await the Plex auth context before presenting.
        Task {
            let allItems = Array(watchlist.watchlistItems.prefix(20))
            let pairs = await buildMediaItems(from: allItems)
            guard !pairs.isEmpty else {
                await MainActor.run { Task { await legacySelect(item) } }
                return
            }
            // Match on the originating watchlist entry id — robust across
            // both library-matched (Plex ratingKey) and TMDB-only itemID
            // encodings, and tolerant of entries that get skipped during
            // mapping (e.g. no tmdbId).
            let validIndex = pairs.firstIndex(where: { $0.sourceID == item.id }) ?? 0
            let mediaItems = pairs.map(\.item)
            await MainActor.run {
                onPreviewRequested(
                    PreviewRequest(
                        items: mediaItems,
                        selectedIndex: validIndex,
                        sourceRowID: rowID,
                        sourceItemID: item.id
                    )
                )
            }
        }
        _ = index // reserved for future use (e.g. row scrolling); kept for API shape
    }

    /// Build carousel-ready MediaItems for every watchlist entry.
    /// Library-matched entries use `PlexMediaMapper` (Plex providerID → Play
    /// actions in MediaDetailView + Plex artwork). Unmatched entries use
    /// `TMDBMediaMapper` with the watchlist poster spliced in; the carousel's
    /// prefetch loop will enrich backdrop/overview from TMDB detail.
    private func buildMediaItems(from entries: [PlexWatchlistItem]) async -> [(sourceID: String, item: MediaItem)] {
        let authManager = PlexAuthManager.shared
        let serverURL = authManager.selectedServerURL ?? ""
        let token = authManager.selectedServerToken ?? ""
        let providerID = await MainActor.run {
            MediaProviderRegistry.shared.primaryProvider?.id
        } ?? "plex:\(serverURL)"

        // Probe LibraryGUIDIndex in parallel — each entry's lookup is an
        // independent actor hop, so 20 items fan out to ~20 concurrent tasks
        // and complete in roughly one hop's latency instead of 20 serial ones.
        // Results are collected by index so the output preserves input order.
        let lookups = await withTaskGroup(of: (Int, PlexMetadata?).self) { group in
            for (index, entry) in entries.enumerated() {
                guard let tmdbId = entry.tmdbId else { continue }
                let mediaType: TMDBMediaType = entry.type == .movie ? .movie : .tv
                group.addTask {
                    let match = await LibraryGUIDIndex.shared.lookup(tmdbId: tmdbId, type: mediaType)
                    return (index, match)
                }
            }
            var out: [Int: PlexMetadata] = [:]
            for await (index, match) in group {
                if let match { out[index] = match }
            }
            return out
        }

        var result: [(sourceID: String, item: MediaItem)] = []
        result.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            guard let tmdbId = entry.tmdbId else { continue }
            let mediaType: TMDBMediaType = entry.type == .movie ? .movie : .tv

            // Library match wins — Plex ref so MediaDetailView shows
            // Play/Resume/Watched and the artwork comes from Plex.
            if let match = lookups[index], !serverURL.isEmpty {
                result.append((
                    sourceID: entry.id,
                    item: PlexMediaMapper.item(match,
                                               providerID: providerID,
                                               serverURL: serverURL,
                                               authToken: token)
                ))
                continue
            }

            // Not in library: TMDB-only. Build a stub; the prefetch loop in
            // PreviewOverlayHost will fetch the real TMDB detail (with
            // backdrop) when the card comes into the prefetch window.
            let stub = TMDBListItem(
                id: tmdbId,
                title: entry.title,
                overview: nil,
                posterPath: nil,
                backdropPath: nil,
                releaseDate: entry.year.map { "\($0)" },
                voteAverage: nil,
                mediaType: mediaType
            )
            var built = TMDBMediaMapper.item(stub)
            if let poster = entry.posterURL {
                built = MediaItem(
                    ref: built.ref,
                    kind: built.kind,
                    title: built.title,
                    sortTitle: built.sortTitle,
                    overview: built.overview,
                    year: built.year,
                    runtime: built.runtime,
                    parentRef: built.parentRef,
                    grandparentRef: built.grandparentRef,
                    episodeNumber: built.episodeNumber,
                    seasonNumber: built.seasonNumber,
                    childProgress: built.childProgress,
                    userState: built.userState,
                    artwork: MediaArtwork(
                        poster: poster,
                        backdrop: built.artwork.backdrop,
                        thumbnail: poster,
                        logo: built.artwork.logo
                    ),
                    parentArtwork: built.parentArtwork,
                    grandparentArtwork: built.grandparentArtwork
                )
            }
            result.append((sourceID: entry.id, item: built))
        }
        return result
    }

    /// Pre-carousel behavior: library-matched items go straight to
    /// MediaDetailView via onSelectPlex; TMDB-only items go via onSelectTMDB.
    /// Retained as a fallback in case a caller doesn't supply
    /// `onPreviewRequested`.
    private func legacySelect(_ item: PlexWatchlistItem) async {
        guard let tmdbId = item.tmdbId else {
            watchlistRowLog.warning("[Select] no tmdbId on \(item.title, privacy: .public), guids=\(item.guids.joined(separator: ","), privacy: .public)")
            return
        }
        let mediaType: TMDBMediaType = item.type == .movie ? .movie : .tv
        if let match = await LibraryGUIDIndex.shared.lookup(tmdbId: tmdbId, type: mediaType) {
            onSelectPlex(match)
            return
        }
        let stub = TMDBListItem(
            id: tmdbId,
            title: item.title,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: item.year.map { "\($0)" },
            voteAverage: nil,
            mediaType: mediaType
        )
        onSelectTMDB(stub)
    }
}

private struct WatchlistTile: View {
    let item: PlexWatchlistItem

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }

    var body: some View {
        poster
            .frame(width: posterWidth, height: posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.highlight)
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
    }

    @ViewBuilder
    private var poster: some View {
        if let url = item.posterURL {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    Rectangle()
                        .fill(Color(white: 0.15))
                        .overlay { ProgressView().tint(.white.opacity(0.3)) }
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.18), Color(white: 0.12)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay {
                Image(systemName: item.type == .movie ? "film" : "tv")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }
}
