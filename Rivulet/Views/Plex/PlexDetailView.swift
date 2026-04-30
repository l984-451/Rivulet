//
//  PlexDetailView.swift
//  Rivulet
//
//  Detail view for movies and TV shows with playback options
//

import SwiftUI

enum PlexDetailPresentationMode: Equatable {
    case previewCarousel
    case expandedDetail
}

struct PlexDetailView: View {
    let item: PlexMetadata
    var presentationMode: PlexDetailPresentationMode = .expandedDetail
    var backgroundParallaxOffset: CGFloat = 0
    var showVignette: Bool = true
    var showMetadata: Bool = true
    var showExpandedChrome: Bool = true
    var showsBackdropLayer: Bool = true
    var allowVerticalScroll: Bool = true
    var allowActionRowInteraction: Bool = true
    var heroBackdropMotionLocked: Bool = false
    var backdropStageSize: CGSize? = nil
    var backdropWindowFrame: CGRect? = nil
    var onPreviewExitRequested: (() -> Void)? = nil
    var onDetailsBecameVisible: (() -> Void)? = nil
    var enableDetailDataLoading: Bool = true
    /// When hosted inside `PreviewOverlayHost`, reflects whether the entry /
    /// paging animation has fully settled. The detail data cascade is deferred
    /// until this flips to `true` so the main thread stays quiet while the
    /// spring + staged fades are running.
    var previewAnimationSettled: Bool = true

    /// Tracks the currently displayed item - allows swapping content in place
    /// When set, this overrides `item` so collection/recommended navigation
    /// replaces content rather than pushing a new view
    @State private var displayedItem: PlexMetadata?

    /// The item currently being shown - either displayedItem or the original item
    private var currentItem: PlexMetadata {
        displayedItem ?? item
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.previewMenuBridge) private var menuBridge
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var seasons: [PlexMetadata] = []
    @State private var selectedSeason: PlexMetadata?
    @State private var episodes: [PlexMetadata] = []
    @State private var isLoadingSeasons = false
    @State private var isLoadingEpisodes = false
    @State private var showPlayer = false
    @State private var selectedEpisode: PlexMetadata?
    @State private var lastPlayedMetadata: PlexMetadata?  // Tracks what was playing when player dismissed (for auto-play)
    @State private var fullEpisodeMetadata: [String: PlexMetadata] = [:]  // Prefetched full metadata keyed by ratingKey
    @State private var nextUpEpisode: PlexMetadata?  // The episode that will play when pressing Play on a show

    // Music album state
    @State private var tracks: [PlexMetadata] = []
    @State private var isLoadingTracks = false
    @State private var selectedTrack: PlexMetadata?

    // Music artist state
    @State private var albums: [PlexMetadata] = []
    @State private var isLoadingAlbums = false
    @State private var navigateToAlbum: PlexMetadata?  // For binding-based navigation
    @State private var artistTracks: [PlexMetadata] = []  // All tracks for "Play All"
    @State private var isLoadingArtistTracks = false
    @State private var showBioSheet = false  // Show artist bio

    // Focus state for restoring focus when returning from nested navigation
    @FocusState private var focusedAlbumId: String?
    @FocusState private var focusedTrackId: String?
    @FocusState private var focusedEpisodeId: String?  // Track focused episode
    @FocusState private var focusedActionButton: String?  // Track focused action button
    @State private var savedAlbumFocus: String?  // Save focus when navigating to album
    @State private var savedTrackFocus: String?  // Save focus when playing track
    @State private var isSummaryExpanded = false  // Expand summary text on focus/click

    // New state for cast/crew, collections, and recommendations
    @State private var fullMetadata: PlexMetadata?
    @State private var collectionItems: [PlexMetadata] = []
    @State private var collectionName: String?
    @State private var recommendedItems: [PlexMetadata] = []
    @State private var isWatched = false
    @State private var isStarred = false  // For music: 5-star rating toggle
    @State private var displayedProgress: Double = 0  // For animating progress bar
    @State private var isLoadingExtras = false
    @State private var showTrailerPlayer = false
    @State private var trailerMetadata: PlexMetadata?  // Full metadata for trailer playback
    @State private var playFromBeginning = false  // For "Play from Beginning" button
    @State private var isLoadingShufflePlay = false

    // Pre-play track picker state. Selections are per-detail-page-visit
    // and are passed to the player on Play; we don't touch the saved
    // language preference managers, so future plays still default to
    // remembered language defaults until the user explicitly picks again.
    @State private var preplayAudioTrackId: Int? = nil
    @State private var preplaySubtitleSelection: UniversalPlayerViewModel.InitialSubtitleSelection = .auto
    @State private var showAudioTrackPicker = false
    @State private var showSubtitleTrackPicker = false

    /// In-flight serialised chain of pre-play picker writes (Plex stream
    /// selection PUT + fullMetadata refresh). presentPlayer awaits this
    /// before building the player VM so the HLS URL is constructed
    /// against Plex's updated server-side state.
    @State private var pendingPreplayWrite: Task<Void, Never>? = nil
    @State private var shuffledEpisodeQueue: [PlexMetadata] = []
    @StateObject private var heroBackdrop = HeroBackdropCoordinator()
    @State private var belowFoldLoaded = false  // Flipped true after the full cascade finishes
    @State private var scrollProgress: CGFloat = 0  // 0 = at rest (peek), 1 = fully scrolled
    @State private var belowFoldTitleOpacity: CGFloat = 0
    @State private var scrollResetID = UUID()
    @State private var kenBurnsOffset: CGFloat = 0
    @State private var retainedLogoURL: URL?
    @State private var hasDisplayedHeroLogoImage = false
    @State private var parentShowLogoPath: String?

    // Navigation state for episode parent navigation
    @State private var navigateToSeason: PlexMetadata?
    @State private var navigateToShow: PlexMetadata?
    @State private var navigateToEpisode: PlexMetadata?
    @State private var isLoadingNavigation = false

    // Unified episode list state (all seasons in one scroll)
    @State private var unifiedEpisodes: [PlexMetadata] = []
    @State private var episodeScrollTarget: String? = nil
    @State private var scrollToTopTrigger = false
    @State private var browseActivity: NSUserActivity?

    private let networkManager = PlexNetworkManager.shared
    private let recommendationService = PersonalizedRecommendationService.shared
    private var isPreviewCarousel: Bool { presentationMode == .previewCarousel }
    private var isExpandedPreviewFlow: Bool { onPreviewExitRequested != nil && presentationMode == .expandedDetail }
    private var shouldLoadDetailData: Bool {
        if !isPreviewCarousel { return true }
        return enableDetailDataLoading
    }
    /// Cascade work is gated on both `shouldLoadDetailData` (which card is
    /// current) and `previewAnimationSettled` (no animation in flight). Both
    /// must be satisfied before we start hitting the network on MainActor.
    private var canRunDetailCascade: Bool {
        shouldLoadDetailData && previewAnimationSettled
    }
    /// Task ID keyed only on the rating key. We deliberately do *not* include
    /// `shouldLoadDetailData` or `previewAnimationSettled` here — those gates
    /// are checked *inside* the task body via early-return, and a separate
    /// `.onChange` re-invokes `loadDetailData()` when they flip. Including
    /// them in the task ID would cause `.task(id:)` to cancel and restart
    /// mid-paging when `isCurrent` flips, which was the dominant paging-jank
    /// source.
    private var detailLoadTaskID: String {
        currentItem.ratingKey ?? "unknown"
    }
    private var effectiveHeroLogoURL: URL? {
        heroBackdrop.session.logoURL ?? retainedLogoURL
    }
    private var heroBackdropScale: CGFloat {
        (isPreviewCarousel || isExpandedPreviewFlow) ? 1.14 : 1.08
    }
    private var heroOverlayHorizontalInset: CGFloat {
        if isPreviewCarousel { return 118 }
        if isExpandedPreviewFlow { return 128 }
        return 140
    }

    private var heroLogoMaxWidth: CGFloat {
        (isPreviewCarousel || isExpandedPreviewFlow) ? 620 : 520
    }

    private var heroLogoSlotHeight: CGFloat {
        (isPreviewCarousel || isExpandedPreviewFlow) ? 138 : 120
    }

    private var heroActionRowTopPadding: CGFloat {
        (isPreviewCarousel || isExpandedPreviewFlow) ? 32 : 24
    }

    /// Effective vignette visibility — vignette fades in before text (Apple TV+ two-phase reveal)
    private var effectiveVignetteVisible: Bool {
        guard showVignette else { return false }
        if !isPreviewCarousel && !isExpandedPreviewFlow { return true }
        return true
    }

    /// Effective metadata visibility — requires both the host's staged fade
    /// timing (`showMetadata`) AND `fullMetadata` being loaded, so genres,
    /// cast, and summary all appear together. Because `loadFullMetadata`
    /// fires immediately on appear (not gated by `previewAnimationSettled`),
    /// it typically returns before the text fade at ~750ms.
    private var effectiveMetadataVisible: Bool {
        guard showMetadata else { return false }
        if isPreviewCarousel || isExpandedPreviewFlow {
            return fullMetadata != nil
        }
        return true
    }

    private var heroBrandTitle: String {
        if currentItem.type == "season" {
            return (fullMetadata?.seriesTitleForDisplay ?? currentItem.seriesTitleForDisplay)
                ?? (fullMetadata?.title ?? currentItem.title ?? "Unknown Title")
        }
        return fullMetadata?.title ?? currentItem.title ?? "Unknown Title"
    }

    private var seasonHeroContextLabel: String? {
        guard currentItem.type == "season" else { return nil }
        return fullMetadata?.seasonDisplayTitle ?? currentItem.seasonDisplayTitle
    }

    private var relatedShowRatingKey: String? {
        switch currentItem.type {
        case "episode":
            return fullMetadata?.grandparentRatingKey ?? currentItem.grandparentRatingKey
        case "season":
            return fullMetadata?.parentRatingKey ?? currentItem.parentRatingKey
        default:
            return nil
        }
    }

    /// Effective item data - uses fullMetadata for progress/viewOffset when available
    /// This ensures we have the most up-to-date playback position after returning from the player
    private var effectiveItem: PlexMetadata {
        if let full = fullMetadata {
            // Merge updated viewOffset/viewCount into currentItem
            var merged = currentItem
            merged.viewOffset = full.viewOffset
            merged.viewCount = full.viewCount
            return merged
        }
        return currentItem
    }

    /// Play button label for TV shows and seasons
    /// Shows "Continue S02E05" for in-progress episodes, "Play" otherwise
    private var showPlayButtonLabel: String {
        guard let episode = nextUpEpisode else { return "Play" }

        // Check if the episode is in progress
        if episode.isInProgress, let epString = episode.episodeString {
            return "Continue \(epString)"
        }

        return "Play"
    }

    /// Caption shown below the Play button when there's a next episode to play
    /// Returns nil for in-progress episodes (button already shows episode info)
    private var upNextCaption: String? {
        guard let episode = nextUpEpisode else { return nil }

        // Don't show caption if episode is in progress (button already says "Continue S02E05")
        if episode.isInProgress { return nil }

        // Build "Up Next: S02E05 - Title" caption
        let epString = episode.episodeString ?? ""
        let title = episode.title ?? ""

        if !epString.isEmpty && !title.isEmpty {
            // Truncate long titles
            let maxTitleLength = 25
            let truncatedTitle = title.count <= maxTitleLength
                ? title
                : String(title.prefix(maxTitleLength - 1)) + "…"
            return "Up Next: \(epString) - \(truncatedTitle)"
        } else if !epString.isEmpty {
            return "Up Next: \(epString)"
        } else if !title.isEmpty {
            return "Up Next: \(title)"
        }

        return nil
    }

