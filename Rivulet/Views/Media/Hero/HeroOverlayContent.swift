//
//  HeroOverlayContent.swift
//  Rivulet
//
//  The focusable foreground of the hero — logo/metadata/tagline + button row
//  + paging dots — with a transparent background so the layer behind shows
//  through. Used by the home screen inside a ScrollView so it sits at the
//  same level as the Continue Watching row (and scrolls together with it).
//

import SwiftUI
import os.log

private let overlayLog = Logger(subsystem: "com.rivulet.app", category: "HeroOverlay")

struct HeroOverlayContent: View {
    let items: [PlexMetadata]
    let serverURL: String
    let authToken: String
    @Binding var currentIndex: Int
    let onInfo: (PlexMetadata) -> Void
    let onPlay: (PlexMetadata) -> Void
    var onHeroFocused: (() -> Void)? = nil
    var onHeroExited: (() -> Void)? = nil

    @ObservedObject private var watchlistService = PlexWatchlistService.shared

    @State private var resolvedPlayTargets: [String: PlexMetadata] = [:]
    /// Cache of full-metadata resolutions keyed by ratingKey. Populated lazily
    /// by Watchlist toggles when the hub item lacked a Guid array; lets the
    /// bookmark icon reflect reality after a successful add.
    @State private var resolvedForWatchlistCache: [String: PlexMetadata] = [:]
    @State private var isResolvingPlay: Bool = false
    /// Lags behind `currentIndex` by `slideSwapDelay` so the backdrop has
    /// time to crossfade before the logo/metadata/buttons swap in.
    @State private var displayedIndex: Int = 0
    @FocusState private var focusedButton: HeroButton?

    /// How long to wait after `currentIndex` changes before swapping the
    /// visible slide content. Keeps the metadata from popping in ahead of
    /// the backdrop art (matches the detail view's brief hold).
    private static let slideSwapDelay: Duration = .milliseconds(100)

    private var currentItem: PlexMetadata? {
        guard !items.isEmpty else { return nil }
        let clamped = max(0, min(currentIndex, items.count - 1))
        return items[clamped]
    }

    private var displayedItem: PlexMetadata? {
        guard !items.isEmpty else { return nil }
        let clamped = max(0, min(displayedIndex, items.count - 1))
        return items[clamped]
    }

    private var canAdvance: Bool { items.count > 1 }

    /// Must match the hero-section height computed in `PlexHomeView.contentView`
    /// and `PlexLibraryView.contentView` (`UIScreen.main.bounds.height - 180`).
    /// Set here explicitly so the layout doesn't depend on SwiftUI propagating
    /// the parent's `.frame(height:)` through the ZStack — which wasn't
    /// reaching the VStack reliably and caused the controls to overflow below
    /// the clipped hero bounds.
    private static let heroHeight: CGFloat = UIScreen.main.bounds.height - 200

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Push everything to the bottom of the hero.
                Spacer(minLength: 0)

                if let item = displayedItem {
                    VStack(alignment: .leading, spacing: 28) {
                        HeroSlideContent(
                            item: item,
                            serverURL: serverURL,
                            authToken: authToken
                        )
                        .id(item.ratingKey ?? "idx-\(displayedIndex)")
                        .transition(.opacity)

                        HeroButtonRow(
                            isResolvingPlay: isResolvingPlay,
                            isOnWatchlist: resolvedTmdbId(for: item).map { watchlistService.contains(tmdbId: $0) } ?? false,
                            canAdvance: canAdvance,
                            focusedButton: $focusedButton,
                            onPlay: { handlePlay(item) },
                            onToggleWatchlist: { Task { await toggleWatchlist(for: item) } },
                            onInfo: { onInfo(item) },
                            onNext: { advance() }
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 120)
                }

                // Reserve bottom space for dots so logo/buttons sit above them.
                Spacer().frame(height: 120)
            }