    var body: some View {
        GeometryReader { geo in
            let heroHeight = heroContentHeight(for: geo.size.height)
            let stageSize = backdropStageSize ?? geo.size
            // For preview/expanded-preview flows, keep the backdrop at a fixed
            // screen position so it doesn't drift when the card mask expands.
            // The image is already full-screen-sized; the mask just reveals more.
            // Parallax during paging comes from backgroundParallaxOffset alone.
            let centeredStageBaseOffset: CGPoint = {
                if isPreviewCarousel || isExpandedPreviewFlow {
                    return .zero
                }
                return CGPoint(
                    x: -((stageSize.width - geo.size.width) / 2),
                    y: -((stageSize.height - geo.size.height) / 2)
                )
            }()
            let stageWindowOrigin: CGPoint = {
                if isPreviewCarousel || isExpandedPreviewFlow {
                    return .zero
                }
                return backdropWindowFrame?.origin ?? .zero
            }()
            ZStack {
                if showsBackdropLayer {
                    // Layer 1: Fixed backdrop (doesn't scroll, fills screen)
                    // Ken Burns: subtle slow pan adds life to the static detail view
                    heroBackdropImage
                        .frame(width: stageSize.width, height: stageSize.height)
                        .offset(
                            x: centeredStageBaseOffset.x - stageWindowOrigin.x + backgroundParallaxOffset + kenBurnsOffset,
                            y: centeredStageBaseOffset.y - stageWindowOrigin.y
                        )
                        .scaleEffect(heroBackdropScale)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay {
                            // `.regularMaterial` is backed by `UIVisualEffectView`
                            // on tvOS, which runs a blur render pass every frame
                            // it's composited — even at opacity 0. In carousel
                            // mode vertical scroll is disabled, so `scrollProgress`
                            // is pinned at 0 and the material contributes nothing
                            // visually. Gating on `scrollProgress > 0.01` removes
                            // the blur view from the tree entirely during the
                            // entry/paging animation.
                            if scrollProgress > 0.01 {
                                Rectangle()
                                    .fill(.regularMaterial)
                                    .opacity(scrollProgress)
                            }
                        }
                }

                // Left-side gradient for text readability (Apple TV+ style)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.7), location: 0),
                        .init(color: .black.opacity(0.4), location: 0.25),
                        .init(color: .black.opacity(0.12), location: 0.42),
                        .init(color: .clear, location: 0.55),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(effectiveVignetteVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.6), value: effectiveVignetteVisible)
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Bottom gradient for metadata text readability
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.25), location: 0.2),
                        .init(color: .black.opacity(0.55), location: 0.4),
                        .init(color: .black.opacity(0.8), location: 0.65),
                        .init(color: .black.opacity(0.95), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: geo.size.height * 0.55)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(effectiveVignetteVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.6), value: effectiveVignetteVisible)
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Layer 2: All scrollable content in one continuous flow
                ScrollViewReader { verticalProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Metadata pinned near bottom of visible area.
                        // Scroll fade is applied inside heroMetadataOverlay to
                        // the text only — action buttons stay fully opaque so
                        // they remain in the tvOS focus hierarchy when scrolled off.
                        heroMetadataOverlay
                            .opacity(effectiveMetadataVisible ? 1 : 0)
                            .animation(.easeOut(duration: 0.35), value: effectiveMetadataVisible)
                            .frame(height: heroHeight)
                            .id("scrollTop")

                        // Below-fold page: ZStack decouples min height from content layout.
                        // Color.clear sets the height floor; the VStack sits on top
                        // at its natural size so no extra space leaks into children.
                        ZStack(alignment: .topLeading) {
                            // Invisible rect guarantees at least one screen of scroll room
                            Color.clear.frame(height: geo.size.height)

                            VStack(alignment: .leading, spacing: 0) {
                                VStack(alignment: .leading, spacing: 32) {
                                    // TV Show specific: Seasons and Episodes
                                    if currentItem.type == "show" || currentItem.type == "episode" {
                                        seasonSection
                                    }

                                    // Season specific: Episodes list (no season picker needed)
                                    if currentItem.type == "season" {
                                        episodeSection
                                    }

                                    // Album specific: Tracks
                                    if currentItem.type == "album" {
                                        trackSection
                                    }

                                    // Artist specific: Albums
                                    if currentItem.type == "artist" {
                                        albumSection
                                    }
                                }
                                .padding(.top, belowFoldHeaderReserveHeight)
                                .padding(.horizontal, 48)
                                .allowsHitTesting(!isPreviewCarousel)

                                // Recommended / Related Section
                                if !recommendedItems.isEmpty {
                                    MediaItemRow(
                                        title: "Related",
                                        items: recommendedItems,
                                        serverURL: authManager.selectedServerURL ?? "",
                                        authToken: authManager.selectedServerToken ?? "",
                                        onItemSelected: { selectedItem in
                                            withAnimation(.easeInOut(duration: 0.35)) {
                                                displayedItem = selectedItem
                                            }
                                        }
                                    )
                                    .padding(.top, 32)
                                }

                                // Collection Section (for movies that are part of a collection)
                                if !collectionItems.isEmpty, let name = collectionName {
                                    MediaItemRow(
                                        title: name,
                                        items: collectionItems,
                                        serverURL: authManager.selectedServerURL ?? "",
                                        authToken: authManager.selectedServerToken ?? "",
                                        onItemSelected: { selectedItem in
                                            withAnimation(.easeInOut(duration: 0.35)) {
                                                displayedItem = selectedItem
                                            }
                                        }
                                    )
                                    .padding(.top, 32)
                                }

                                // Cast & Crew Section
                                if let metadata = fullMetadata,
                                   (!metadata.cast.isEmpty || !(metadata.Director?.isEmpty ?? true)) {
                                    CastCrewRow(
                                        cast: metadata.cast,
                                        directors: metadata.Director ?? [],
                                        serverURL: authManager.selectedServerURL ?? "",
                                        authToken: authManager.selectedServerToken ?? ""
                                    )
                                    .padding(.top, 32)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            belowFoldTitleLogo
                                .frame(height: 110)
                                .padding(.top, 40)
                                .padding(.bottom, 8)
                                .opacity(belowFoldTitleOpacity)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        .opacity(belowFoldLoaded ? 1 : 0)
                        .animation(.easeOut(duration: 0.35), value: belowFoldLoaded)
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    // Drive scroll progress continuously from offset so the
                    // reserve-height padding grows in lockstep with scrolling.
                    // Episodes stay visually fixed; the logo/material fade in
                    // proportionally without any compound animation overshoot.
                    let reserveDistance: CGFloat = 158
                    scrollProgress = min(1, max(0, offset / reserveDistance))
                    belowFoldTitleOpacity = min(1, max(0, (offset - 30) / 90))
                    if offset > 10 {
                        onDetailsBecameVisible?()
                    }
                }
                .id(scrollResetID)
                .scrollDisabled(isPreviewCarousel || !allowVerticalScroll)
                .defaultScrollAnchor(.top)
                .onChange(of: scrollToTopTrigger) { _, _ in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        verticalProxy.scrollTo("scrollTop", anchor: .top)
                    }
                }
                } // ScrollViewReader
            }
        }
        .ignoresSafeArea()
        .task(id: detailLoadTaskID) {
            // Fetch full metadata immediately — not gated by
            // `previewAnimationSettled`. This is a single network call
            // with no layout churn, and it needs to land before the
            // text fade at ~750ms so genres/cast/summary are ready
            // when the hero metadata fades in.
            guard shouldLoadDetailData else {
                syncHeroBackdrop()
                return
            }
            fullMetadata = nil
            parentShowLogoPath = nil
            syncHeroBackdrop()
            await loadFullMetadata()
            await refreshHeroBackdropAssets()

            // In non-carousel flows (direct navigation), the cascade gate
            // is already open so onChange(of: canRunDetailCascade) won't
            // fire (no change). Run the heavy cascade directly.
            if canRunDetailCascade {
                await loadDetailData()
            }
        }
        .onChange(of: shouldLoadDetailData) { _, isActive in
            // A previously-passive side card just became current. Load its
            // fullMetadata so the hero overlay has genres/cast/summary ready.
            guard isActive, fullMetadata == nil else { return }
            Task { @MainActor in
                await loadFullMetadata()
                await refreshHeroBackdropAssets()
            }
        }
        .onChange(of: canRunDetailCascade) { _, canRun in
            // When a previously-passive card becomes current, or when the
            // entry animation finishes, re-invoke the cascade. The task
            // ID itself no longer changes on active/passive flips, so this
            // is the only path that promotes a side card's passive stub
            // into a full load.
            guard canRun else { return }
            Task { @MainActor in
                await loadDetailData()
            }
        }
        .task(id: "kenburns-\(currentItem.ratingKey ?? "")") {
            guard !isPreviewCarousel, !isExpandedPreviewFlow else {
                kenBurnsOffset = 0
                return
            }
            // Ken Burns: wait for view to settle, then start slow backdrop drift
            kenBurnsOffset = 0
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 15).repeatForever(autoreverses: true)) {
                kenBurnsOffset = 50
            }
        }
        .onChange(of: presentationMode) { _, newMode in
            if newMode == .previewCarousel {
                displayedItem = nil
                focusedActionButton = nil
                // scrollProgress is scroll-driven; scrollTo resets the offset
                // which drives scrollProgress back to 0 via onScrollGeometryChange.
                scrollToTopTrigger.toggle()
            }
        }
        .onChange(of: heroBackdropMotionLocked) { _, locked in
            heroBackdrop.setMotionLocked(locked)
        }
        .onChange(of: heroBackdrop.session.logoURL) { _, newLogoURL in
            if let newLogoURL {
                retainedLogoURL = newLogoURL
            }
        }
        .onChange(of: currentItem.ratingKey) { _, _ in
            retainedLogoURL = nil
            hasDisplayedHeroLogoImage = false
            parentShowLogoPath = nil
        }
        .onChange(of: showExpandedChrome) { _, isVisible in
            guard isVisible, isExpandedPreviewFlow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                focusedActionButton = "play"
            }
        }
        .onChange(of: focusedEpisodeId) { _, newId in
            // Sync season pill when user navigates across season boundary
            guard let newId,
                  let episode = unifiedEpisodes.first(where: { $0.ratingKey == newId }),
                  episode.parentRatingKey != selectedSeason?.ratingKey,
                  let newSeason = seasons.first(where: { $0.ratingKey == episode.parentRatingKey }) else { return }
            selectedSeason = newSeason
        }
        .onAppear {
            guard isExpandedPreviewFlow, let bridge = menuBridge else { return }
            bridge.interceptHandler = { [self] in
                if navigateToAlbum != nil {
                    navigateToAlbum = nil
                    return true
                } else if navigateToSeason != nil {
                    navigateToSeason = nil
                    return true
                } else if navigateToShow != nil {
                    navigateToShow = nil
                    return true
                } else if navigateToEpisode != nil {
                    navigateToEpisode = nil
                    return true
                } else if scrollProgress > 0 || focusedEpisodeId != nil {
                    scrollToTopTrigger.toggle()
                    focusedEpisodeId = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        focusedActionButton = "play"
                    }
                    return true
                }
                return false
            }
        }
        .onDisappear {
            guard isExpandedPreviewFlow else { return }
            menuBridge?.interceptHandler = nil
        }
        .onChange(of: showPlayer) { _, shouldShow in
            if shouldShow {
                presentPlayer()
            }
        }
        .fullScreenCover(isPresented: $showTrailerPlayer) {
            // Play trailer using the same player as regular content
            if let metadata = trailerMetadata {
                UniversalPlayerView(metadata: metadata)
            }
        }
        .onChange(of: showTrailerPlayer) { _, isShowing in
            // Clear trailer metadata when player is dismissed
            if !isShowing {
                trailerMetadata = nil
            }
        }
        .sheet(isPresented: $showBioSheet) {
            ArtistBioSheet(
                artistName: fullMetadata?.title ?? currentItem.title ?? "Artist",
                bio: fullMetadata?.summary ?? currentItem.summary ?? "",
                thumbURL: artistThumbURL
            )
        }
        .sheet(isPresented: $showAudioTrackPicker) {
            TrackSelectionSheet(
                trackType: .audio,
                tracks: preplayAudioTracks,
                selectedTrackId: preplayAudioTrackId ?? currentSelectedAudioStreamId,
                onSelect: { id in
                    preplayAudioTrackId = id
                    if let id { persistAudioStreamSelection(id) }
                }
            )
        }
        .sheet(isPresented: $showSubtitleTrackPicker) {
            TrackSelectionSheet(
                trackType: .subtitles,
                tracks: preplaySubtitleTracks,
                selectedTrackId: effectiveSubtitlePickerSelection,
                onSelect: { id in
                    preplaySubtitleSelection = id.map { .track(id: $0) } ?? .off
                    persistSubtitleStreamSelection(id)
                }
            )
        }
        .onChange(of: currentItem.ratingKey) { _, _ in
            // Reset pre-play picker state when navigating to a different
            // item within this detail view (e.g., via collection / recs).
            preplayAudioTrackId = nil
            preplaySubtitleSelection = .auto
            // Cancel any in-flight write for the previous item so
            // presentPlayer() doesn't await a task that refreshes
            // metadata for the now-defunct item.
            pendingPreplayWrite?.cancel()
            pendingPreplayWrite = nil
        }
        .onChange(of: showPlayer) { _, isShowing in
            // Clear selected episode/track and playFromBeginning when player closes
            if !isShowing {
                // Capture episode ratingKey before clearing for refresh
                let playedEpisodeKey = selectedEpisode?.ratingKey
                let lastPlayed = lastPlayedMetadata

                selectedEpisode = nil
                selectedTrack = nil
                playFromBeginning = false
                lastPlayedMetadata = nil

                // If we're on an episode detail page and auto-play advanced to a different episode,
                // swap the displayed item so the detail page shows the last-played episode
                if currentItem.type == "episode",
                   let lastPlayed,
                   lastPlayed.ratingKey != currentItem.ratingKey {
                    displayedItem = lastPlayed
                    // .task(id: currentItem.ratingKey) will fire and do a full reload
                    return
                }

                // Refresh metadata to get updated viewOffset after playback
                Task {
                    await loadFullMetadata()

                    // Update displayed progress and watched state from refreshed metadata
                    if let full = fullMetadata {
                        withAnimation(.easeOut(duration: 0.3)) {
                            displayedProgress = full.watchProgress ?? 0
                            isWatched = full.isWatched
                        }
                    }

                    // Also refresh the specific episode if one was played
                    if let episodeKey = playedEpisodeKey {
                        await refreshEpisodeWatchStatus(ratingKey: episodeKey)
                    }

                    // For show/season detail pages, also refresh episode list and next-up
                    if currentItem.type == "show" {
                        await loadAllEpisodes()
                        await loadNextUpEpisode()
                    } else if currentItem.type == "season" {
                        await loadEpisodesForSeason()
                        await loadNextUpEpisode()
                    }
                }
            }
        }
        // Navigation destinations only in standard flow (not preview overlay — no NavigationStack there)
        .modifier(NavigationDestinationsModifier(
            navigateToAlbum: $navigateToAlbum,
            navigateToSeason: $navigateToSeason,
            navigateToShow: $navigateToShow,
            navigateToEpisode: $navigateToEpisode,
            isEnabled: onPreviewExitRequested == nil
        ))
        // Restore focus when returning from a nested album view
        .onChange(of: navigateToAlbum) { oldAlbum, newAlbum in
            if oldAlbum != nil && newAlbum == nil, let savedFocus = savedAlbumFocus {
                // Delay slightly to let the view update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedAlbumId = savedFocus
                }
            }
        }
        // Restore track focus when returning from player
        .onChange(of: showPlayer) { wasPlaying, isPlaying in
            if wasPlaying && !isPlaying, let savedFocus = savedTrackFocus {
                // Delay slightly to let the view update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedTrackId = savedFocus
                }
            }
        }
    }

    private func heroContentHeight(for fullHeight: CGFloat) -> CGFloat {
        let shelfPeek: CGFloat
        switch currentItem.type {
        case "show", "season", "episode":
            // TV detail surfaces should all expose the shelf at the same shallow depth.
            shelfPeek = 160
        default:
            shelfPeek = 220
        }

        return max(0, fullHeight - shelfPeek)
    }

    private var belowFoldHeaderReserveHeight: CGFloat {
        158 * scrollProgress
    }

    // MARK: - Hero Components (Apple TV+ style — backdrop fixed, content scrolls over)

    /// Fixed backdrop image (behind everything, doesn't scroll)
    private var heroBackdropImage: some View {
        HeroBackdropImage(
            url: heroBackdrop.session.displayedBackdropURL,
            animationDuration: isPreviewCarousel ? 0.38 : 0.26
        ) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    /// Gradient overlay for hero text readability (scrolls with content)
    private var heroGradient: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.5), location: 0.55),
                .init(color: .black.opacity(0.85), location: 0.75),
                .init(color: .black, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Metadata overlay (title, genres, quality, buttons, cast) positioned at bottom of hero
    private var heroMetadataOverlay: some View {
        GeometryReader { metaGeo in
            VStack(alignment: .leading, spacing: 10) {
                Spacer()

                // Text content — fixed height so buttons/peek distance
                // stays constant regardless of description length, logo vs title, etc.
                VStack(alignment: .leading, spacing: 14) {
                    // Plex clearLogo or title — fixed height so content below is always
                    // at the same position regardless of logo aspect ratio
                    Group {
                        if let logoURL = effectiveHeroLogoURL {
                            CachedAsyncImage(url: logoURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        // Shadow is redundant in carousel mode — the bottom
                                        // vignette at lines ~305-321 already hits 95% black
                                        // opacity where the logo sits, so the drop shadow is
                                        // invisible. Removing it during carousel avoids the
                                        // per-frame offscreen compositing pass the shadow forces
                                        // while `heroMetadataOverlay` opacity is animating.
                                        .shadow(
                                            color: .black.opacity(isPreviewCarousel ? 0 : 0.8),
                                            radius: isPreviewCarousel ? 0 : 20,
                                            x: 0,
                                            y: isPreviewCarousel ? 0 : 4
                                        )
                                        .onAppear {
                                            if !hasDisplayedHeroLogoImage {
                                                hasDisplayedHeroLogoImage = true
                                            }
                                        }
                                case .empty:
                                    if hasDisplayedHeroLogoImage {
                                        Color.clear
                                    } else {
                                        heroTitleText
                                    }
                                default:
                                    heroTitleText
                                }
                            }
                        } else {
                            heroTitleText
                        }
                    }
                    .frame(maxWidth: heroLogoMaxWidth, alignment: .leading)
                    .frame(height: heroLogoSlotHeight, alignment: .bottomLeading)

                    // Genre + content rating row
                    heroMetadataRow

                    // Description area (narrower than full metadata block, per Apple TV+ reference)
                    VStack(alignment: .leading, spacing: 4) {
                        if currentItem.type == "episode" {
                            if let epString = currentItem.episodeString {
                                let title = currentItem.title ?? ""
                                let header = epString + (title.isEmpty ? "" : " · \(title)")
                                let desc = fullMetadata?.summary ?? currentItem.summary ?? ""
                                (Text(header).bold() + Text(desc.isEmpty ? "" : ":  \(desc)"))
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .lineLimit(3)
                            }
                        } else if currentItem.type == "show" || currentItem.type == "season" {
                            if let tagline = fullMetadata?.tagline ?? currentItem.tagline {
                                Text(tagline)
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            if let summary = fullMetadata?.summary ?? currentItem.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(3)
                            }
                        } else {
                            if let tagline = fullMetadata?.tagline ?? currentItem.tagline {
                                Text(tagline)
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.9))
                            } else if let summary = fullMetadata?.summary ?? currentItem.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(3)
                            }
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)

                    // Year · Duration · Quality badges
                    heroQualityRow

                    // Up Next caption
                    if let caption = upNextCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 420, alignment: .bottomLeading)
                .frame(maxWidth: 760, alignment: .leading)
                .opacity(1 - scrollProgress)

                // Bottom row: buttons (left) + starring (right) — full width
                // Buttons stay fully opaque (not faded by scroll) so tvOS keeps
                // them in the focus hierarchy for Up navigation from below-fold.
                HStack(alignment: .bottom, spacing: 0) {
                    actionButtons
                        .onMoveCommand { direction in
                            if direction == .up,
                               isExpandedPreviewFlow,
                               scrollProgress == 0 {
                                onPreviewExitRequested?()
                            }
                        }

                    Spacer(minLength: 40)

                    // Starring (comma-separated, right-aligned)
                    if let roles = (fullMetadata ?? currentItem).Role, !roles.isEmpty {
                        let topCast = roles.prefix(3).compactMap { $0.tag }
                        if !topCast.isEmpty {
                            Text("Starring \(topCast.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(3)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 460, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, heroActionRowTopPadding)
                .focusSection()
                .opacity(effectiveMetadataVisible ? 1 : 0)
                .allowsHitTesting(allowActionRowInteraction)
            }
            .padding(.horizontal, heroOverlayHorizontalInset)
            .animation(isPreviewCarousel ? nil : .easeInOut(duration: 0.3), value: currentItem.ratingKey)
        }
    }

    // MARK: - Below-fold Title Logo (centered, Apple TV+ style)

    private var belowFoldTitleLogo: some View {
        Group {
            if let logoURL = effectiveHeroLogoURL {
                CachedAsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .onAppear {
                                if !hasDisplayedHeroLogoImage {
                                    hasDisplayedHeroLogoImage = true
                                }
                            }
                    case .empty:
                        if hasDisplayedHeroLogoImage {
                            Color.clear
                        } else {
                            Text(heroBrandTitle)
                                .font(.system(size: 42, weight: .bold))
                                .foregroundStyle(.primary)
                        }
                    default:
                        Text(heroBrandTitle)
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: 680, maxHeight: 126)
            } else {
                Text(heroBrandTitle)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Hero Sub-components

    private var heroTitleText: some View {
        Text(heroBrandTitle)
            .font(.system(size: 52, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
    }

    /// Genre tags + content rating badge (Apple TV+ style: "TV Show · Adventure · Sci-Fi [TV-14]")
    private var heroMetadataRow: some View {
        HStack(spacing: 8) {
            // Build label parts with dot separators
            let parts = heroMetadataParts
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·")
                }
                Text(part)
            }

            // Content rating badge (bordered, at end)
            if let contentRating = fullMetadata?.contentRating ?? currentItem.contentRating {
                Text(contentRating)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    }
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }

    private var heroMetadataParts: [String] {
        var parts: [String] = []

        // Type label: prefer library section title, fall back to content type
        if let library = (fullMetadata ?? currentItem).librarySectionTitle {
            parts.append(library)
        } else if currentItem.type == "show" || currentItem.type == "episode" || currentItem.type == "season" {
            parts.append("TV Show")
        } else if currentItem.type == "movie" {
            parts.append("Movie")
        }

        // Genres (up to 2 — keeps the row concise alongside the type label and rating badge)
        let genreSource = fullMetadata ?? currentItem
        if let genres = genreSource.Genre?.prefix(2) {
            for genre in genres {
                if let tag = genre.tag {
                    parts.append(tag)
                }
            }
        }

        return parts
    }

    /// Year, duration, quality badges row (Apple TV+ style: "2023 · 49 min [4K] [DV] [5.1]")
    private var heroQualityRow: some View {
        HStack(spacing: 8) {
            // Year · Duration with dot separator
            let year = fullMetadata?.year ?? currentItem.year
            let duration = fullMetadata?.durationFormatted ?? currentItem.durationFormatted

            if let year {
                Text(String(year))
            }
            if year != nil && duration != nil {
                Text("·")
            }
            if let duration {
                Text(duration)
            }

            if let rating = fullMetadata?.rating ?? currentItem.rating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", rating))
                }
            }

            // Quality badges
            if let videoQuality = fullMetadata?.videoQualityDisplay ?? currentItem.videoQualityDisplay {
                QualityBadge(text: videoQuality)
            }
            if let hdrFormat = fullMetadata?.hdrFormatDisplay ?? currentItem.hdrFormatDisplay {
                QualityBadge(text: hdrFormat)
            }
            if let audioFormat = fullMetadata?.audioFormatDisplay ?? currentItem.audioFormatDisplay {
                QualityBadge(text: audioFormat)
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
    }

    /// Small badge for quality indicators (4K, DV, Atmos, etc.)
    private struct QualityBadge: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.15))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.white.opacity(0.3), lineWidth: 0.5)
                }
        }
    }

    /// Check if this is a music item (album, artist, track)
    private var isMusicItem: Bool {
        currentItem.type == "album" || currentItem.type == "artist" || currentItem.type == "track"
    }

    /// Icon for fallback poster based on item type
    private var iconForType: String {
        switch currentItem.type {
        case "movie": return "film"
        case "show": return "tv"
        case "album": return "music.note.list"
        case "artist": return "music.mic"
        case "track": return "music.note"
        default: return "photo"
        }
    }

    /// Artist thumbnail URL for bio sheet
    private var artistThumbURL: URL? {
        guard let thumb = fullMetadata?.thumb ?? currentItem.thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    /// Load and play all tracks for an artist
    private func playAllArtistTracks() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingArtistTracks = true
        defer { isLoadingArtistTracks = false }

        do {
            // Use getAllLeaves to get all tracks for this artist
            let allTracks = try await networkManager.getAllLeaves(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )

            if !allTracks.isEmpty {
                artistTracks = allTracks
                MusicQueue.shared.playAlbum(tracks: allTracks, startingAt: 0)
            }
        } catch {
            print("Failed to load artist tracks: \(error)")
        }
    }

    /// Shuffle play all episodes for a show or season
    private func shufflePlay() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingShufflePlay = true
        defer { isLoadingShufflePlay = false }

        do {
            // For seasons, use getChildren (allLeaves returns empty for seasons)
            // For shows, use getAllLeaves to get episodes across all seasons
            let allEpisodes: [PlexMetadata]
            if currentItem.type == "season" {
                allEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
            } else {
                allEpisodes = try await networkManager.getAllLeaves(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
            }

            guard !allEpisodes.isEmpty else { return }

            var shuffled = allEpisodes
            shuffled.shuffle()

            selectedEpisode = shuffled[0]
            shuffledEpisodeQueue = shuffled
            playFromBeginning = true
            showPlayer = true
        } catch {
            print("Failed to load episodes for shuffle play: \(error)")
        }
    }

    // MARK: - Summary Section (Full, below fold)

    @ViewBuilder
    private func fullSummarySection(summary: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isSummaryExpanded.toggle()
            }
        } label: {
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(isSummaryExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action Buttons (Apple TV+ style)

    private let pillButtonHeight: CGFloat = 66
    private let circleButtonSize: CGFloat = 66

    private var actionButtons: some View {
        HStack(spacing: 18) {
            // Primary play button with inline progress + time remaining
            if currentItem.type == "artist" {
                Button {
                    Task { await playAllArtistTracks() }
                } label: {
                    HStack(spacing: 10) {
                        if isLoadingArtistTracks {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Play All")
                    }
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 32)
                    .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
                .disabled(isLoadingArtistTracks)
            } else if currentItem.type == "album" {
                Button {
                    if !tracks.isEmpty {
                        MusicQueue.shared.playAlbum(tracks: tracks, startingAt: 0)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        Text("Play Album")
                    }
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 32)
                    .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
                .disabled(tracks.isEmpty)
            } else if currentItem.type == "show" || currentItem.type == "season" {
                Button {
                    if let episode = nextUpEpisode { selectedEpisode = episode }
                    playFromBeginning = false
                    showPlayer = true
                } label: {
                    playButtonLabel(text: showPlayButtonLabel, isFocused: focusedActionButton == "play")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.horizontal, 32)
                        .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
                .disabled(nextUpEpisode == nil)

                // Shuffle
                Button {
                    Task { await shufflePlay() }
                } label: {
                    HStack(spacing: 10) {
                        if isLoadingShufflePlay {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "shuffle")
                        }
                        Text("Shuffle")
                    }
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 32)
                    .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "shuffle", cornerRadius: pillButtonHeight / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "shuffle")
                .disabled(isLoadingShufflePlay)
            } else if currentItem.type != "track" {
                // Movies/Episodes: Play button with progress bar + time remaining
                Button {
                    playFromBeginning = false
                    showPlayer = true
                } label: {
                    playButtonLabel(text: effectiveItem.isInProgress ? "Resume" : "Play", isFocused: focusedActionButton == "play")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.horizontal, 32)
                        .frame(height: pillButtonHeight)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
                .focused($focusedActionButton, equals: "play")
            }

            // Watched toggle — perfect circle checkmark button
            if !isMusicItem {
                Button {
                    Task { await toggleWatched() }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "watched", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "watched")
            }

            // Music: Star rating — perfect circle
            if isMusicItem {
                Button {
                    Task { await toggleStarRating() }
                } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "star", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "star")
            }

            // Info button for artists — perfect circle
            if currentItem.type == "artist", let summary = fullMetadata?.summary ?? currentItem.summary, !summary.isEmpty {
                Button {
                    showBioSheet = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "info", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "info")
            }

            // Trailer button — perfect circle
            if !isMusicItem, fullMetadata?.trailer != nil {
                Button {
                    Task { await loadAndPlayTrailer() }
                } label: {
                    Image(systemName: "film")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "trailer", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "trailer")
            }

            // Pre-play audio track picker — only for movies and episodes
            // (single-video items where we know the streams ahead of play).
            if showsPreplayTrackPickers, !preplayAudioTracks.isEmpty {
                Button {
                    showAudioTrackPicker = true
                } label: {
                    Image(systemName: "speaker.wave.3")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "audioTrack", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "audioTrack")
            }

            // Pre-play subtitle track picker — hidden when there are no subtitle streams.
            if showsPreplayTrackPickers, !preplaySubtitleTracks.isEmpty {
                Button {
                    showSubtitleTrackPicker = true
                } label: {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: circleButtonSize, height: circleButtonSize)
                }
                .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "subtitleTrack", cornerRadius: circleButtonSize / 2, isPrimary: false))
                .focused($focusedActionButton, equals: "subtitleTrack")
            }
        }
        .disabled(!allowActionRowInteraction)
    }

    // MARK: - Pre-play Track Picker Helpers

    /// Whether the pre-play picker buttons make sense for the current
    /// item type. Show / season / artist / album / track detail pages
    /// don't have a single, known track list at this level.
    private var showsPreplayTrackPickers: Bool {
        switch currentItem.type {
        case "movie", "episode": return true
        default: return false
        }
    }

    /// Streams come from `fullMetadata` once it's loaded; before that,
    /// the pickers stay hidden because their counts are zero.
    private var preplayStreams: [PlexStream] {
        (fullMetadata ?? currentItem).Media?.first?.Part?.first?.Stream ?? []
    }

    private var preplayAudioTracks: [MediaTrack] {
        preplayStreams.filter { $0.isAudio }.map { MediaTrack(from: $0) }
    }

    private var preplaySubtitleTracks: [MediaTrack] {
        preplayStreams.filter { $0.isSubtitle }.map { MediaTrack(from: $0) }
    }

    /// Audio stream Plex has marked `selected` for the current user.
    /// Reflects whatever the user previously chose (in any client) or
    /// Plex's server-side default; what the player would pick today.
    private var currentSelectedAudioStreamId: Int? {
        preplayStreams.first(where: { $0.isAudio && $0.selected == true })?.id
    }

    /// Subtitle stream Plex has marked `selected` for the current user.
    /// `nil` means subtitles are off server-side.
    private var currentSelectedSubtitleStreamId: Int? {
        preplayStreams.first(where: { $0.isSubtitle && $0.selected == true })?.id
    }

    /// What to highlight in the subtitle picker on open. Honors the
    /// user's local preplay choice first, then falls back to the
    /// server-side selection so reopening the picker mid-visit shows
    /// the current state rather than always defaulting to "Off".
    private var effectiveSubtitlePickerSelection: Int? {
        switch preplaySubtitleSelection {
        case .track(let id): return id
        case .off: return nil
        case .auto: return currentSelectedSubtitleStreamId
        }
    }

    /// PUT the chosen audio stream to Plex so it persists per-user-per-item
    /// across plays from any client. Refresh `fullMetadata` afterward so
    /// the local view of `selected: true` matches the new server state.
    /// Chained off any prior in-flight write so concurrent audio + subtitle
    /// picks serialise rather than racing each other (or the Play tap).
    private func persistAudioStreamSelection(_ streamId: Int) {
        guard let serverURL = authManager.selectedServerURL,
              let authToken = authManager.selectedServerToken,
              let partId = (fullMetadata ?? currentItem).Media?.first?.Part?.first?.id else {
            return
        }
        let previous = pendingPreplayWrite
        pendingPreplayWrite = Task {
            if let previous { _ = await previous.value }
            await networkManager.setSelectedAudioStream(
                serverURL: serverURL,
                authToken: authToken,
                partId: partId,
                audioStreamID: streamId
            )
            await loadFullMetadata()
        }
    }

    /// PUT the chosen subtitle stream to Plex (id `0` disables subs).
    /// Refresh `fullMetadata` afterward. Same chained-Task pattern as audio.
    private func persistSubtitleStreamSelection(_ streamId: Int?) {
        guard let serverURL = authManager.selectedServerURL,
              let authToken = authManager.selectedServerToken,
              let partId = (fullMetadata ?? currentItem).Media?.first?.Part?.first?.id else {
            return
        }
        let previous = pendingPreplayWrite
        pendingPreplayWrite = Task {
            if let previous { _ = await previous.value }
            await networkManager.setSelectedSubtitleStream(
                serverURL: serverURL,
                authToken: authToken,
                partId: partId,
                subtitleStreamID: streamId ?? 0
            )
            await loadFullMetadata()
        }
    }

    /// Play button label with inline progress bar + time remaining (Apple TV+ style)
    private func playButtonLabel(text: String, isFocused: Bool = false) -> some View {
        let trackColor = isFocused ? Color.black.opacity(0.2) : Color.white.opacity(0.3)
        let fillColor = isFocused ? Color.black : Color.white

        return HStack(spacing: 10) {
            Image(systemName: "play.fill")

            // Progress bar (always shown — full track for unwatched, partial for in-progress)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(trackColor)
                    .frame(width: 80, height: 5)
                if displayedProgress > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fillColor)
                        .frame(width: 80 * displayedProgress, height: 5)
                }
            }

            // Time: remaining if in progress, total duration otherwise
            if effectiveItem.isInProgress, let remaining = effectiveItem.remainingTimeFormatted {
                Text(remaining)
            } else if let duration = effectiveItem.durationFormatted {
                Text(duration)
            } else {
                Text(text)
            }
        }
    }

    // MARK: - Season Section (TV Shows)

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingSeasons {
                ProgressView("Loading seasons...")
            } else if !seasons.isEmpty {
                SeasonPillBar(
                    seasons: seasons,
                    selectedSeason: $selectedSeason,
                    onSeasonSelected: { season in
                        // Scroll episode list to this season's first episode
                        if let firstEp = unifiedEpisodes.first(where: { $0.parentRatingKey == season.ratingKey }),
                           let epKey = firstEp.ratingKey {
                            episodeScrollTarget = epKey
                        }
                    }
                )
                .opacity(scrollProgress)
                .onMoveCommand { direction in
                    if direction == .up {
                        scrollToTopTrigger.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            focusedActionButton = "play"
                        }
                    }
                }

                // Unified horizontal episode cards across all seasons
                unifiedEpisodeList
            }
        }
    }

    private var shouldUseSingleSeasonPillHeaderInSeasonDetail: Bool {
        currentItem.type == "season" && seasons.count <= 1
    }

    private var seasonDetailHeaderPills: [PlexMetadata] {
        let matchingSeason = seasons.filter { $0.ratingKey == currentItem.ratingKey }
        if !matchingSeason.isEmpty {
            return matchingSeason
        }
        return [selectedSeason ?? currentItem]
    }

    /// Unified horizontal episode card row across all seasons
    private var unifiedEpisodeList: some View {
        Group {
            if unifiedEpisodes.isEmpty && isLoadingEpisodes {
                ProgressView("Loading episodes...")
                    .padding(.top, 20)
            } else if !unifiedEpisodes.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) {
                            ForEach(Array(unifiedEpisodes.enumerated()), id: \.element.ratingKey) { index, episode in
                                let isSeasonBoundary = index > 0 && episode.parentRatingKey != unifiedEpisodes[index - 1].parentRatingKey
                                let leadingPad: CGFloat = index == 0 ? 48 : (isSeasonBoundary ? 56 : 24)

                                EpisodeCard(
                                    episode: episode,
                                    serverURL: authManager.selectedServerURL ?? "",
                                    authToken: authManager.selectedServerToken ?? "",
                                    focusedEpisodeId: $focusedEpisodeId,
                                    showSeasonPrefix: seasons.count > 1,
                                    onPlay: {
                                        selectedEpisode = episode
                                        playFromBeginning = false
                                        showPlayer = true
                                    },
                                    onRefreshNeeded: {
                                        await refreshEpisodeWatchStatus(ratingKey: episode.ratingKey)
                                    },
                                    onShowInfo: {
                                        navigateToEpisode = episode
                                    }
                                )
                                .padding(.leading, leadingPad)
                                .padding(.trailing, index == unifiedEpisodes.count - 1 ? 48 : 0)
                                .id(episode.ratingKey)
                            }
                        }
                        .padding(.vertical, 16)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                    .onMoveCommand { direction in
                        guard direction == .up, seasons.count <= 1 else { return }
                        scrollToTopTrigger.toggle()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            focusedActionButton = "play"
                        }
                    }
                    .onChange(of: episodeScrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(target, anchor: .leading)
                        }
                        episodeScrollTarget = nil
                    }
                }
            }
        }
    }

    // MARK: - Episode Section (Seasons)

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isLoadingEpisodes || isLoadingSeasons {
                ProgressView("Loading episodes...")
            } else if !episodes.isEmpty {
                if shouldUseSingleSeasonPillHeaderInSeasonDetail {
                    SeasonPillBar(
                        seasons: seasonDetailHeaderPills,
                        selectedSeason: $selectedSeason,
                        onSeasonSelected: { _ in }
                    )
                    .opacity(scrollProgress)
                } else {
                    Text("Episodes")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.leading, 48)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(episodes, id: \.ratingKey) { episode in
                            EpisodeCard(
                                episode: episode,
                                serverURL: authManager.selectedServerURL ?? "",
                                authToken: authManager.selectedServerToken ?? "",
                                focusedEpisodeId: $focusedEpisodeId,
                                onPlay: {
                                    selectedEpisode = episode
                                    playFromBeginning = false
                                    showPlayer = true
                                },
                                onRefreshNeeded: {
                                    await refreshEpisodeWatchStatus(ratingKey: episode.ratingKey)
                                },
                                onShowInfo: {
                                    navigateToEpisode = episode
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 16)
                }
                .scrollClipDisabled()
                .focusSection()
                .remembersFocus(key: "detailEpisodes", focusedId: $focusedEpisodeId)
            }
        }
    }

    // MARK: - Track Section (Albums)

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isLoadingTracks {
                ProgressView("Loading tracks...")
            } else if !tracks.isEmpty {
                Text("Tracks")
                    .font(.title2)
                    .fontWeight(.bold)

                LazyVStack(spacing: 12) {
                    ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { index, track in
                        AlbumTrackRow(
                            track: track,
                            trackNumber: track.index ?? (index + 1),
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            focusedId: $focusedTrackId,
                            onPlay: {
                                savedTrackFocus = track.ratingKey
                                MusicQueue.shared.playAlbum(tracks: tracks, startingAt: index)
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)  // Room for focus scale effect
            }
        }
    }

    // MARK: - Album Section (Artists)

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isLoadingAlbums {
                ProgressView("Loading albums...")
            } else if !albums.isEmpty {
                Text("Albums")
                    .font(.title2)
                    .fontWeight(.bold)

                LazyVStack(spacing: 16) {
                    ForEach(albums, id: \.ratingKey) { album in
                        AlbumRowButton(
                            album: album,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            focusedAlbumId: $focusedAlbumId,
                            onSelect: {
                                savedAlbumFocus = album.ratingKey
                                navigateToAlbum = album
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)  // Room for focus scale effect
                .focusSection()
            }
        }
    }

    // MARK: - Player Presentation (tvOS)

    /// Present player using UIViewController to intercept Menu button
    private func presentPlayer() {
        // Get images and metadata, then present player
        Task {
            // Wait for any in-flight pre-play picker writes to land first,
            // so the player is built against Plex's updated server-side
            // stream selection (avoids a race where the HLS URL is built
            // with stale audio / subtitle ids). Awaiting an already-finished
            // Task returns immediately, so leaving pendingPreplayWrite set
            // after it completes is harmless.
            if let pending = pendingPreplayWrite {
                _ = await pending.value
            }

            // Determine which item to play and fetch full metadata if needed (for DV/HDR detection)
            let playItem: PlexMetadata
            if let episode = selectedEpisode {
                // Fetch full metadata on-demand for episodes (avoids N+1 prefetch - Fixes RIVULET-V)
                if let ratingKey = episode.ratingKey, let fullEpisode = fullEpisodeMetadata[ratingKey] {
                    playItem = fullEpisode
                } else if let ratingKey = episode.ratingKey,
                          let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken {
                    // Fetch full metadata now (single request vs N+1 prefetch)
                    do {
                        let metadata = try await networkManager.getFullMetadata(
                            serverURL: serverURL,
                            authToken: token,
                            ratingKey: ratingKey
                        )
                        fullEpisodeMetadata[ratingKey] = metadata
                        playItem = metadata
                    } catch {
                        // Fall back to basic metadata if fetch fails
                        playItem = episode
                    }
                } else {
                    playItem = episode
                }
            } else if selectedTrack != nil {
                playItem = selectedTrack!
            } else {
                // For main item (movie), ensure full metadata with Stream data for DV/HDR detection.
                // Hub metadata often lacks Stream details needed for Dolby Vision profile detection.
                if let fm = fullMetadata, fm.Media?.first?.Part?.first?.Stream != nil {
                    playItem = fm
                } else if let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken,
                          let ratingKey = item.ratingKey {
                    do {
                        let metadata = try await networkManager.getFullMetadata(
                            serverURL: serverURL,
                            authToken: token,
                            ratingKey: ratingKey
                        )
                        fullMetadata = metadata
                        playItem = metadata
                    } catch {
                        playItem = fullMetadata ?? item
                    }
                } else {
                    playItem = fullMetadata ?? item
                }
            }

            // Use fullMetadata for updated viewOffset when playing the main item (not episodes/tracks)
            let viewOffset = (selectedEpisode == nil && selectedTrack == nil)
                ? (fullMetadata?.viewOffset ?? playItem.viewOffset)
                : playItem.viewOffset
            let resumeOffset = playFromBeginning ? nil : (Double(viewOffset ?? 0) / 1000.0)

            // Get images for loading screen (from cache or fetch if needed)
            let (artImage, thumbImage) = await getPlayerImages(for: playItem)

            await MainActor.run {
                // Create viewModel with cached images for instant loading screen display
                let queue = shuffledEpisodeQueue
                shuffledEpisodeQueue = []

                // Forward pre-play picker selections only when the picker
                // applies to the actual item being played. Show/season Play
                // resolves to a child episode whose stream ids may differ;
                // playFromBeginning paths reuse the same metadata so are fine.
                let useTrackOverrides = (selectedEpisode == nil && selectedTrack == nil)
                let viewModel = UniversalPlayerViewModel(
                    metadata: playItem,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? "",
                    startOffset: resumeOffset != nil && resumeOffset! > 0 ? resumeOffset : nil,
                    shuffledQueue: queue,
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage,
                    initialAudioTrackId: useTrackOverrides ? preplayAudioTrackId : nil,
                    initialSubtitleSelection: useTrackOverrides ? preplaySubtitleSelection : .auto
                )

                let useApplePlayer = UserDefaults.standard.bool(forKey: "useApplePlayer")
                let playerVC: UIViewController
                if useApplePlayer {
                    let nativePlayer = NativePlayerViewController(viewModel: viewModel)
                    nativePlayer.onDismiss = { [weak viewModel] in
                        lastPlayedMetadata = viewModel?.metadata
                        showPlayer = false
                    }
                    playerVC = nativePlayer
                } else {
                    let inputCoordinator = PlaybackInputCoordinator()
                    let playerView = UniversalPlayerView(viewModel: viewModel, inputCoordinator: inputCoordinator)
                    let container = PlayerContainerViewController(
                        rootView: playerView,
                        viewModel: viewModel,
                        inputCoordinator: inputCoordinator
                    )
                    container.onDismiss = { [weak viewModel] in
                        lastPlayedMetadata = viewModel?.metadata
                        showPlayer = false
                    }
                    playerVC = container
                }

                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    topVC.present(playerVC, animated: true)
                }
            }
        }
    }

    /// Get art and poster images for the player loading screen (from cache or fetch)
    private func getPlayerImages(for metadata: PlexMetadata) async -> (UIImage?, UIImage?) {
        guard let request = playerHeroBackdropRequest(for: metadata) else {
            return (nil, nil)
        }

        return await HeroBackdropResolver.shared.playerLoadingImages(for: request)
    }

    // MARK: - Data Loading

    /// Hydrates everything the detail view needs beyond the hero surface
    /// (cast, seasons, episodes, recommendations, etc.). Split out of the
    /// inline `.task` body so it can be invoked from both the initial task
    /// and the `canRunDetailCascade` onChange observer without duplicating
    /// the reset/cascade logic.
    ///
    /// The method is gated twice:
    /// 1. `shouldLoadDetailData` — only the *current* carousel card runs.
    ///    Passive side cards still call `syncHeroBackdrop()` so they show
    ///    the correct logo/art, then early-return.
    /// 2. `previewAnimationSettled` — even for the current card, the cascade
    ///    waits for the entry spring + staged fades to finish, and for
    ///    paging motion to stop. This keeps the main thread quiet during
    ///    the ~1.5s animation window.
    private func loadDetailData() async {
        // Passive carousel cards should keep any already-resolved metadata/logo
        // so transitions never swap logo -> title mid-motion.
        guard shouldLoadDetailData else {
            syncHeroBackdrop()
            return
        }

        // Defer network + state-reset churn until the entry/paging animation
        // settles. The onChange(of: canRunDetailCascade) observer will
        // re-invoke this method once `previewAnimationSettled` flips to true.
        guard previewAnimationSettled else {
            syncHeroBackdrop()
            return
        }

        // Reset below-fold state — stays hidden until the full cascade
        // completes so sections don't pop in one at a time.
        // fullMetadata + parentShowLogoPath are reset in the ungated
        // .task above (they run during the entry animation).
        belowFoldLoaded = false
        seasons = []
        episodes = []
        selectedSeason = nil
        unifiedEpisodes = []
        episodeScrollTarget = nil
        collectionItems = []
        collectionName = nil
        recommendedItems = []
        nextUpEpisode = nil
        isSummaryExpanded = false
        scrollProgress = 0
        belowFoldTitleOpacity = 0
        syncHeroBackdrop()

        // Index for Siri search
        browseActivity?.resignCurrent()
        let activity = NSUserActivity(activityType: "com.rivulet.viewMedia")
        activity.title = currentItem.title
        activity.isEligibleForSearch = true
        activity.userInfo = ["ratingKey": currentItem.ratingKey ?? ""]
        activity.targetContentIdentifier = "rivulet://detail?ratingKey=\(currentItem.ratingKey ?? "")"
        activity.becomeCurrent()
        browseActivity = activity

        // Initialize watched state
        isWatched = currentItem.isWatched

        // Initialize progress for animation
        displayedProgress = currentItem.watchProgress ?? 0

        // Initialize starred state for music (userRating > 0 means starred)
        isStarred = (currentItem.userRating ?? 0) > 0

        // fullMetadata + refreshHeroBackdropAssets are handled by the
        // ungated .task(id: detailLoadTaskID) above so they fire during
        // the entry animation and land before the text fade. By the time
        // we reach here, fullMetadata is already populated.

        // Load type-specific data — run independent calls in parallel
        // where possible so the total wall-clock time is the slowest
        // single call, not the sum.
        switch currentItem.type {
        case "movie":
            // Collection + recommendations are independent of each other
            async let collectionTask: Void = {
                if let collection = fullMetadata?.Collection?.first,
                   let collectionId = collection.idString,
                   let sectionId = fullMetadata?.librarySectionID {
                    let name = (collection.tag ?? "Collection") + " Collection"
                    await loadCollectionItems(sectionId: String(sectionId), collectionId: collectionId, name: name)
                }
            }()
            async let recommendTask: Void = loadRecommendedItems()
            _ = await (collectionTask, recommendTask)

        case "show":
            // Seasons and all-episodes are independent network calls
            async let seasonsTask: Void = loadSeasons()
            async let episodesTask: Void = loadAllEpisodes()
            async let nextUpTask: Void = loadNextUpEpisode()
            _ = await (seasonsTask, episodesTask, nextUpTask)

        case "season":
            async let seasonsTask: Void = loadSeasonsForCurrentSeason()
            async let episodesTask: Void = loadEpisodesForSeason()
            async let nextUpTask: Void = loadNextUpEpisode()
            _ = await (seasonsTask, episodesTask, nextUpTask)

        case "episode":
            async let seasonsTask: Void = loadSeasonsForEpisode()
            async let episodesTask: Void = loadAllEpisodes()
            _ = await (seasonsTask, episodesTask)

        case "album":
            await loadTracks()

        case "artist":
            await loadAlbums()

        default:
            break
        }

        // Warm the first batch of episode/recommendation thumbnails into the
        // image cache so they're instant when the below-fold fades in.
        // CachedAsyncImage checks the memory cache synchronously — if the
        // image is there, it renders on the first frame with no flash.
        await prefetchBelowFoldThumbnails()

        // All below-fold data + thumbnails are now populated — fade in.
        belowFoldLoaded = true
    }

    /// Warms the first visible episode / recommendation / collection
    /// thumbnails into the memory cache so `CachedAsyncImage` hits the
    /// synchronous path on first render — no flash, no placeholder frame.
    /// Caps at ~10 images to avoid delaying the below-fold reveal.
    private func prefetchBelowFoldThumbnails() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        var urls: [URL] = []

        // Episode thumbnails (first ~8 visible in the horizontal scroll)
        let visibleEpisodes = Array(unifiedEpisodes.prefix(8)) + Array(episodes.prefix(8))
        for ep in visibleEpisodes {
            if let thumb = ep.thumb, let url = URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)") {
                urls.append(url)
            }
        }

        // Recommendation / collection poster thumbnails (first ~6)
        let posterItems = Array(recommendedItems.prefix(6)) + Array(collectionItems.prefix(6))
        for item in posterItems {
            if let thumb = item.thumb ?? item.bestThumb,
               let url = URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)") {
                urls.append(url)
            }
        }

        // Album art / track thumbs
        let musicItems = Array(albums.prefix(6)) + Array(tracks.prefix(6))
        for item in musicItems {
            if let thumb = item.thumb,
               let url = URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)") {
                urls.append(url)
            }
        }

        guard !urls.isEmpty else { return }

        // Load concurrently (up to 8 at a time via the cache's coalescing)
        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(12) {
                group.addTask {
                    _ = await ImageCacheManager.shared.image(for: url)
                }
            }
        }
    }

    private func loadFullMetadata() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingExtras = true

        // Check in-memory cache first for instant display
        if let cached = PlexDataStore.shared.getCachedFullMetadata(for: ratingKey) {
            fullMetadata = cached

            // Pre-warm from cached data immediately
            if cached.type == "movie" || cached.type == "episode" {
                preWarmStreamURL(for: cached, serverURL: serverURL, authToken: token)
            }

            // If cache is fresh enough, skip the network request entirely
            if PlexDataStore.shared.isFullMetadataFresh(for: ratingKey) {
                // Still need to backfill genres for episodes from parent show
                if cached.type == "episode", (cached.Genre == nil || cached.Genre?.isEmpty == true) {
                    await backfillParentGenres(serverURL: serverURL, authToken: token)
                }
                isLoadingExtras = false
                return
            }
        }

        // Fetch from network (either no cache or stale cache)
        do {
            var metadata = try await networkManager.getFullMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )

            // Episodes don't carry Genre — backfill from parent show
            if metadata.type == "episode", (metadata.Genre == nil || metadata.Genre?.isEmpty == true),
               let showKey = metadata.grandparentRatingKey ?? currentItem.grandparentRatingKey {
                if let showMeta = try? await networkManager.getFullMetadata(
                    serverURL: serverURL, authToken: token, ratingKey: showKey
                ) {
                    metadata.Genre = showMeta.Genre
                    metadata.contentRating = metadata.contentRating ?? showMeta.contentRating
                }
            }

            fullMetadata = metadata
            PlexDataStore.shared.cacheFullMetadata(metadata, for: ratingKey)

            // Pre-warm stream URL for playable content (movies, episodes)
            // This reduces startup latency when user presses Play
            if metadata.type == "movie" || metadata.type == "episode" {
                preWarmStreamURL(for: metadata, serverURL: serverURL, authToken: token)
            }
        } catch {
            print("Failed to load full metadata: \(error)")
        }

        isLoadingExtras = false
    }

    /// Backfill genres from parent show for episodes that don't carry their own
    private func backfillParentGenres(serverURL: String, authToken: String) async {
        guard var current = fullMetadata, current.type == "episode",
              let showKey = current.grandparentRatingKey ?? currentItem.grandparentRatingKey else { return }

        if let showMeta = try? await networkManager.getFullMetadata(
            serverURL: serverURL, authToken: authToken, ratingKey: showKey
        ) {
            current.Genre = showMeta.Genre
            current.contentRating = current.contentRating ?? showMeta.contentRating
            fullMetadata = current
            PlexDataStore.shared.cacheFullMetadata(current, for: current.ratingKey ?? "")
        }
    }

    private func syncHeroBackdrop() {
        let request = currentHeroBackdropRequest()
        heroBackdrop.load(request: request, motionLocked: heroBackdropMotionLocked)
    }

    /// Re-syncs the hero backdrop after full metadata has loaded. For episodes
    /// and seasons, also fetches the parent show's metadata so its `clearLogo`
    /// can be folded into the request.
    private func refreshHeroBackdropAssets() async {
        if currentItem.type == "episode" || currentItem.type == "season" {
            await loadParentShowLogoPath()
        }
        syncHeroBackdrop()
    }

    private func currentHeroBackdropRequest() -> HeroBackdropRequest? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }

        // Prefer full metadata (carries the Image array) but fall back to the
        // hub item so we still get backdrop/thumb while the network call is in
        // flight.
        let source = fullMetadata ?? currentItem
        return source.heroBackdropRequest(
            serverURL: serverURL,
            authToken: token,
            logoPathOverride: parentShowLogoPath
        )
    }

    private func playerHeroBackdropRequest(for metadata: PlexMetadata) -> HeroBackdropRequest? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }

        let backdropSource = (metadata.type == "episode" && selectedEpisode != nil) ? currentItem : metadata
        let baseRequest = backdropSource.heroBackdropRequest(
            serverURL: serverURL,
            authToken: token,
            logoPathOverride: parentShowLogoPath
        )

        let thumbPath = metadata.thumb ?? metadata.bestThumb
        let thumbURL = thumbPath.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }

        return HeroBackdropRequest(
            cacheKey: metadata.ratingKey ?? baseRequest.cacheKey,
            plexBackdropURL: baseRequest.plexBackdropURL,
            plexThumbnailURL: thumbURL,
            plexLogoURL: baseRequest.plexLogoURL
        )
    }

    /// Fetches the parent show's full metadata (using the cached copy when
    /// fresh) and extracts its clearLogo path for use on episode/season views.
    private func loadParentShowLogoPath() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = relatedShowRatingKey else {
            return
        }

        if let cached = PlexDataStore.shared.getCachedFullMetadata(for: showRatingKey),
           PlexDataStore.shared.isFullMetadataFresh(for: showRatingKey) {
            parentShowLogoPath = cached.clearLogoPath
            return
        }

        do {
            let showMetadata = try await networkManager.getFullMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showRatingKey
            )
            PlexDataStore.shared.cacheFullMetadata(showMetadata, for: showRatingKey)
            parentShowLogoPath = showMetadata.clearLogoPath
        } catch {
            print("🎨 [Logo] Failed to fetch parent show metadata: \(error)")
        }
    }

    /// Pre-compute and cache stream URL to reduce player startup latency
    private func preWarmStreamURL(for metadata: PlexMetadata, serverURL: String, authToken: String) {
        guard let ratingKey = metadata.ratingKey,
              let partKey = metadata.Media?.first?.Part?.first?.key else { return }

        // Build direct play URL for playback prewarming
        if let url = networkManager.buildPlaybackDirectPlayURL(
            serverURL: serverURL,
            authToken: authToken,
            partKey: partKey
        ) {
            let headers = [
                "X-Plex-Token": authToken,
                "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
                "X-Plex-Platform": PlexAPI.platform,
                "X-Plex-Device": PlexAPI.deviceName,
                "X-Plex-Product": PlexAPI.productName
            ]
            StreamURLCache.shared.set(ratingKey: ratingKey, url: url, headers: headers)
            Task(priority: .utility) {
                await networkManager.warmDirectPlayStream(url: url, headers: headers)
            }
        }
    }

    private func loadCollectionItems(sectionId: String, collectionId: String, name: String) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        do {
            let items = try await networkManager.getCollectionItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: sectionId,
                collectionId: collectionId,
                excludeRatingKey: currentItem.ratingKey
            )
            collectionItems = items
            collectionName = name
        } catch {
            print("Failed to load collection items: \(error)")
        }
    }

    private func loadRecommendedItems() async {
        do {
            let items = try await recommendationService.recommendationsForItem(currentItem, blendWithHistory: true, limit: 12)
            recommendedItems = items
        } catch {
            print("Failed to load recommended items: \(error)")
        }
    }

    /// Determine the "next up" episode for the Play button on TV shows and seasons
    /// Uses Plex's OnDeck data if available, otherwise falls back to first unwatched episode
    private func loadNextUpEpisode() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // For seasons, find the next up episode from the loaded episodes
        if currentItem.type == "season" {
            await loadNextUpEpisodeForSeason()
            return
        }

        guard currentItem.type == "show" else { return }

        // Try to get OnDeck episode from full metadata
        if let onDeckEpisode = fullMetadata?.OnDeck?.Metadata?.first,
           let ratingKey = onDeckEpisode.ratingKey {
            // Fetch full metadata for the episode (includes Stream data for DV detection)
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
                return
            } catch {
                // Fall back to the basic OnDeck episode data
                nextUpEpisode = onDeckEpisode
                return
            }
        }

        // No OnDeck episode - search unifiedEpisodes if available
        if !unifiedEpisodes.isEmpty {
            let candidate = unifiedEpisodes.first(where: { $0.isInProgress })
                ?? unifiedEpisodes.first(where: { !$0.isWatched })
                ?? unifiedEpisodes.first

            if let candidate, let ratingKey = candidate.ratingKey {
                do {
                    nextUpEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL, authToken: token, ratingKey: ratingKey
                    )
                } catch {
                    nextUpEpisode = candidate
                }
            }
            return
        }

        // Fallback: per-season API calls (unifiedEpisodes not yet loaded)
        for season in seasons {
            guard let seasonRatingKey = season.ratingKey else { continue }

            do {
                let seasonEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonRatingKey
                )

                // First, look for an in-progress episode in this season
                if let inProgressEpisode = seasonEpisodes.first(where: { $0.isInProgress }),
                   let ratingKey = inProgressEpisode.ratingKey {
                    let fullEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    nextUpEpisode = fullEpisode
                    return
                }

                // Next, look for first unwatched episode in this season
                if let unwatchedEpisode = seasonEpisodes.first(where: { !$0.isWatched }),
                   let ratingKey = unwatchedEpisode.ratingKey {
                    let fullEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    nextUpEpisode = fullEpisode
                    return
                }
            } catch {
                print("Failed to load episodes for season: \(error)")
            }
        }

        // All episodes watched - fall back to first episode of first season
        if let firstSeason = seasons.first,
           let seasonRatingKey = firstSeason.ratingKey {
            do {
                let seasonEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonRatingKey
                )
                if let firstEpisode = seasonEpisodes.first,
                   let ratingKey = firstEpisode.ratingKey {
                    let fullEpisode = try await networkManager.getFullMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    nextUpEpisode = fullEpisode
                }
            } catch {
                print("Failed to load first episode: \(error)")
            }
        }
    }

    /// Determine the "next up" episode for seasons
    /// Finds the first in-progress or unwatched episode, falls back to first episode
    private func loadNextUpEpisodeForSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // First, look for an in-progress episode
        if let inProgressEpisode = episodes.first(where: { $0.isInProgress }),
           let ratingKey = inProgressEpisode.ratingKey {
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
                return
            } catch {
                nextUpEpisode = inProgressEpisode
                return
            }
        }

        // Next, look for the first unwatched episode
        if let unwatchedEpisode = episodes.first(where: { !$0.isWatched }),
           let ratingKey = unwatchedEpisode.ratingKey {
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
                return
            } catch {
                nextUpEpisode = unwatchedEpisode
                return
            }
        }

        // All episodes watched - fall back to first episode
        if let firstEpisode = episodes.first,
           let ratingKey = firstEpisode.ratingKey {
            do {
                let fullEpisode = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                nextUpEpisode = fullEpisode
            } catch {
                nextUpEpisode = firstEpisode
            }
        }
    }

    private func loadAndPlayTrailer() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let trailer = fullMetadata?.trailer,
              let ratingKey = trailer.ratingKey else { return }

        do {
            // Fetch full metadata for the trailer (includes Media/Part info for playback)
            let metadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            trailerMetadata = metadata
            showTrailerPlayer = true
        } catch {
            print("Failed to load trailer metadata: \(error)")
        }
    }

    private func toggleWatched() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        do {
            if isWatched {
                try await networkManager.markUnwatched(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                isWatched = false
            } else {
                try await networkManager.markWatched(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                // Animate progress bar to 100% before marking as watched
                withAnimation(.easeOut(duration: 0.5)) {
                    displayedProgress = 1.0
                }
                // After animation, mark as watched and hide progress
                try? await Task.sleep(nanoseconds: 500_000_000)
                isWatched = true
            }
            // Notify home screen to refresh Continue Watching
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
        } catch {
            print("Failed to toggle watched status: \(error)")
        }
    }

    private func toggleStarRating() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        do {
            // Toggle between 5 stars (rating=10) and no rating (rating=nil)
            let newRating: Int? = isStarred ? nil : 10
            try await networkManager.setRating(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey,
                rating: newRating
            )
            isStarred.toggle()
        } catch {
            print("Failed to toggle star rating: \(error)")
        }
    }

    // MARK: - Episode Navigation

    /// Navigate to the parent season of the current episode
    private func navigateToParentSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let seasonKey = currentItem.parentRatingKey else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            let seasonMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: seasonKey
            )
            navigateToSeason = seasonMetadata
        } catch {
            print("Failed to load season metadata: \(error)")
        }
    }

    /// Navigate to the parent show of the current episode
    private func navigateToParentShow() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showKey = currentItem.grandparentRatingKey else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            let showMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showKey
            )
            navigateToShow = showMetadata
        } catch {
            print("Failed to load show metadata: \(error)")
        }
    }

    /// Navigate to the parent show from a season (season's parent is the show)
    private func navigateToParentShowFromSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showKey = currentItem.parentRatingKey else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            let showMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showKey
            )
            navigateToShow = showMetadata
        } catch {
            print("Failed to load show metadata: \(error)")
        }
    }

    private func loadSeasons() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingSeasons = true

        do {
            let fetchedSeasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            seasons = fetchedSeasons

            // Auto-select first season
            if let first = fetchedSeasons.first {
                selectedSeason = first
            }
        } catch {
            print("Failed to load seasons: \(error)")
        }

        isLoadingSeasons = false
    }

    /// Load seasons when viewing an episode - displays the parent show's seasons inline
    private func loadSeasonsForEpisode() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = currentItem.grandparentRatingKey else { return }

        isLoadingSeasons = true

        do {
            let fetchedSeasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showRatingKey
            )
            seasons = fetchedSeasons

            // Select the season this episode belongs to
            // Note: We don't set focusedSeasonId here - focus should stay on action buttons
            // The ScrollViewReader will scroll the season into view when user navigates down
            if let currentSeasonKey = currentItem.parentRatingKey,
               let currentSeason = fetchedSeasons.first(where: { $0.ratingKey == currentSeasonKey }) {
                selectedSeason = currentSeason
            } else if let first = fetchedSeasons.first {
                // Fallback to first season
                selectedSeason = first
            }
        } catch {
            print("Failed to load seasons for episode: \(error)")
        }

        isLoadingSeasons = false
    }

    /// Load sibling seasons when viewing a season so single-season shows can
    /// keep the season-pill header pattern instead of falling back to `Episodes`.
    private func loadSeasonsForCurrentSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = currentItem.parentRatingKey else { return }

        isLoadingSeasons = true

        do {
            let fetchedSeasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showRatingKey
            )
            seasons = fetchedSeasons

            if let currentSeasonKey = currentItem.ratingKey,
               let currentSeason = fetchedSeasons.first(where: { $0.ratingKey == currentSeasonKey }) {
                selectedSeason = currentSeason
            } else if let first = fetchedSeasons.first {
                selectedSeason = first
            }
        } catch {
            print("Failed to load sibling seasons for season detail: \(error)")
        }

        isLoadingSeasons = false
    }

    /// Load all episodes across all seasons using getAllLeaves (single API call)
    private func loadAllEpisodes() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        let ratingKey: String?
        if currentItem.type == "show" {
            ratingKey = currentItem.ratingKey
        } else if currentItem.type == "episode" {
            ratingKey = currentItem.grandparentRatingKey
        } else {
            return
        }

        guard let ratingKey else { return }

        isLoadingEpisodes = true

        do {
            let allEps = try await networkManager.getAllLeaves(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            unifiedEpisodes = allEps

            // When opened from a specific episode, scroll the unified list to that episode.
            // Defer one run loop so the ScrollViewReader mounts with the new list before
            // its .onChange(episodeScrollTarget) observer fires.
            if currentItem.type == "episode", let targetKey = currentItem.ratingKey {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                episodeScrollTarget = targetKey
            }
        } catch {
            print("Failed to load all episodes: \(error)")
        }

        isLoadingEpisodes = false
    }

    /// Load episodes for a season.
    /// - Parameter crossfade: When true, keeps old episodes visible and crossfades to new ones
    ///   instead of showing a loading indicator. Used for season switching.
    private func loadEpisodes(for season: PlexMetadata, crossfade: Bool = false) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = season.ratingKey else { return }

        if !crossfade {
            isLoadingEpisodes = true
        }

        do {
            let fetchedEpisodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            if crossfade {
                withAnimation(.easeInOut(duration: 0.35)) {
                    episodes = fetchedEpisodes
                }
            } else {
                episodes = fetchedEpisodes
            }
            // Note: Full metadata is fetched on-demand when user plays an episode
            // to avoid N+1 API calls (Fixes RIVULET-V)
        } catch {
            print("Failed to load episodes: \(error)")
        }

        isLoadingEpisodes = false
    }

    /// Load episodes when viewing a season directly
    private func loadEpisodesForSeason() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingEpisodes = true

        do {
            let fetchedEpisodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            episodes = fetchedEpisodes
            // Note: Full metadata is fetched on-demand when user plays an episode
            // to avoid N+1 API calls (Fixes RIVULET-V)
        } catch {
            print("Failed to load episodes for season: \(error)")
        }

        isLoadingEpisodes = false
    }

    /// Refresh a single episode's watch status without reloading the entire list
    /// This preserves focus position in the episode list
    private func refreshEpisodeWatchStatus(ratingKey: String?) async {
        guard let ratingKey = ratingKey,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        do {
            // Fetch fresh metadata for just this episode
            let updatedMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )

            // Update the episode in place
            if let index = episodes.firstIndex(where: { $0.ratingKey == ratingKey }) {
                episodes[index].viewCount = updatedMetadata.viewCount
                episodes[index].viewOffset = updatedMetadata.viewOffset
            }

            // Also update in unified episodes
            if let index = unifiedEpisodes.firstIndex(where: { $0.ratingKey == ratingKey }) {
                unifiedEpisodes[index].viewCount = updatedMetadata.viewCount
                unifiedEpisodes[index].viewOffset = updatedMetadata.viewOffset
            }

            // Also update prefetched metadata
            fullEpisodeMetadata[ratingKey] = updatedMetadata
        } catch {
            print("Failed to refresh episode watch status: \(error)")
        }
    }


    private func loadTracks() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else { return }

        isLoadingTracks = true

        do {
            let fetchedTracks = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            tracks = fetchedTracks
        } catch {
            print("Failed to load tracks: \(error)")
        }

        isLoadingTracks = false
    }

    private func loadAlbums() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = currentItem.ratingKey else {
            return
        }

        // Get librarySectionID from fullMetadata (fetched first) or item
        guard let librarySectionId = fullMetadata?.librarySectionID ?? currentItem.librarySectionID else {
            return
        }

        isLoadingAlbums = true

        do {
            // Use the library section endpoint with artist.id filter
            // This is more reliable than /children endpoint
            let fetchedAlbums = try await networkManager.getAlbumsForArtist(
                serverURL: serverURL,
                authToken: token,
                librarySectionId: librarySectionId,
                artistId: ratingKey
            )

            // Sort by year (newest first)
            albums = fetchedAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        } catch {
            print("Failed to load albums: \(error)")
        }

        isLoadingAlbums = false
    }


    // MARK: - URL Helpers

    /// Poster URL - uses grandparent poster for episodes (series poster)
    private var posterURL: URL? {
        let thumb: String?

        // For TV show episodes, prefer the series poster (grandparentThumb)
        if currentItem.type == "episode" || currentItem.type == "season" {
            thumb = currentItem.grandparentThumb ?? currentItem.parentThumb ?? currentItem.thumb
        } else {
            thumb = currentItem.thumb
        }

        guard let thumbPath = thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumbPath)?X-Plex-Token=\(token)")
    }

    private var thumbURL: URL? {
        guard let thumb = currentItem.thumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }
}

// MARK: - Season Poster Bar (tvOS)


/// Season poster card for the horizontal bar. Click selects, focus only highlights.
struct SeasonBarCard: View {
    let season: PlexMetadata
    let isSelected: Bool
    let serverURL: String
    let authToken: String
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }
    private var titleSize: CGFloat { ScaledDimensions.posterTitleSize * scale }
    private var subtitleSize: CGFloat { ScaledDimensions.posterSubtitleSize * scale }

    @FocusState private var isFocused: Bool

    private var isFullyWatched: Bool {
        guard let leafCount = season.leafCount,
              let viewedLeafCount = season.viewedLeafCount,
              leafCount > 0 else { return false }
        return viewedLeafCount >= leafCount
    }

    private var seasonLabel: String {
        if let index = season.index {
            if index == 0 { return "Specials" }
            return "Season \(index)"
        }
        return season.title ?? "Season"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 10) {
                // Season poster
                posterImage
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay(alignment: .topTrailing) {
                        if isFullyWatched {
                            WatchedCornerTag()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? .white : .clear, lineWidth: 3)
                    )

                // Season label
                Text(seasonLabel)
                    .font(.system(size: titleSize, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected || isFocused ? 1.0 : 0.6))
                    .lineLimit(1)
            }
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .hoverEffect(.highlight)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    private var posterImage: some View {
        CachedAsyncImage(url: posterURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty:
                Rectangle()
                    .fill(Color(white: 0.15))
                    .overlay { ProgressView().tint(.white.opacity(0.3)) }
            case .failure:
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.18), Color(white: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Image(systemName: "number.square")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }

    private var posterURL: URL? {
        guard let thumb = season.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

/// Horizontal scrollable row of season poster cards. Click-to-select only.
struct SeasonPosterBar: View {
    let seasons: [PlexMetadata]
    @Binding var selectedSeason: PlexMetadata?
    let serverURL: String
    let authToken: String
    let onSeasonSelected: (PlexMetadata) -> Void

    @FocusState private var focusedSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(seasons, id: \.ratingKey) { season in
                        SeasonBarCard(
                            season: season,
                            isSelected: selectedSeason?.ratingKey == season.ratingKey,
                            serverURL: serverURL,
                            authToken: authToken,
                            onSelect: {
                                selectedSeason = season
                                onSeasonSelected(season)
                            }
                        )
                        .focused($focusedSeasonId, equals: season.ratingKey)
                        .id(season.ratingKey)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
            .scrollClipDisabled()
            .focusSection()
            .remembersFocus(key: "seasonPosters", focusedId: $focusedSeasonId)
            .onChange(of: selectedSeason?.ratingKey) { _, newKey in
                guard let key = newKey else { return }
                withAnimation {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
        }
    }
}


// MARK: - Season Poster Card

struct SeasonPosterCard: View {
    let season: PlexMetadata
    let isSelected: Bool
    let serverURL: String
    let authToken: String
    var focusedSeasonId: FocusState<String?>.Binding?
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }
    private var titleSize: CGFloat { ScaledDimensions.posterTitleSize * scale }
    private var subtitleSize: CGFloat { ScaledDimensions.posterSubtitleSize * scale }

    /// Season is fully watched when all episodes have been viewed
    private var isFullyWatched: Bool {
        guard let leafCount = season.leafCount,
              let viewedLeafCount = season.viewedLeafCount,
              leafCount > 0 else { return false }
        return viewedLeafCount >= leafCount
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .center, spacing: 12) {
                // Season poster - structure matches MediaPosterCard
                posterImage
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay(alignment: .topTrailing) {
                        // Watched indicator (corner triangle tag) - inside clipShape so it curves
                        if isFullyWatched {
                            WatchedCornerTag()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 4)
                    )
                    .hoverEffect(.highlight)  // Native tvOS focus effect - scales poster AND badge
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
                    .padding(.bottom, 10)  // Space for hover scale effect

                // Season label
                VStack(spacing: 4) {
                    Text(seasonLabel)
                        .font(.system(size: titleSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))

                    if let leafCount = season.leafCount {
                        Text("\(leafCount) episodes")
                            .font(.system(size: subtitleSize))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .modifier(SeasonFocusModifier(focusedSeasonId: focusedSeasonId, seasonRatingKey: season.ratingKey))
    }

    private var seasonLabel: String {
        // Format as "Season 01", "Season 02", etc.
        if let index = season.index {
            return String(format: "Season %02d", index)
        }
        return season.title ?? "Season"
    }

    private var posterImage: some View {
        CachedAsyncImage(url: posterURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty:
                Rectangle()
                    .fill(Color(white: 0.15))
                    .overlay { ProgressView().tint(.white.opacity(0.3)) }
            case .failure:
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.18), Color(white: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Image(systemName: "number.square")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }

    private var posterURL: URL? {
        guard let thumb = season.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

// MARK: - Scroll Offset Tracking

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Season Pill Bar

/// Horizontal row of capsule/pill buttons for season selection (Apple TV+ style)
struct SeasonPillBar: View {
    let seasons: [PlexMetadata]
    @Binding var selectedSeason: PlexMetadata?
    let onSeasonSelected: (PlexMetadata) -> Void

    @FocusState private var focusedSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(seasons, id: \.ratingKey) { season in
                        let isSelected = selectedSeason?.ratingKey == season.ratingKey
                        SeasonPillButton(
                            label: seasonLabel(for: season),
                            isSelected: isSelected,
                            action: {
                                selectedSeason = season
                                onSeasonSelected(season)
                            }
                        )
                        .focused($focusedSeasonId, equals: season.ratingKey)
                        .id(season.ratingKey)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
            .focusSection()
            .onAppear {
                // Initial scroll to selected season (handles "open show from specific episode")
                guard let key = selectedSeason?.ratingKey else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
            .onChange(of: selectedSeason?.ratingKey) { _, newKey in
                guard let newKey else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newKey, anchor: .center)
                }
            }
        }
    }

    private func seasonLabel(for season: PlexMetadata) -> String {
        if let index = season.index {
            if index == 0 { return "Specials" }
            return "Season \(index)"
        }
        return season.title ?? "Season"
    }
}

/// Individual season pill button
struct SeasonPillButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 24, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isFocused ? .black : .white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isFocused ? .white : (isSelected ? .white.opacity(0.2) : .clear))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected && !isFocused ? .white.opacity(0.4) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .hoverEffectDisabled()
        .focusEffectDisabled()
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}

// MARK: - Episode Card (Horizontal)

/// Apple TV+ style episode card for horizontal scrolling rows
struct EpisodeCard: View {
    let episode: PlexMetadata
    let serverURL: String
    let authToken: String
    var focusedEpisodeId: FocusState<String?>.Binding?
    var showSeasonPrefix: Bool = false
    let onPlay: () -> Void
    var onRefreshNeeded: MediaItemRefreshCallback? = nil
    var onShowInfo: MediaItemNavigationCallback? = nil

    @FocusState private var isFocused: Bool

    private let cardWidth: CGFloat = 340
    private let thumbHeight: CGFloat = 192

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .overlay { ProgressView().tint(.white.opacity(0.3)) }
                    case .failure:
                        Rectangle()
                            .fill(Color(white: 0.15))
                            .overlay {
                                Image(systemName: "play.rectangle")
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                    }
                }
                .frame(width: cardWidth, height: thumbHeight)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    // Duration pill
                    if let duration = episode.durationFormatted {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text(duration)
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    // Progress bar
                    if let progress = episode.watchProgress, progress > 0 && progress < 1 {
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.black.opacity(0.5)).frame(height: 3)
                                    Rectangle().fill(.blue).frame(width: geo.size.width * progress, height: 3)
                                }
                            }
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Watched indicator — same corner tag used on poster cards.
                    // In-progress episodes show the bottom bar instead (isWatched excludes that).
                    if episode.isWatched {
                        WatchedCornerTag()
                            .accessibilityLabel("Watched")
                    }
                }

                // Metadata below thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    // Episode label
                    Text(episodeLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isFocused ? .black.opacity(0.6) : .white.opacity(0.6))
                        .textCase(.uppercase)
                        .padding(.top, 10)

                    // Title
                    Text(episode.title ?? "Episode")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isFocused ? .black : .white)
                        .lineLimit(1)

                    // Summary
                    if let summary = episode.summary {
                        Text(summary)
                            .font(.system(size: 16))
                            .foregroundStyle(isFocused ? .black.opacity(0.7) : .white.opacity(0.7))
                            .lineLimit(3)
                            .padding(.top, 1)
                    }

                    // Date + Content Rating
                    HStack(spacing: 6) {
                        if let date = episode.originallyAvailableAt {
                            Text(formattedDate(date))
                                .font(.system(size: 14))
                                .foregroundStyle(isFocused ? .black.opacity(0.5) : .white.opacity(0.5))
                        }
                        if let rating = episode.contentRating {
                            Text(rating)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isFocused ? .black.opacity(0.5) : .white.opacity(0.5))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(isFocused ? .black.opacity(0.3) : .white.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(width: cardWidth)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .modifier(EpisodeFocusModifier(focusedEpisodeId: focusedEpisodeId, episodeRatingKey: episode.ratingKey))
        .hoverEffect(.highlight)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .mediaItemContextMenu(
            item: episode,
            serverURL: serverURL,
            authToken: authToken,
            source: .other,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo
        )
    }

    private var episodeLabel: String {
        if showSeasonPrefix, let epString = episode.episodeString {
            return epString
        }
        if let index = episode.index {
            return "Episode \(index)"
        }
        return episode.episodeString ?? "Episode"
    }

    private var thumbURL: URL? {
        guard let thumb = episode.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }

    private func formattedDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: PlexMetadata
    let serverURL: String
    let authToken: String
    var isCurrent: Bool = false  // Indicates this is the episode currently being viewed
    var focusedEpisodeId: FocusState<String?>.Binding?
    let onPlay: () -> Void
    var onPlayFromBeginning: (() -> Void)? = nil
    var onRefreshNeeded: MediaItemRefreshCallback? = nil
    var onShowInfo: MediaItemNavigationCallback? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 16) {
                // Thumbnail
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay {
                                Image(systemName: "play.rectangle")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottom) {
                    // Progress bar
                    if let progress = episode.watchProgress, progress > 0 && progress < 1 {
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.black.opacity(0.5))
                            Color.blue
                                .scaleEffect(x: progress, anchor: .leading)
                        }
                        .frame(height: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    if let epString = episode.episodeString {
                        Text(epString)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }

                    Text(episode.title ?? "Episode")
                        .font(.system(size: 30, weight: .medium))
                        .lineLimit(1)

                    if let duration = episode.durationFormatted {
                        Text(duration)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }

                    if let summary = episode.summary {
                        Text(summary)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Current episode indicator (when viewing episode detail)
                if isCurrent {
                    Text("VIEWING")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.blue)
                        )
                }

                // Watched indicator
                if episode.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 24))
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 22)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .modifier(EpisodeFocusModifier(focusedEpisodeId: focusedEpisodeId, episodeRatingKey: episode.ratingKey))
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .mediaItemContextMenu(
            item: episode,
            serverURL: serverURL,
            authToken: authToken,
            source: .other,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo
        )
    }

    private var thumbURL: URL? {
        guard let thumb = episode.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

/// Helper modifier to apply focus binding to episode rows
struct EpisodeFocusModifier: ViewModifier {
    var focusedEpisodeId: FocusState<String?>.Binding?
    let episodeRatingKey: String?

    func body(content: Content) -> some View {
        if let binding = focusedEpisodeId, let key = episodeRatingKey {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}

// MARK: - Skeleton Episode Row

/// Loading placeholder for episode rows - shows while fetching episode data
struct SkeletonEpisodeRow: View {
    let episodeNumber: Int

    var body: some View {
        HStack(spacing: 16) {
            // Placeholder thumbnail
            Rectangle()
                .fill(Color(white: 0.15))
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    ProgressView()
                        .tint(.white.opacity(0.3))
                }

            VStack(alignment: .leading, spacing: 5) {
                // Episode number placeholder
                Text("Episode \(episodeNumber)")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))

                // Title placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 220, height: 26)

                // Duration placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 90, height: 22)
            }

            Spacer()
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

// MARK: - Album Track Row

struct AlbumTrackRow: View {
    let track: PlexMetadata
    let trackNumber: Int
    let serverURL: String
    let authToken: String
    var focusedId: FocusState<String?>.Binding?
    @FocusState private var isFocused: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 16) {
                // Track number
                Text("\(trackNumber)")
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title ?? "Track \(trackNumber)")
                        .font(.system(size: 22, weight: .medium))
                        .lineLimit(1)

                    if let duration = track.durationFormatted {
                        Text(duration)
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(CardButtonStyle())
        .modifier(TrackFocusModifier(focusedId: focusedId, trackRatingKey: track.ratingKey))
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

/// Helper view for album rows with proper focus tracking
struct AlbumRowButton: View {
    let album: PlexMetadata
    let serverURL: String
    let authToken: String
    var focusedAlbumId: FocusState<String?>.Binding
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            ArtistAlbumRow(
                album: album,
                serverURL: serverURL,
                authToken: authToken,
                isFocused: isFocused
            )
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .focused(focusedAlbumId, equals: album.ratingKey)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

/// Helper modifier to apply focus binding to track rows
struct TrackFocusModifier: ViewModifier {
    var focusedId: FocusState<String?>.Binding?
    let trackRatingKey: String?

    func body(content: Content) -> some View {
        if let binding = focusedId, let key = trackRatingKey {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}

/// Helper modifier to apply focus binding to season cards
struct SeasonFocusModifier: ViewModifier {
    var focusedSeasonId: FocusState<String?>.Binding?
    let seasonRatingKey: String?

    func body(content: Content) -> some View {
        if let binding = focusedSeasonId, let key = seasonRatingKey {
            content.focused(binding, equals: key)
        } else {
            content
        }
    }
}

// MARK: - Artist Album Row

struct ArtistAlbumRow: View {
    let album: PlexMetadata
    let serverURL: String
    let authToken: String
    var isFocused: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            // Album artwork (square)
            CachedAsyncImage(url: thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty:
                    Rectangle()
                        .fill(Color(white: 0.15))
                        .overlay { ProgressView().tint(.white.opacity(0.3)) }
                case .failure:
                    Rectangle()
                        .fill(Color(white: 0.15))
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title ?? "Unknown Album")
                    .font(.system(size: 22, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let year = album.year {
                        Text(String(year))
                    }
                    if let trackCount = album.leafCount {
                        Text("\(trackCount) tracks")
                    }
                }
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
    }

    private var thumbURL: URL? {
        guard let thumb = album.thumb else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
    }
}

// MARK: - Artist Bio Sheet

struct ArtistBioSheet: View {
    let artistName: String
    let bio: String
    let thumbURL: URL?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedParagraph: Int?

    /// Split bio into small chunks for smooth scrolling
    /// Each chunk is ~2-3 sentences or ~300 chars max for comfortable reading
    private var bioChunks: [String] {
        let sentences = bio.components(separatedBy: ". ")
        var chunks: [String] = []
        var currentChunk = ""

        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let sentenceWithPeriod = trimmed.hasSuffix(".") ? trimmed : trimmed + "."

            if currentChunk.isEmpty {
                currentChunk = sentenceWithPeriod
            } else if currentChunk.count + sentenceWithPeriod.count < 300 {
                // Add to current chunk if under limit
                currentChunk += " " + sentenceWithPeriod
            } else {
                // Start new chunk
                chunks.append(currentChunk)
                currentChunk = sentenceWithPeriod
            }
        }

        // Add remaining chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks.isEmpty ? [bio] : chunks
    }

    var body: some View {
        // tvOS: Scrollable view with focusable paragraphs
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 40) {
                // Header with artist name
                Text(artistName)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 60)

                // Artist image
                if let url = thumbURL {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .empty:
                            Rectangle()
                                .fill(Color(white: 0.15))
                                .overlay { ProgressView().tint(.white.opacity(0.3)) }
                        case .failure:
                            Rectangle()
                                .fill(Color(white: 0.15))
                                .overlay {
                                    Image(systemName: "music.mic")
                                        .font(.system(size: 40, weight: .light))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                        }
                    }
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
                }

                // Bio text - split into small focusable chunks for smooth scrolling
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(bioChunks.enumerated()), id: \.offset) { index, chunk in
                        BioParagraphRow(
                            text: chunk,
                            isFocused: focusedParagraph == index
                        )
                        .focusable()
                        .focused($focusedParagraph, equals: index)
                    }
                }
                .frame(maxWidth: 1200)
                .padding(.horizontal, 80)

                // Done button at bottom (index = -1)
                BioDoneButton(isFocused: focusedParagraph == -1) {
                    dismiss()
                }
                .focused($focusedParagraph, equals: -1)
                .padding(.top, 20)
                .padding(.bottom, 80)
            }
            .padding(8) // Room for scale effect
        }
        .onExitCommand {
            dismiss()
        }
    }
}