            // Paging dots — pinned to the bottom of the hero independently
            // of the logo/buttons column.
            if canAdvance {
                pagingDots
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.heroHeight)
        .onAppear {
            // Sync the displayed slide with the active index on first load.
            if displayedIndex != currentIndex {
                displayedIndex = currentIndex
            }
        }
        .onChange(of: currentIndex) { _, newIndex in
            Task { @MainActor in
                try? await Task.sleep(for: Self.slideSwapDelay)
                withAnimation(.easeInOut(duration: 0.22)) {
                    displayedIndex = newIndex
                }
            }
        }
        .onChange(of: focusedButton) { oldButton, newButton in
            if newButton != nil && oldButton == nil {
                onHeroFocused?()
                // Always land on Play when entering the hero. tvOS's directional
                // focus otherwise lands on whichever button sits above the
                // column you came up from (often the "next" arrow); Play is the
                // hero's primary action, so re-anchor to it for a predictable
                // entry. Only fires on entry (oldButton == nil), so navigating
                // between buttons once inside is unaffected.
                if newButton != .play {
                    focusedButton = .play
                }
            } else if newButton == nil && oldButton != nil {
                onHeroExited?()
            }
        }
        .onChange(of: items.map(\.ratingKey)) { _, _ in
            if currentIndex >= items.count { currentIndex = 0 }
            if displayedIndex >= items.count { displayedIndex = 0 }
        }
    }

    // MARK: - Paging Dots

    private var pagingDots: some View {
        HStack(spacing: 10) {
            ForEach(0..<items.count, id: \.self) { idx in
                Capsule()
                    .fill(Color.white.opacity(idx == displayedIndex ? 1.0 : 0.35))
                    .frame(width: idx == displayedIndex ? 22 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: displayedIndex)
            }
        }
    }

    // MARK: - Paging

    private func advance() {
        guard canAdvance else { return }
        // The backdrop reacts to `currentIndex` immediately; the visible
        // overlay follows ~100ms later via the onChange handler in `body`.
        currentIndex = (currentIndex + 1) % items.count
    }

    // MARK: - Play

    private func handlePlay(_ item: PlexMetadata) {
        guard !isResolvingPlay else { return }

        if let key = item.ratingKey, let cached = resolvedPlayTargets[key] {
            overlayLog.info("[HeroOverlay] Play (cached resolution) for \(key, privacy: .public)")
            onPlay(cached)
            return
        }

        // Fast path: movies and episodes need no resolution.
        if let type = item.type, type == "movie" || type == "episode" {
            onPlay(item)
            return
        }

        isResolvingPlay = true
        Task { @MainActor in
            let resolved = await HeroPlaySession.resolvePlaybackTarget(
                for: item,
                serverURL: serverURL,
                authToken: authToken
            )
            if let key = item.ratingKey {
                resolvedPlayTargets[key] = resolved
            }
            isResolvingPlay = false
            onPlay(resolved)
        }
    }

    // MARK: - Watchlist Toggle

    private func toggleWatchlist(for item: PlexMetadata) async {
        // Hub items often ship without the Guid array, so resolve full metadata
        // (which includes external IDs) before deriving a TMDB guid.
        let resolved = await resolvedForWatchlist(item)
        guard let tmdbId = resolved.tmdbId else {
            overlayLog.warning("Watchlist toggle aborted: no tmdbId on item \(resolved.ratingKey ?? "?", privacy: .public) title=\(resolved.title ?? "?", privacy: .public)")
            return
        }
        let guid = "tmdb://\(tmdbId)"
        let service = PlexWatchlistService.shared
        if service.contains(guid: guid) {
            overlayLog.info("Watchlist remove \(guid, privacy: .public)")
            await service.remove(guid: guid)
        } else {
            let watchType: PlexWatchlistItem.WatchlistType = (resolved.type == "show") ? .show : .movie
            let posterURL: URL? = {
                guard let thumbPath = resolved.thumb, !thumbPath.isEmpty else { return nil }
                return URL(string: "\(serverURL)\(thumbPath)?X-Plex-Token=\(authToken)")
            }()
            let watchlistItem = PlexWatchlistItem(
                id: guid,
                title: resolved.title ?? "",
                year: resolved.year,
                type: watchType,
                posterURL: posterURL,
                guids: [guid]
            )
            overlayLog.info("Watchlist add \(guid, privacy: .public)")
            await service.add(guid: guid, item: watchlistItem)
        }
    }

    private func resolvedForWatchlist(_ item: PlexMetadata) async -> PlexMetadata {
        if item.tmdbId != nil { return item }
        if let ratingKey = item.ratingKey, let cached = resolvedForWatchlistCache[ratingKey] {
            return cached
        }
        guard let ratingKey = item.ratingKey else { return item }
        do {
            let full = try await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            resolvedForWatchlistCache[ratingKey] = full
            return full
        } catch {
            overlayLog.warning("Watchlist metadata resolve failed for \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return item
        }
    }

    /// Returns the TMDB id for an item using the watchlist resolution cache when
    /// the raw hub item lacked a Guid array.
    private func resolvedTmdbId(for item: PlexMetadata) -> Int? {
        if let id = item.tmdbId { return id }
        if let key = item.ratingKey, let cached = resolvedForWatchlistCache[key] {
            return cached.tmdbId
        }
        return nil
    }

}