// MARK: - Bio Sheet Helper Views (tvOS)

/// Focusable text chunk - minimal styling for continuous reading
private struct BioParagraphRow: View {
    let text: String
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Subtle focus indicator on the left edge
            RoundedRectangle(cornerRadius: 2)
                .fill(isFocused ? .white.opacity(0.6) : .clear)
                .frame(width: 3)

            Text(text)
                .font(.system(size: 26))
                .foregroundStyle(isFocused ? .white : .white.opacity(0.8))
                .multilineTextAlignment(.leading)
                .lineSpacing(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Done button for bio sheet - follows design guide glass styling
private struct BioDoneButton: View {
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 60)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(SettingsButtonStyle())
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Player View Wrapper (non-tvOS)


#Preview {
    let sampleMovie = PlexMetadata(
        ratingKey: "123",
        key: "/library/metadata/123",
        type: "movie",
        title: "Sample Movie",
        contentRating: "PG-13",
        summary: "This is a sample movie summary that describes the plot and gives viewers an idea of what to expect.",
        tagline: "An epic adventure awaits",
        year: 2024,
        duration: 7200000 // 2 hours
    )

    PlexDetailView(item: sampleMovie)
}

// MARK: - Navigation Destinations Modifier

/// Conditionally applies .navigationDestination modifiers.
/// Disabled in preview overlay flow (no NavigationStack ancestor).
private struct NavigationDestinationsModifier: ViewModifier {
    @Binding var navigateToAlbum: PlexMetadata?
    @Binding var navigateToSeason: PlexMetadata?
    @Binding var navigateToShow: PlexMetadata?
    @Binding var navigateToEpisode: PlexMetadata?
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .navigationDestination(item: $navigateToAlbum) { album in
                    PlexDetailView(item: album)
                }
                .navigationDestination(item: $navigateToSeason) { season in
                    PlexDetailView(item: season)
                }
                .navigationDestination(item: $navigateToShow) { show in
                    PlexDetailView(item: show)
                }
                .navigationDestination(item: $navigateToEpisode) { episode in
                    PlexDetailView(item: episode)
                }
        } else {
            content
        }
    }
}
