//
//  MediaDetailView.swift
//  Rivulet
//
//  Detail view for movies and TV shows with playback options
//

import SwiftUI
import os.log

private let previewFocusLog = Logger(subsystem: "com.rivulet.app", category: "PreviewFocus")

enum MediaDetailPresentationMode: Equatable {
    case previewCarousel
    case expandedDetail
}

struct MediaDetailView: View {
    let item: MediaItem
    var presentationMode: MediaDetailPresentationMode = .expandedDetail
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
    /// When set, sub-item navigation (e.g. clicking an episode's description
    /// tile to open the episode detail page) routes through this closure
    /// instead of the local `navigateToEpisode` binding. Required when the
    /// view is hosted inside `PreviewOverlayHost`: the preview is presented
    /// via UIKit `UIViewController.present(_:)`, so the SwiftUI view tree
    /// inside has no `NavigationStack` ancestor and `.navigationDestination`
    /// is a no-op. The host (typically `PlexHomeView`) dismisses the preview
    /// and pushes the destination onto its own `NavigationStack`.
    var onSubItemNavigation: ((MediaItem) -> Void)? = nil
    var enableDetailDataLoading: Bool = true
    /// When hosted inside `PreviewOverlayHost`, reflects whether the entry /
    /// paging animation has fully settled. The detail data cascade is deferred
    /// until this flips to `true` so the main thread stays quiet while the
    /// spring + staged fades are running.
    var previewAnimationSettled: Bool = true

    /// Tracks the currently displayed item - allows swapping content in place
    /// When set, this overrides `item` so collection/recommended navigation
    /// replaces content rather than pushing a new view
    @State private var displayedItem: MediaItem?

    /// The item currently being shown - either displayedItem or the original item
    private var currentItem: MediaItem {
        displayedItem ?? item
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.previewMenuBridge) private var menuBridge
    @Environment(MediaProviderRegistry.self) private var providerRegistry
    @Environment(MetadataSourceRegistry.self) private var metadataRegistry
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var seasons: [MediaItem] = []
    @State private var selectedSeason: MediaItem?
    @State private var episodes: [MediaItem] = []
    @State private var isLoadingSeasons = false
    @State private var isLoadingEpisodes = false
    @State private var showPlayer = false
    /// The episode (or movie) the user tapped Play on. Agnostic MediaItem;
    /// resolved to PlexMetadata just before handing off to UniversalPlayerView.
    @State private var selectedEpisodeItem: MediaItem?
    @State private var lastPlayedItem: MediaItem?  // Tracks what was playing when player dismissed (for auto-play)
    @State private var nextUpEpisode: MediaItem?  // The episode that will play when pressing Play on a show

    // Focus state for restoring focus when returning from nested navigation
    @FocusState private var focusedEpisodeId: String?  // Track focused episode
    @FocusState private var focusedActionButton: String?  // Track focused action button
    @State private var isSummaryExpanded = false  // Expand summary text on focus/click

    // Detail state (replaces fullMetadata)
    @State private var detail: MediaItemDetail?
    @State private var collectionItems: [MediaItem] = []
    @State private var collectionName: String?
    @State private var recommendedItems: [MediaItem] = []
    @State private var isWatched = false
    @State private var displayedProgress: Double = 0  // For animating progress bar
    @State private var isLoadingExtras = false
    @State private var showTrailerPlayer = false
    @State private var playFromBeginning = false  // For "Play from Beginning" button
    @State private var isLoadingShufflePlay = false
    @State private var shuffledEpisodeQueue: [MediaItem] = []

    // Pre-play track picker state. Selections are per-detail-page-visit
    // and are passed to the player on Play; we don't touch the saved
    // language preference managers, so future plays still default to
    // remembered language defaults until the user explicitly picks again.
    // `preplayAudioTrackId` / `preplaySubtitleSelection` carry the user's
    // local pick; `pendingPreplayWrite` chains the server-side PUT +
    // detail refresh so presentPlayer() can await it before building the
    // player VM.
    @State private var preplayAudioTrackId: String? = nil
    @State private var preplaySubtitleSelection: UniversalPlayerViewModel.InitialSubtitleSelection = .auto
    @State private var showAudioTrackPicker = false
    @State private var showSubtitleTrackPicker = false
    @State private var showSummarySheet = false  // Full description for movies/shows/episodes
    @State private var pendingPreplayWrite: Task<Void, Never>? = nil

    // Resume-or-restart prompt for in-progress items. Off by default;
    // when on, pressing Play on an in-progress item shows a Resume /
    // Start from Beginning / Cancel chooser instead of resuming silently.
    // Long-press "Watch from Beginning" paths bypass the prompt because
    // they pass `fromBeginning: true` to the launch closure directly.
    @AppStorage("promptResumeOrRestart") private var promptResumeOrRestart = false
    @AppStorage("hideSpoilersForUnwatched") private var hideSpoilersForUnwatched = false
    @State private var showResumeChoice = false
    @State private var resumeChoiceTimeMs: Int = 0
    @State private var resumeChoiceLaunch: ((_ playFromBeginning: Bool) -> Void)? = nil

    /// Escape hatch: PlexMetadata required by UniversalPlayerView.
    /// Populated via `presentPlayer()` at play time, by resolving the agnostic
    /// MediaItem's ref back to a concrete PlexMetadata via PlexNetworkManager.
    /// Post-wave-1: when UniversalPlayerView is reparameterized on MediaItem,
    /// this escape hatch can be removed.
    @State private var playerPlexMeta: PlexMetadata?
    @StateObject private var heroBackdrop = HeroBackdropCoordinator()
    @State private var belowFoldLoaded = false  // Flipped true after the full cascade finishes
    @State private var scrollProgress: CGFloat = 0  // 0 = at rest (peek), 1 = fully scrolled
    @State private var belowFoldTitleOpacity: CGFloat = 0
    @State private var scrollResetID = UUID()
    @State private var kenBurnsOffset: CGFloat = 0
    @State private var retainedLogoURL: URL?
    @State private var hasDisplayedHeroLogoImage = false
    @State private var parentShowLogoPath: String?
    @State private var parentShowSummary: String?
    @State private var parentShowTagline: String?

    // Navigation state for episode parent navigation
    @State private var navigateToSeason: MediaItem?
    @State private var navigateToShow: MediaItem?
    @State private var navigateToEpisode: MediaItem?
    @State private var isLoadingNavigation = false

    // Unified episode list state (all seasons in one scroll)
    @State private var unifiedEpisodes: [MediaItem] = []
    @State private var episodeScrollTarget: String? = nil
    @State private var scrollToTopTrigger = false
    @State private var browseActivity: NSUserActivity?

    private let networkManager = PlexNetworkManager.shared
    private let recommendationService = PersonalizedRecommendationService.shared

    private var provider: (any MediaProvider)? {
        providerRegistry.provider(for: currentItem.ref.providerID)
    }

    private var metadataSource: (any MetadataSource)? {
        metadataRegistry.source(for: currentItem.ref.providerID)
    }
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
        currentItem.ref.itemID
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
    /// timing (`showMetadata`) AND `detail` being loaded, so genres,
    /// cast, and summary all appear together. Because `loadDetail`
    /// fires immediately on appear (not gated by `previewAnimationSettled`),
    /// it typically returns before the text fade at ~750ms.
    private var effectiveMetadataVisible: Bool {
        guard showMetadata else { return false }
        if isPreviewCarousel || isExpandedPreviewFlow {
            return detail != nil
        }
        return true
    }

    private var heroBrandTitle: String {
        if currentItem.kind == .season {
            // TODO(post-wave-1): fetch grandparent show detail for season hero brand
            return currentItem.title
        }
        return currentItem.title
    }

    private var seasonHeroContextLabel: String? {
        guard currentItem.kind == .season else { return nil }
        guard let n = currentItem.seasonNumber else { return nil }
        return "Season \(n)"
    }

    private var relatedShowRatingKey: String? {
        switch currentItem.kind {
        case .episode:
            return currentItem.grandparentRef?.itemID
        case .season:
            return currentItem.parentRef?.itemID
        default:
            return nil
        }
    }

    /// Effective item data - merges detail (progress/viewOffset) over currentItem
    /// This ensures we have the most up-to-date playback position after returning from the player
    private var effectiveViewOffset: TimeInterval {
        // detail?.item has refreshed viewOffset after playback; fall back to currentItem
        return detail?.item.userState.viewOffset ?? currentItem.userState.viewOffset
    }

    private var effectiveIsInProgress: Bool {
        let offset = effectiveViewOffset
        guard let runtime = currentItem.runtime, runtime > 0 else { return false }
        let progress = offset / runtime
        return offset > 0 && progress < 0.98
    }

    private var effectiveWatchProgress: Double? {
        guard let runtime = currentItem.runtime, runtime > 0 else { return nil }
        let offset = effectiveViewOffset
        guard offset > 0 else { return nil }
        return min(1.0, offset / runtime)
    }

    private var effectiveRemainingFormatted: String? {
        guard effectiveIsInProgress, let runtime = currentItem.runtime else { return nil }
        let remaining = max(0, runtime - effectiveViewOffset)
        let minutes = Int(remaining / 60)
        if minutes >= 60 {
            let h = minutes / 60; let m = minutes % 60
            return "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    // MARK: - Derived helper properties

    private var currentItemDurationFormatted: String? {
        guard let runtime = currentItem.runtime else { return nil }
        let minutes = Int(runtime / 60)
        if minutes >= 60 {
            let h = minutes / 60; let m = minutes % 60
            return "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    private var currentItemEpisodeString: String? {
        guard let s = currentItem.seasonNumber, let e = currentItem.episodeNumber else { return nil }
        return "S\(s)E\(e)"
    }

    private var currentItemSeasonDisplayTitle: String? {
        guard let n = currentItem.seasonNumber else { return nil }
        return "Season \(n)"
    }

    // TODO(post-wave-1): fetch grandparent detail for episode hero brand.
    private var currentItemSeriesTitleForDisplay: String? {
        nil
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
        let title = episode.title

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
        // Modifier chain split across three computed properties to stay within
        // the Swift type-checker expression-complexity budget.
        contentWithInteractionHandlers
            .modifier(NavigationDestinationsModifier(
                navigateToSeason: $navigateToSeason,
                navigateToShow: $navigateToShow,
                navigateToEpisode: $navigateToEpisode,
                // Disabled inside `PreviewOverlayHost`-hosted views: the
                // overlay is presented via UIKit modal, so the SwiftUI
                // tree has no `NavigationStack` ancestor and these
                // destinations would be no-ops. Sub-item navigation in
                // that context routes through `onSubItemNavigation`
                // instead — see the host (PlexLibraryView /
                // PlexHomeView).
                isEnabled: onPreviewExitRequested == nil
            ))
    }

    /// Second segment: animation tasks + interaction/presentation onChange handlers.
    private var contentWithInteractionHandlers: some View {
        contentWithDataTasks
        .task(id: "kenburns-\(currentItem.ref.itemID)") {
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
        .onChange(of: presentationMode) { oldMode, newMode in
            let ref = currentItem.ref.itemID
            previewFocusLog.info("[Mode] \(String(describing: oldMode), privacy: .public) -> \(String(describing: newMode), privacy: .public) ref=\(ref, privacy: .public)")
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
        .onChange(of: currentItem.ref.itemID) { _, _ in
            retainedLogoURL = nil
            hasDisplayedHeroLogoImage = false
            parentShowLogoPath = nil
            parentShowSummary = nil
            parentShowTagline = nil
        }
        .onChange(of: showExpandedChrome) { _, isVisible in
            let ref = currentItem.ref.itemID
            let kind = String(describing: currentItem.kind)
            let nextUp = nextUpEpisode != nil
            let isShow = currentItem.kind == .show || currentItem.kind == .season
            let playDisabled = isShow && !nextUp
            previewFocusLog.info("[Chrome] showExpandedChrome=\(isVisible) isExpandedPreviewFlow=\(isExpandedPreviewFlow) kind=\(kind, privacy: .public) nextUpEpisode=\(nextUp) playButtonDisabled=\(playDisabled) currentFocus=\(String(describing: focusedActionButton), privacy: .public) ref=\(ref, privacy: .public)")
            guard isVisible, isExpandedPreviewFlow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                previewFocusLog.info("[Chrome] setting focusedActionButton=play (was \(String(describing: focusedActionButton), privacy: .public))")
                focusedActionButton = "play"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    previewFocusLog.info("[Chrome] 50ms later: focusedActionButton=\(String(describing: focusedActionButton), privacy: .public)")
                }
            }
        }
        // Re-assert focus on the play button once `nextUpEpisode` resolves.
        // For shows the Play button is `.disabled(nextUpEpisode == nil)`.
        // The initial focus-set on chrome reveal writes `focusedActionButton
        // = "play"`, but SwiftUI won't actually place focus on a disabled
        // button — so the value is set but no view has focus. Once the
        // detail loads and `nextUpEpisode` becomes non-nil, the button
        // enables; we have to re-assert the focus binding (setting to nil
        // first forces a re-evaluation) to make focus actually land.
        .onChange(of: nextUpEpisode) { oldValue, newValue in
            let ref = currentItem.ref.itemID
            previewFocusLog.info("[NextUp] changed: \(oldValue?.ref.itemID ?? "nil", privacy: .public) -> \(newValue?.ref.itemID ?? "nil", privacy: .public) isExpandedPreviewFlow=\(isExpandedPreviewFlow) showExpandedChrome=\(showExpandedChrome) currentFocus=\(String(describing: focusedActionButton), privacy: .public) ref=\(ref, privacy: .public)")
            guard newValue != nil,
                  isExpandedPreviewFlow,
                  showExpandedChrome else { return }
            focusedActionButton = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                previewFocusLog.info("[NextUp] re-asserting focusedActionButton=play")
                focusedActionButton = "play"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    previewFocusLog.info("[NextUp] 50ms later: focusedActionButton=\(String(describing: focusedActionButton), privacy: .public)")
                }
            }
        }
        .onChange(of: focusedActionButton) { oldValue, newValue in
            previewFocusLog.info("[Focus] focusedActionButton: \(String(describing: oldValue), privacy: .public) -> \(String(describing: newValue), privacy: .public) isExpandedPreviewFlow=\(isExpandedPreviewFlow)")
        }
        .onChange(of: focusedEpisodeId) { _, newId in
            // Sync season pill when user navigates across season boundary
            guard let newId,
                  let episode = unifiedEpisodes.first(where: { $0.ref.itemID == newId }),
                  episode.parentRef?.itemID != selectedSeason?.ref.itemID,
                  let newSeason = seasons.first(where: { $0.ref.itemID == episode.parentRef?.itemID }) else { return }
            selectedSeason = newSeason
        }
        .onAppear {
            guard isExpandedPreviewFlow, let bridge = menuBridge else { return }
            bridge.interceptHandler = { [self] in
                if navigateToSeason != nil {
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
        // Refresh in-memory episode arrays when a child MediaDetailView
        // (e.g. an episode pushed from this show's carousel) toggles its
        // watched state. Without this, backing out from the child reveals
        // the carousel still showing the pre-toggle state.
        .onReceive(NotificationCenter.default.publisher(for: .episodeWatchedStatusChanged)) { note in
            guard let rk = note.userInfo?["ratingKey"] as? String,
                  let watched = note.userInfo?["watched"] as? Bool else { return }
            applyEpisodeWatchedStatusUpdate(ratingKey: rk, watched: watched)
        }
        // Pre-play audio / subtitle picker sheets. Tracks come from the
        // first MediaSource in detail (movies/episodes have exactly one).
        .sheet(isPresented: $showAudioTrackPicker) {
            TrackSelectionSheet(
                trackType: .audio,
                tracks: preplayAudioTracks.map(MediaTrack.init(from:)),
                selectedTrackId: Int(preplayAudioTrackId ?? "") ?? currentSelectedAudioTrackPlexID,
                onSelect: { id in
                    if let id {
                        preplayAudioTrackId = "\(id)"
                        persistAudioTrackSelection(trackID: "\(id)")
                    }
                }
            )
        }
        .sheet(isPresented: $showSubtitleTrackPicker) {
            TrackSelectionSheet(
                trackType: .subtitles,
                tracks: preplaySubtitleTracks.map(MediaTrack.init(from:)),
                selectedTrackId: effectiveSubtitlePickerSelectionID,
                onSelect: { id in
                    if let id {
                        preplaySubtitleSelection = .track(id: id)
                        persistSubtitleTrackSelection(trackID: "\(id)")
                    } else {
                        preplaySubtitleSelection = .off
                        persistSubtitleTrackSelection(trackID: nil)
                    }
                }
            )
        }
        .sheet(isPresented: $showSummarySheet) {
            SummarySheet(
                title: summarySheetTitle,
                summary: effectiveOverview
            )
        }
        .onChange(of: currentItem.ref.itemID) { _, _ in
            // Reset pre-play picker state when navigating to a different
            // item within this detail view (e.g., via collection / recs).
            // Cancel any in-flight write for the previous item so
            // presentPlayer() doesn't await a task that refreshes
            // detail for the now-defunct item.
            preplayAudioTrackId = nil
            preplaySubtitleSelection = .auto
            pendingPreplayWrite?.cancel()
            pendingPreplayWrite = nil
        }
        // Resume-or-restart prompt for in-progress items (gated on the
        // `promptResumeOrRestart` setting; off by default).
        .confirmationDialog(
            "Resume Playback?",
            isPresented: $showResumeChoice,
            titleVisibility: .visible
        ) {
            Button("Resume from \(PlexMetadata.formatResumeTime(resumeChoiceTimeMs))") {
                resumeChoiceLaunch?(false)
                resumeChoiceLaunch = nil
            }
            Button("Start from Beginning") {
                resumeChoiceLaunch?(true)
                resumeChoiceLaunch = nil
            }
            Button("Cancel", role: .cancel) {
                resumeChoiceLaunch = nil
            }
        }
        .fullScreenCover(isPresented: $showTrailerPlayer) {
            // Escape hatch: UniversalPlayerView requires PlexMetadata.
            // playerPlexMeta is set by loadAndPlayTrailer() before showTrailerPlayer → true.
            if let meta = playerPlexMeta {
                UniversalPlayerView(metadata: meta)
            }
        }
        .onChange(of: showTrailerPlayer) { _, isShowing in
            // Clear player meta when trailer player is dismissed
            if !isShowing {
                playerPlexMeta = nil
            }
        }
        .onChange(of: showPlayer) { _, isShowing in
            if !isShowing { onPlayerDismissed() }
        }
    }

    private func onPlayerDismissed() {
        // Capture episode itemID before clearing for refresh
        let playedEpisodeKey = selectedEpisodeItem?.ref.itemID
        let lastPlayed = lastPlayedItem

        selectedEpisodeItem = nil
        playFromBeginning = false
        lastPlayedItem = nil
        playerPlexMeta = nil

        // If we're on an episode detail page and auto-play advanced to a different episode,
        // swap the displayed item so the detail page shows the last-played episode.
        // TODO(post-wave-1): episode-detail auto-advance swap (post-wave-1)
        if currentItem.kind == .episode {
            if let lastPlayed, lastPlayed.ref.itemID != currentItem.ref.itemID {
                // Silently drop swap; episode-detail auto-advance is a post-wave-1 feature
                _ = lastPlayed
            }
        }

        // Refresh metadata to get updated viewOffset after playback
        Task {
            await loadDetail()

            // Update displayed progress and watched state from refreshed detail
            if let d = detail {
                withAnimation(.easeOut(duration: 0.3)) {
                    displayedProgress = effectiveWatchProgress ?? 0
                    isWatched = d.item.userState.isPlayed
                }
            }

            // Also refresh the specific episode if one was played
            if let episodeKey = playedEpisodeKey {
                await refreshEpisodeWatchStatus(itemID: episodeKey)
            }

            // For show/season detail pages, also refresh episode list and next-up
            if currentItem.kind == .show {
                await loadAllEpisodes()
                await loadNextUpEpisode()
            } else if currentItem.kind == .season {
                await loadEpisodesForSeason()
                await loadNextUpEpisode()
            }
        }
    }

    private func heroContentHeight(for fullHeight: CGFloat) -> CGFloat {
        let shelfPeek: CGFloat
        switch currentItem.kind {
        case .show, .season, .episode:
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

    /// Fixed backdrop layer extracted to help the Swift type-checker.
    private func backdropLayer(stageSize: CGSize, geoSize: CGSize,
                               stageBaseOffset: CGPoint, windowOrigin: CGPoint) -> some View {
        heroBackdropImage
            .frame(width: stageSize.width, height: stageSize.height)
            .offset(
                x: stageBaseOffset.x - windowOrigin.x + backgroundParallaxOffset + kenBurnsOffset,
                y: stageBaseOffset.y - windowOrigin.y
            )
            .scaleEffect(heroBackdropScale)
            .frame(width: geoSize.width, height: geoSize.height)
            .clipped()
            .overlay { backdropScrollOverlay }
    }

    /// Material blur overlay driven by scroll progress.
    /// Extracted to avoid Swift type-checker complexity in the main body.
    @ViewBuilder
    private var backdropScrollOverlay: some View {
        // `.regularMaterial` is backed by `UIVisualEffectView` on tvOS, which runs a
        // blur render pass every frame. Gating on scrollProgress > 0.01 removes the
        // blur view from the tree entirely during the entry/paging animation.
        if scrollProgress > 0.01 {
            Rectangle()
                .fill(.regularMaterial)
                .opacity(scrollProgress)
        }
    }

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
                        if currentItem.kind == .episode {
                            if let epString = currentItemEpisodeString {
                                let title = currentItem.title
                                let header = epString + (title.isEmpty ? "" : " · \(title)")
                                let desc = detail?.item.overview ?? currentItem.overview ?? ""
                                if shouldBlurHeroSummary {
                                    // When blurring, split header (sharp) from description
                                    // (blurred) so the title stays visible. Matches Infuse.
                                    Text(header)
                                        .font(.caption)
                                        .bold()
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                    if !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.white)
                                            .lineLimit(3)
                                            .blur(radius: 8)
                                    }
                                } else {
                                    (Text(header).bold() + Text(desc.isEmpty ? "" : ":  \(desc)"))
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .lineLimit(3)
                                }
                            }
                        } else if currentItem.kind == .show || currentItem.kind == .season {
                            // For seasons, Plex often returns an empty
                            // summary (notably for single-season recently-
                            // added shows). Fall back to the parent show's
                            // tagline/summary so the hero isn't blank.
                            let effectiveTagline = detail?.tagline
                                ?? (currentItem.kind == .season ? parentShowTagline : nil)
                            if let tagline = effectiveTagline, !tagline.isEmpty {
                                Text(tagline)
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            if !effectiveOverview.isEmpty {
                                Text(effectiveOverview)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(3)
                            }
                        } else {
                            if let tagline = detail?.tagline {
                                Text(tagline)
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.9))
                            } else if let summary = detail?.item.overview ?? currentItem.overview, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(3)
                                    .blur(radius: shouldBlurHeroSummary ? 8 : 0)
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
                    if let d = detail, !d.cast.isEmpty {
                        let topCast = d.cast.prefix(3).map { $0.name }
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
            .animation(isPreviewCarousel ? nil : .easeInOut(duration: 0.3), value: currentItem.ref.itemID)
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
            if let contentRating = detail?.contentRating {
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

        // Type label from kind
        switch currentItem.kind {
        case .show, .episode, .season:
            parts.append("TV Show")
        case .movie:
            parts.append("Movie")
        default:
            break
        }

        // Genres (up to 2 — keeps the row concise alongside the type label and rating badge)
        let genres = detail?.genres ?? []
        for genre in genres.prefix(2) {
            parts.append(genre)
        }

        return parts
    }

    /// Year, duration, quality badges row (Apple TV+ style: "2023 · 49 min [4K] [DV] [5.1]")
    private var heroQualityRow: some View {
        HStack(spacing: 8) {
            // Year · Duration with dot separator
            let year = currentItem.year
            let duration = currentItemDurationFormatted

            if let year {
                Text(String(year))
            }
            if year != nil && duration != nil {
                Text("·")
            }
            if let duration {
                Text(duration)
            }

            if let rating = detail?.rating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", rating))
                }
            }

            // Quality badges from MediaSource
            let badges = detail?.mediaSources.first?.qualityBadges() ?? []
            ForEach(badges, id: \.self) { badge in
                QualityBadge(text: badge)
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

    /// Icon for fallback poster based on item kind
    private var iconForType: String {
        switch currentItem.kind {
        case .movie: return "film"
        case .show: return "tv"
        default: return "photo"
        }
    }

    /// Shuffle play all episodes for a show or season.
    private func shufflePlay() async {
        guard let prov = provider else { return }
        isLoadingShufflePlay = true
        defer { isLoadingShufflePlay = false }

        do {
            let allEpisodes: [MediaItem]
            if currentItem.kind == .season {
                allEpisodes = try await prov.children(of: currentItem.ref)
            } else {
                allEpisodes = try await prov.allEpisodes(of: currentItem.ref)
            }

            guard !allEpisodes.isEmpty else { return }

            var shuffled = allEpisodes
            shuffled.shuffle()

            selectedEpisodeItem = shuffled[0]
            shuffledEpisodeQueue = shuffled
            playFromBeginning = true
            showPlayer = true
        } catch {
            print("Failed to load episodes for shuffle play: \(error)")
        }
    }

    // MARK: - Summary Section (Full, below fold)

    /// Whether the hero overview should be blurred for the spoiler-hiding
    /// feature. Movies and episodes are spoiler-prone; show/season summaries
    /// are marketing-level and stay un-blurred. Matches Infuse: blur stays
    /// until the item is fully watched (in-progress is still blurred).
    private var shouldBlurHeroSummary: Bool {
        // `currentItem` is a navigation-time snapshot and never re-fetches its
        // watched flag; `isWatched` is the live @State that loadDetailData /
        // onPlayerDismissed / toggleWatched keep current. Consult both so the
        // blur clears once an episode is watched to completion (the @State
        // path) without a one-frame blur flash when arriving on an
        // already-watched item before loadDetailData runs (the snapshot path).
        let watched = isWatched || currentItem.isWatched
        guard hideSpoilersForUnwatched, !watched else { return false }
        switch currentItem.kind {
        case .movie, .episode: return true
        default: return false
        }
    }

    /// Resolved summary for hero / info-circle / SummarySheet, with parent-
    /// show fallback for seasons whose own summary Plex returns empty.
    private var effectiveOverview: String {
        let baseSummary = detail?.item.overview ?? currentItem.overview ?? ""
        if !baseSummary.isEmpty { return baseSummary }
        if currentItem.kind == .season, let parent = parentShowSummary, !parent.isEmpty {
            return parent
        }
        return ""
    }

    /// Whether the info-circle button should appear: only for kinds that
    /// have meaningful long descriptions, and only when one is present.
    private var hasReadableSummary: Bool {
        switch currentItem.kind {
        case .movie, .show, .season, .episode: break
        default: return false
        }
        return !effectiveOverview.isEmpty
    }

    /// Title for the SummarySheet: episode header (e.g., "S02E05 · Title")
    /// for episodes; the item's title for everything else.
    private var summarySheetTitle: String {
        if currentItem.kind == .episode, let epString = currentItem.episodeString {
            let title = currentItem.title
            return title.isEmpty ? epString : "\(epString) · \(title)"
        }
        return detail?.item.title ?? currentItem.title
    }

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

    /// True when the current item's provider can play it locally. TMDB-only
    /// items (from Discover, or watchlist entries with no Plex match) flow
    /// through MediaDetailView too, but Play/Resume doesn't apply — they
    /// show watchlist actions instead.
    private var isPlayableFromProvider: Bool {
        currentItem.ref.providerID != TMDBMediaMapper.providerID
    }

    /// Either show the resume-or-restart prompt (in-progress items, when the
    /// user has opted in via Settings) or launch playback directly (everything
    /// else). The launch closure runs synchronously on the chosen branch and
    /// is responsible for setting `selectedEpisodeItem` / `playFromBeginning`
    /// / `showPlayer` as needed. `userState.viewOffset` is in seconds; the
    /// formatter wants milliseconds.
    private func presentPlay(for item: MediaItem, launch: @escaping (_ playFromBeginning: Bool) -> Void) {
        let offsetSec = item.userState.viewOffset
        if promptResumeOrRestart, item.isInProgress, offsetSec > 0 {
            resumeChoiceTimeMs = Int(offsetSec * 1000)
            resumeChoiceLaunch = launch
            showResumeChoice = true
        } else {
            launch(false)
        }
    }

    private var actionButtons: some View {
        // ScrollView so the row keeps each button at its intrinsic width
        // (play button + multiple circle-to-pill buttons) when the total
        // exceeds the available width: happens on items with an extra
        // optional button (e.g. Trailer) or when a focused button
        // expands into a pill. tvOS focus engine auto-scrolls the
        // focused button into view; .scrollClipDisabled lets the
        // focus-driven pill expansion render past the viewport edge
        // without clipping.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                if isPlayableFromProvider {
                    playableActionButtons
                } else {
                    watchlistActionButton
                }
            }
        }
        .scrollClipDisabled()
        .disabled(!allowActionRowInteraction)
    }

    /// Play / Resume / Shuffle / Watched / Trailer — shown for in-library
    /// items whose provider can play them (Plex today).
    @ViewBuilder
    private var playableActionButtons: some View {
        // Primary play button with inline progress + time remaining
        if currentItem.kind == .show || currentItem.kind == .season {
            Button {
                guard let episode = nextUpEpisode else { return }
                presentPlay(for: episode) { fromBeginning in
                    selectedEpisodeItem = episode
                    playFromBeginning = fromBeginning
                    showPlayer = true
                }
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
        } else {
            // Movies/Episodes: Play button with progress bar + time remaining
            Button {
                presentPlay(for: currentItem) { fromBeginning in
                    playFromBeginning = fromBeginning
                    showPlayer = true
                }
            } label: {
                playButtonLabel(text: effectiveIsInProgress ? "Resume" : "Play", isFocused: focusedActionButton == "play")
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 32)
                    .frame(height: pillButtonHeight)
            }
            .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play", cornerRadius: pillButtonHeight / 2))
            .focused($focusedActionButton, equals: "play")
        }

        // Watched toggle — circle that expands to a label on focus.
        Button {
            Task { await toggleWatched() }
        } label: {
            actionCircleLabel(
                icon: isWatched ? "checkmark.circle.fill" : "checkmark",
                title: isWatched ? "Mark as Unwatched" : "Mark as Watched",
                isFocused: focusedActionButton == "watched"
            )
        }
        .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "watched", cornerRadius: circleButtonSize / 2, isPrimary: false))
        .focused($focusedActionButton, equals: "watched")
        .accessibilityLabel(isWatched ? "Mark as Unwatched" : "Mark as Watched")

        // Info button — surfaces the full description for items with a
        // non-empty summary (movies, shows, seasons, episodes). Hero
        // text is `lineLimit(3)`-truncated; this is the path to read the
        // rest. Matches Plex / Infuse "show full description".
        if hasReadableSummary {
            Button {
                showSummarySheet = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: circleButtonSize, height: circleButtonSize)
            }
            .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "summary", cornerRadius: circleButtonSize / 2, isPrimary: false))
            .focused($focusedActionButton, equals: "summary")
        }

        // Trailer button — perfect circle
        if detail?.trailerURL != nil {
            Button {
                Task { await loadAndPlayTrailer() }
            } label: {
                actionCircleLabel(
                    icon: "film",
                    title: "Trailer",
                    isFocused: focusedActionButton == "trailer"
                )
            }
            .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "trailer", cornerRadius: circleButtonSize / 2, isPrimary: false))
            .focused($focusedActionButton, equals: "trailer")
            .accessibilityLabel("Trailer")
        }

        // Pre-play audio track picker — only for movies and episodes
        // (single-video items where we know the streams ahead of play).
        if showsPreplayTrackPickers, !preplayAudioTracks.isEmpty {
            Button {
                showAudioTrackPicker = true
            } label: {
                actionCircleLabel(
                    icon: "speaker.wave.3",
                    title: "Audio",
                    isFocused: focusedActionButton == "audioTrack"
                )
            }
            .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "audioTrack", cornerRadius: circleButtonSize / 2, isPrimary: false))
            .focused($focusedActionButton, equals: "audioTrack")
            .accessibilityLabel("Audio")
        }

        // Pre-play subtitle track picker — hidden when there are no subtitle streams.
        if showsPreplayTrackPickers, !preplaySubtitleTracks.isEmpty {
            Button {
                showSubtitleTrackPicker = true
            } label: {
                actionCircleLabel(
                    icon: "captions.bubble",
                    title: "Subtitles",
                    isFocused: focusedActionButton == "subtitleTrack"
                )
            }
            .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "subtitleTrack", cornerRadius: circleButtonSize / 2, isPrimary: false))
            .focused($focusedActionButton, equals: "subtitleTrack")
            .accessibilityLabel("Subtitles")
        }
    }

    /// Label content for the secondary circular action buttons (Watched,
    /// Trailer, Audio, Subtitles). Unfocused it is an icon-only circle;
    /// on focus it expands into a labelled pill so the action is
    /// self-describing — the tvOS / Apple-TV+ convention of focus
    /// revealing affordance. The single-subtree (no `if`-swap) form lets
    /// the width animate smoothly rather than cross-fading, and the
    /// spring matches `AppStoreActionButtonStyle`'s focus animation so
    /// the background (drawn by the style) tracks the label exactly.
    @ViewBuilder
    private func actionCircleLabel(icon: String, title: String, isFocused: Bool) -> some View {
        HStack(spacing: isFocused ? 10 : 0) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
            if isFocused {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: circleButtonSize)
        // Keeps width == height (a true circle) until the label appears;
        // the label then drives the width past this minimum into a pill.
        .frame(minWidth: circleButtonSize)
        .padding(.horizontal, isFocused ? 26 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
    }

    // MARK: - Pre-play Track Picker Helpers

    /// Whether the pre-play picker buttons make sense for the current
    /// item type. Show / season / artist / album / track detail pages
    /// don't have a single, known track list at this level.
    private var showsPreplayTrackPickers: Bool {
        switch currentItem.kind {
        case .movie, .episode: return true
        default: return false
        }
    }

    /// First MediaSource on the detail (movies/episodes have exactly one).
    /// Streams come from `detail` once it's loaded; before that, the
    /// pickers stay hidden because their counts are zero.
    private var preplayPrimarySource: MediaSource? {
        detail?.mediaSources.first
    }

    private var preplayAudioTracks: [AudioTrack] {
        preplayPrimarySource?.audioTracks ?? []
    }

    private var preplaySubtitleTracks: [SubtitleTrack] {
        preplayPrimarySource?.subtitleTracks ?? []
    }

    /// Backend-flagged "currently selected" audio track for the user.
    /// Reflects whatever the user previously chose (in any client) or the
    /// provider's server-side default; what the player would pick today.
    /// Returned as the bridged Plex-stream-int form the picker expects.
    private var currentSelectedAudioTrackPlexID: Int? {
        guard let track = preplayAudioTracks.first(where: { $0.isSelected }) else { return nil }
        return Int(track.id)
    }

    /// Backend-flagged "currently selected" subtitle track. `nil` means
    /// subtitles are off server-side.
    private var currentSelectedSubtitleTrackPlexID: Int? {
        guard let track = preplaySubtitleTracks.first(where: { $0.isSelected }) else { return nil }
        return Int(track.id)
    }

    /// What to highlight in the subtitle picker on open. Honors the
    /// user's local preplay choice first, then falls back to the
    /// server-side selection so reopening the picker mid-visit shows
    /// the current state rather than always defaulting to "Off".
    private var effectiveSubtitlePickerSelectionID: Int? {
        switch preplaySubtitleSelection {
        case .track(let id): return id
        case .off: return nil
        case .auto: return currentSelectedSubtitleTrackPlexID
        }
    }

    /// Persist the chosen audio track to the provider so it sticks
    /// per-user-per-item across plays from any client. Refresh detail
    /// afterward so the local view of `isSelected` reflects the new
    /// state. Chained off any prior in-flight write so concurrent audio
    /// + subtitle picks serialise rather than racing.
    private func persistAudioTrackSelection(trackID: String) {
        guard let provider = providerRegistry.provider(for: currentItem.ref.providerID),
              let sourceID = preplayPrimarySource?.id else {
            return
        }
        let ref = currentItem.ref
        let previous = pendingPreplayWrite
        pendingPreplayWrite = Task {
            if let previous { _ = await previous.value }
            do {
                try await provider.setSelectedAudioTrack(trackID, source: sourceID, of: ref)
                await reloadDetailForPreplayWrite()
            } catch {
                print("[MediaDetailView] persistAudioTrackSelection failed: \(error)")
            }
        }
    }

    /// Persist the chosen subtitle track (or `nil` for "off") and refresh
    /// detail. Same chained-Task pattern as audio.
    private func persistSubtitleTrackSelection(trackID: String?) {
        guard let provider = providerRegistry.provider(for: currentItem.ref.providerID),
              let sourceID = preplayPrimarySource?.id else {
            return
        }
        let ref = currentItem.ref
        let previous = pendingPreplayWrite
        pendingPreplayWrite = Task {
            if let previous { _ = await previous.value }
            do {
                try await provider.setSelectedSubtitleTrack(trackID, source: sourceID, of: ref)
                await reloadDetailForPreplayWrite()
            } catch {
                print("[MediaDetailView] persistSubtitleTrackSelection failed: \(error)")
            }
        }
    }

    /// Refresh detail state so the picker shows the post-PUT `isSelected` flag.
    /// Best-effort — failures here just leave the local state slightly stale.
    private func reloadDetailForPreplayWrite() async {
        guard let provider = providerRegistry.provider(for: currentItem.ref.providerID) else { return }
        guard !Task.isCancelled else { return }
        do {
            let refreshed = try await provider.fullDetail(for: currentItem.ref)
            await MainActor.run {
                self.detail = refreshed
            }
        } catch {
            print("[MediaDetailView] preplay detail refresh failed: \(error)")
        }
    }

    /// Watchlist toggle — shown for items whose provider can't play them
    /// locally (TMDB-only items from Discover / watchlist with no Plex match).
    @ViewBuilder
    private var watchlistActionButton: some View {
        let tmdbId = TMDBMediaMapper.decodeItemID(currentItem.ref.itemID)?.tmdbId
        let onWatchlist = tmdbId.map { PlexWatchlistService.shared.contains(tmdbId: $0) } ?? false
        let label = onWatchlist ? "Remove from Watchlist" : "Add to Watchlist"
        let icon = onWatchlist ? "bookmark.fill" : "bookmark"

        Button {
            Task { await toggleWatchlist() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 32)
            .frame(height: pillButtonHeight)
        }
        .buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "watchlist", cornerRadius: pillButtonHeight / 2))
        .focused($focusedActionButton, equals: "watchlist")
    }

    /// Add or remove the current TMDB item from the Plex watchlist. Called
    /// only from `watchlistActionButton` so `currentItem.ref.providerID` is
    /// always the TMDB id.
    private func toggleWatchlist() async {
        guard let tmdbId = TMDBMediaMapper.decodeItemID(currentItem.ref.itemID)?.tmdbId else { return }
        let guid = "tmdb://\(tmdbId)"
        if PlexWatchlistService.shared.contains(tmdbId: tmdbId) {
            await PlexWatchlistService.shared.remove(guid: guid)
        } else {
            let type: PlexWatchlistItem.WatchlistType = currentItem.kind == .movie ? .movie : .show
            let item = PlexWatchlistItem(
                id: guid,
                title: currentItem.title,
                year: currentItem.year,
                type: type,
                posterURL: currentItem.artwork.poster,
                guids: [guid]
            )
            await PlexWatchlistService.shared.add(guid: guid, item: item)
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

            // Time: remaining if in progress, total duration otherwise.
            // lineLimit(1)+fixedSize prevents the parent HStack squeezing
            // an adjacent focused button from wrapping the time text
            // ("43m" → "43" / "m") or hiding it entirely.
            Group {
                if effectiveIsInProgress, let remaining = effectiveRemainingFormatted {
                    Text(remaining)
                } else if let duration = currentItemDurationFormatted {
                    Text(duration)
                } else {
                    Text(text)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        // Make the play button hold its intrinsic width. Without this
        // the row's HStack shrinks the Play button to give space to a
        // sibling that just expanded into a pill on focus.
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Body Modifier Chain (split for type-checker)

    /// First segment: layout + data-loading tasks. Applied before the
    /// interaction/navigation modifiers so each half stays within the
    /// Swift type-checker expression complexity budget.
    private var contentWithDataTasks: some View {
        contentLayout
            .ignoresSafeArea()
            .task(id: detailLoadTaskID) {
                // Fetch detail immediately — not gated by
                // `previewAnimationSettled`. This is a single network call
                // with no layout churn, and it needs to land before the
                // text fade at ~750ms so genres/cast/summary are ready
                // when the hero metadata fades in.
                guard shouldLoadDetailData else {
                    syncHeroBackdrop()
                    return
                }
                detail = nil
                parentShowLogoPath = nil
                parentShowSummary = nil
                parentShowTagline = nil
                syncHeroBackdrop()
                await loadDetail()
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
                // detail so the hero overlay has genres/cast/summary ready.
                guard isActive, detail == nil else { return }
                Task { @MainActor in
                    await loadDetail()
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
    }

    // MARK: - Content Layout

    /// Full backdrop + scroll layout. Extracted from `body` so that the long
    /// lifecycle-modifier chain in `body` stays within the Swift type-checker
    /// complexity budget.
    private var contentLayout: some View {
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
                    backdropLayer(stageSize: stageSize, geoSize: geo.size,
                                  stageBaseOffset: centeredStageBaseOffset,
                                  windowOrigin: stageWindowOrigin)
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

                            // Below-fold page: extracted to `belowFoldPage(geoHeight:)` for
                            // Swift type-checker relief on the deeply-nested body.
                            // Gated on the same metadata flag as the hero overlay so
                            // cast/episodes/recommended fade together during preview
                            // paging instead of staying visible through the card mask.
                            belowFoldPage(geoHeight: geo.size.height)
                                .opacity(effectiveMetadataVisible ? 1 : 0)
                                .animation(.easeOut(duration: 0.35), value: effectiveMetadataVisible)
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
    }

    // MARK: - Below-Fold Page

    /// Extracted from the ScrollView body to relieve Swift type-checker
    /// complexity on the deeply-nested ZStack.
    @ViewBuilder private func belowFoldPage(geoHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: geoHeight)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 32) {
                    let isShowOrEpisode = currentItem.kind == .show || currentItem.kind == .episode
                    if isShowOrEpisode { seasonSection }
                    if currentItem.kind == .season { episodeSection }
                }
                .padding(.top, belowFoldHeaderReserveHeight)
                .padding(.horizontal, 48)
                .allowsHitTesting(!isPreviewCarousel)
                recommendedRow
                collectionRow
                castCrewRow
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
                        let epKey = unifiedEpisodes.first(where: { $0.parentRef?.itemID == season.ref.itemID })?.ref.itemID
                        episodeScrollTarget = epKey
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
        currentItem.kind == .season && seasons.count <= 1
    }

    private var seasonDetailHeaderPills: [MediaItem] {
        let currentKey = currentItem.ref.itemID
        let matchingSeason = seasons.filter { $0.ref.itemID == currentKey }
        if !matchingSeason.isEmpty {
            return matchingSeason
        }
        if let selected = selectedSeason {
            return [selected]
        }
        return []
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
                            ForEach(Array(unifiedEpisodes.enumerated()), id: \.element.ref.itemID) { index, episode in
                                let isSeasonBoundary = index > 0 && episode.parentRef?.itemID != unifiedEpisodes[index - 1].parentRef?.itemID
                                let leadingPad: CGFloat = index == 0 ? 48 : (isSeasonBoundary ? 56 : 24)

                                EpisodeCard(
                                    episode: episode,
                                    serverURL: authManager.selectedServerURL ?? "",
                                    authToken: authManager.selectedServerToken ?? "",
                                    focusedEpisodeId: $focusedEpisodeId,
                                    showSeasonPrefix: seasons.count > 1,
                                    onPlay: {
                                        presentPlay(for: episode) { fromBeginning in
                                            selectedEpisodeItem = episode
                                            playFromBeginning = fromBeginning
                                            showPlayer = true
                                        }
                                    },
                                    onRefreshNeeded: {
                                        await refreshEpisodeWatchStatus(itemID: episode.ref.itemID)
                                    },
                                    onShowInfo: {
                                        if let nav = onSubItemNavigation {
                                            nav(episode)
                                        } else {
                                            navigateToEpisode = episode
                                        }
                                    }
                                )
                                .padding(.leading, leadingPad)
                                .padding(.trailing, index == unifiedEpisodes.count - 1 ? 48 : 0)
                                .id(episode.ref.itemID)
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
                        ForEach(episodes, id: \.ref.itemID) { episode in
                            EpisodeCard(
                                episode: episode,
                                serverURL: authManager.selectedServerURL ?? "",
                                authToken: authManager.selectedServerToken ?? "",
                                focusedEpisodeId: $focusedEpisodeId,
                                onPlay: {
                                    presentPlay(for: episode) { fromBeginning in
                                        selectedEpisodeItem = episode
                                        playFromBeginning = fromBeginning
                                        showPlayer = true
                                    }
                                },
                                onRefreshNeeded: {
                                    await refreshEpisodeWatchStatus(itemID: episode.ref.itemID)
                                },
                                onShowInfo: {
                                    if let nav = onSubItemNavigation {
                                        nav(episode)
                                    } else {
                                        navigateToEpisode = episode
                                    }
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

    // MARK: - Player Presentation (tvOS)

    /// Present player using UIViewController to intercept Menu button.
    ///
    /// This is the single site where agnostic MediaItem is resolved back to
    /// PlexMetadata for the UniversalPlayerView handoff (the "escape hatch").
    /// Post-wave-1: when UniversalPlayerView is reparameterized on MediaItem,
    /// this fetch can be removed.
    private func presentPlayer() {
        Task {
            // Wait for any in-flight pre-play picker writes to land first,
            // so the player is built against the provider's updated
            // server-side stream selection (avoids a race where the HLS
            // URL is built with stale audio / subtitle ids). Awaiting an
            // already-finished Task returns immediately, so leaving
            // pendingPreplayWrite set after it completes is harmless.
            if let pending = pendingPreplayWrite {
                _ = await pending.value
            }

            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }

            // Determine which MediaItem to play (episode or main item).
            let mediaItemToPlay: MediaItem
            if let ep = selectedEpisodeItem {
                mediaItemToPlay = ep
            } else {
                mediaItemToPlay = currentItem
            }

            // --- Escape hatch: resolve MediaItem → PlexMetadata for UniversalPlayerView ---
            // Fetch full metadata with Stream data for DV/HDR detection.
            let playItem: PlexMetadata
            do {
                playItem = try await networkManager.getFullMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: mediaItemToPlay.ref.itemID
                )
            } catch {
                // Fall back to basic metadata if full fetch fails
                do {
                    playItem = try await networkManager.getMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: mediaItemToPlay.ref.itemID
                    )
                } catch {
                    print("[MediaDetailView] player handoff fetch failed: \(error)")
                    return
                }
            }
            // --- End escape hatch ---

            // Determine resume offset
            let resumeOffset: Double?
            if playFromBeginning {
                resumeOffset = nil
            } else if selectedEpisodeItem != nil {
                // Episode: use its own viewOffset (seconds)
                let offsetSec = mediaItemToPlay.userState.viewOffset
                resumeOffset = offsetSec > 0 ? offsetSec : nil
            } else {
                // Main item: prefer detail's fresher viewOffset
                let offsetSec = detail?.item.userState.viewOffset ?? mediaItemToPlay.userState.viewOffset
                resumeOffset = offsetSec > 0 ? offsetSec : nil
            }

            // Convert MediaItem shuffle queue to PlexMetadata shells for UniversalPlayerViewModel.
            // The player fetches full metadata for each episode when it auto-advances.
            let plexQueue: [PlexMetadata] = shuffledEpisodeQueue.map { mi in
                var shell = PlexMetadata()
                shell.ratingKey = mi.ref.itemID
                shell.title = mi.title
                shell.type = "episode"
                shell.parentRatingKey = mi.parentRef?.itemID
                shell.grandparentRatingKey = mi.grandparentRef?.itemID
                shell.index = mi.episodeNumber
                shell.parentIndex = mi.seasonNumber
                shell.viewOffset = mi.userState.viewOffset > 0 ? Int(mi.userState.viewOffset * 1000) : nil
                return shell
            }

            // Get images for loading screen
            let (artImage, thumbImage) = await getPlayerImages(for: playItem)

            await MainActor.run {
                shuffledEpisodeQueue = []

                // Forward pre-play picker selections only when the picker
                // applies to the actual item being played. Show/season Play
                // resolves to a child episode whose stream IDs differ; in
                // that case the picker buttons aren't shown anyway, so
                // preplayAudioTrackId/Selection will be at their defaults.
                let useTrackOverrides = (selectedEpisodeItem == nil)
                let initialAudioId: Int? = useTrackOverrides
                    ? preplayAudioTrackId.flatMap { Int($0) }
                    : nil
                let initialSubtitleSelection: UniversalPlayerViewModel.InitialSubtitleSelection = useTrackOverrides
                    ? preplaySubtitleSelection
                    : .auto

                let viewModel = UniversalPlayerViewModel(
                    metadata: playItem,
                    serverURL: serverURL,
                    authToken: token,
                    startOffset: resumeOffset,
                    shuffledQueue: plexQueue,
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage,
                    initialAudioTrackId: initialAudioId,
                    initialSubtitleSelection: initialSubtitleSelection
                )

                let useApplePlayer = UserDefaults.standard.bool(forKey: "useApplePlayer")
                let playerVC: UIViewController
                if useApplePlayer {
                    let nativePlayer = NativePlayerViewController(viewModel: viewModel)
                    nativePlayer.onDismiss = { [weak viewModel] in
                        if let meta = viewModel?.metadata {
                            // Convert resolved PlexMetadata back to a lightweight MediaItem
                            // so lastPlayedItem stays agnostic. Using a synthetic ref.
                            var shell = PlexMetadata()
                            shell.ratingKey = meta.ratingKey
                            if let prov = self.providerRegistry.primaryProvider {
                                self.lastPlayedItem = PlexMediaMapper.item(
                                    meta,
                                    providerID: prov.id,
                                    serverURL: serverURL,
                                    authToken: token
                                )
                            }
                        }
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
                        if let meta = viewModel?.metadata,
                           let prov = self.providerRegistry.primaryProvider {
                            self.lastPlayedItem = PlexMediaMapper.item(
                                meta,
                                providerID: prov.id,
                                serverURL: serverURL,
                                authToken: token
                            )
                        }
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

    /// Get art and poster images for the player loading screen (from cache or fetch).
    /// Part of the player-launch escape hatch cluster — takes PlexMetadata because
    /// playerHeroBackdropRequest needs the resolved metadata.
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
        activity.userInfo = ["ratingKey": currentItem.ref.itemID]
        activity.targetContentIdentifier = "rivulet://detail?ratingKey=\(currentItem.ref.itemID)"
        activity.becomeCurrent()
        browseActivity = activity

        // Initialize watched state
        isWatched = currentItem.userState.isPlayed

        // Initialize progress for animation
        displayedProgress = effectiveWatchProgress ?? 0

        // detail + refreshHeroBackdropAssets are handled by the
        // ungated .task(id: detailLoadTaskID) above so they fire during
        // the entry animation and land before the text fade. By the time
        // we reach here, detail is already populated.

        // Load type-specific data — run independent calls in parallel
        // where possible so the total wall-clock time is the slowest
        // single call, not the sum.
        switch currentItem.kind {
        case .movie:
            // Collection + recommendations are independent of each other
            async let collectionTask: Void = {
                // TODO(post-wave-1): collectionItems returns [] for Wave 1; skip fetch
                // Collection name comes from detail?.collections, but we need a library
                // context to call collectionItems(matching:in:) — not available yet.
                _ = detail?.collections
            }()
            async let recommendTask: Void = loadRecommendedItems()
            _ = await (collectionTask, recommendTask)

        case .show:
            // Seasons and all-episodes are independent network calls
            async let seasonsTask: Void = loadSeasons()
            async let episodesTask: Void = loadAllEpisodes()
            async let nextUpTask: Void = loadNextUpEpisode()
            _ = await (seasonsTask, episodesTask, nextUpTask)

        case .season:
            async let seasonsTask: Void = loadSeasonsForCurrentSeason()
            async let episodesTask: Void = loadEpisodesForSeason()
            async let nextUpTask: Void = loadNextUpEpisode()
            _ = await (seasonsTask, episodesTask, nextUpTask)

        case .episode:
            async let seasonsTask: Void = loadSeasonsForEpisode()
            async let episodesTask: Void = loadAllEpisodes()
            _ = await (seasonsTask, episodesTask)

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

        // Episode thumbnails (first ~8 visible in the horizontal scroll).
        // MediaItem.artwork.thumbnail is already a fully-constructed URL.
        let visibleEpisodes = Array(unifiedEpisodes.prefix(8)) + Array(episodes.prefix(8))
        for ep in visibleEpisodes {
            if let url = ep.artwork.thumbnail ?? ep.artwork.poster {
                urls.append(url)
            }
        }

        // Recommendation / collection poster thumbnails (first ~6)
        let posterItems = Array(recommendedItems.prefix(6)) + Array(collectionItems.prefix(6))
        for mi in posterItems {
            if let url = mi.artwork.thumbnail ?? mi.artwork.poster {
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

    /// Fetch detail via provider (or fallback metadataSource). Also pre-warms stream URL.
    private func loadDetail() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        let ratingKey = currentItem.ref.itemID
        isLoadingExtras = true

        if let prov = provider {
            do {
                let d = try await prov.fullDetail(for: currentItem.ref)
                detail = d
                // TODO(post-wave-1): pre-warm stream URL via provider.resolveStream(for:)
                // MediaSource no longer exposes a Plex part key — keep this as a no-op for now.
                _ = serverURL; _ = token
            } catch {
                print("[MediaDetailView] provider.fullDetail failed: \(error)")
            }
        } else if let metaSrc = metadataSource {
            do {
                detail = try await metaSrc.itemDetail(currentItem.ref)
            } catch {
                print("[MediaDetailView] metadataSource.itemDetail failed: \(error)")
            }
        }

        isLoadingExtras = false
        _ = ratingKey
    }

    private func syncHeroBackdrop() {
        let request = currentHeroBackdropRequest()
        heroBackdrop.load(request: request, motionLocked: heroBackdropMotionLocked)
    }

    /// Re-syncs the hero backdrop after detail has loaded. For episodes
    /// and seasons, also fetches the parent show's metadata so its `clearLogo`
    /// can be folded into the request.
    private func refreshHeroBackdropAssets() async {
        if currentItem.kind == .episode || currentItem.kind == .season {
            await loadParentShowLogoPath()
        }
        syncHeroBackdrop()
    }

    private func currentHeroBackdropRequest() -> HeroBackdropRequest? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }

        // Build a HeroBackdropRequest from the MediaItem's artwork URLs.
        // detail.item has fresher data when available; fall back to currentItem.
        let sourceItem = detail?.item ?? currentItem
        let backdropURL = sourceItem.artwork.backdrop
        let thumbURL = sourceItem.artwork.thumbnail ?? sourceItem.artwork.poster
        let logoURL = sourceItem.artwork.logo.flatMap { url -> URL? in
            // Logo path stored as relative in artwork.logo? No — it's already a URL.
            return url
        }

        // For episodes/seasons, grandparentArtwork carries the show backdrop.
        let effectiveBackdrop = backdropURL
            ?? sourceItem.grandparentArtwork?.backdrop
            ?? sourceItem.parentArtwork?.backdrop

        // parentShowLogoPath is a Plex-relative path; convert to URL if present.
        var effectiveLogoURL = logoURL
        if let logoPath = parentShowLogoPath,
           let url = URL(string: "\(serverURL)\(logoPath)?X-Plex-Token=\(token)") {
            effectiveLogoURL = url
        }

        return HeroBackdropRequest(
            cacheKey: currentItem.ref.itemID,
            backdropURL: effectiveBackdrop,
            thumbnailURL: thumbURL,
            logoURL: effectiveLogoURL
        )
    }

    private func playerHeroBackdropRequest(for metadata: PlexMetadata) -> HeroBackdropRequest? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }

        let backdropSource = (metadata.type == "episode" && selectedEpisodeItem != nil) ? currentItem : nil
        if let plexMeta = backdropSource {
            // currentItem is a MediaItem — build from artwork
            let backdropURL = plexMeta.artwork.backdrop ?? plexMeta.grandparentArtwork?.backdrop
            let thumbURL = plexMeta.artwork.thumbnail ?? plexMeta.artwork.poster
            var effectiveLogoURL: URL? = nil
            if let logoPath = parentShowLogoPath,
               let url = URL(string: "\(serverURL)\(logoPath)?X-Plex-Token=\(token)") {
                effectiveLogoURL = url
            }
            return HeroBackdropRequest(
                cacheKey: plexMeta.ref.itemID,
                backdropURL: backdropURL,
                thumbnailURL: thumbURL,
                logoURL: effectiveLogoURL
            )
        }

        let thumbPath = metadata.thumb ?? metadata.bestThumb
        let thumbURL = thumbPath.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }
        let backdropURL = metadata.bestArt.flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(token)") }
        return HeroBackdropRequest(
            cacheKey: metadata.ratingKey ?? currentItem.ref.itemID,
            backdropURL: backdropURL,
            thumbnailURL: thumbURL,
            logoURL: nil
        )
    }

    /// Fetches the parent show's full metadata (using the cached copy when
    /// fresh) and extracts its clearLogo path, summary, and tagline for use
    /// on episode/season views. The summary is needed as a fallback for
    /// season detail pages because Plex's season metadata often returns an
    /// empty summary (notably for single-season shows surfaced via the
    /// "Recently Added" hub, which collapses show → season).
    private func loadParentShowLogoPath() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let showRatingKey = relatedShowRatingKey else {
            return
        }

        if let cached = PlexDataStore.shared.getCachedFullMetadata(for: showRatingKey),
           PlexDataStore.shared.isFullMetadataFresh(for: showRatingKey) {
            parentShowLogoPath = cached.clearLogoPath
            parentShowSummary = cached.summary
            parentShowTagline = cached.tagline
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
            parentShowSummary = showMetadata.summary
            parentShowTagline = showMetadata.tagline
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
            let plexItems = try await networkManager.getCollectionItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: sectionId,
                collectionId: collectionId,
                excludeRatingKey: currentItem.ref.itemID
            )
            // Convert [PlexMetadata] → [MediaItem]
            guard let prov = providerRegistry.primaryProvider else { return }
            collectionItems = plexItems.map { meta in
                PlexMediaMapper.item(meta, providerID: prov.id, serverURL: serverURL, authToken: token)
            }
            collectionName = name
        } catch {
            print("Failed to load collection items: \(error)")
        }
    }

    private func loadRecommendedItems() async {
        // Fetch recommendations via the provider when available.
        // TODO(post-wave-1): replace PersonalizedRecommendationService with provider.relatedItems
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let ratingKey = currentItem.ref.itemID
        do {
            // Build a minimal PlexMetadata shell for the recommendation service
            let shellMeta = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            let plexItems = try await recommendationService.recommendationsForItem(shellMeta, blendWithHistory: true, limit: 12)
            // Convert [PlexMetadata] → [MediaItem] so state stays agnostic
            guard let prov = providerRegistry.primaryProvider else { return }
            recommendedItems = plexItems.map { meta in
                PlexMediaMapper.item(meta, providerID: prov.id, serverURL: serverURL, authToken: token)
            }
        } catch {
            print("Failed to load recommended items: \(error)")
        }
    }

    /// Determine the "next up" episode for the Play button on TV shows and seasons.
    /// Uses detail?.nextEpisode if available, otherwise falls back to first unwatched episode.
    /// All state is MediaItem; no PlexMetadata involved.
    private func loadNextUpEpisode() async {
        // For seasons, find the next up episode from the loaded episodes
        if currentItem.kind == .season {
            await loadNextUpEpisodeForSeason()
            return
        }

        guard currentItem.kind == .show else { return }

        // 1. Try detail?.nextEpisode — already a MediaItem
        if let nextItem = detail?.nextEpisode {
            nextUpEpisode = nextItem
            return
        }

        // 2. Search unifiedEpisodes (already [MediaItem]) for in-progress or unwatched
        if !unifiedEpisodes.isEmpty {
            nextUpEpisode = unifiedEpisodes.first(where: { $0.isInProgress })
                ?? unifiedEpisodes.first(where: { !$0.isWatched })
                ?? unifiedEpisodes.first
            return
        }

        // 3. Fallback: per-season provider calls (unifiedEpisodes not yet loaded)
        guard let prov = provider else { return }
        for season in seasons {
            do {
                let seasonEpisodes = try await prov.children(of: season.ref)
                if let ep = seasonEpisodes.first(where: { $0.isInProgress })
                         ?? seasonEpisodes.first(where: { !$0.isWatched }) {
                    nextUpEpisode = ep
                    return
                }
            } catch {
                print("Failed to load episodes for season: \(error)")
            }
        }

        // 4. All episodes watched — fall back to first episode of first season
        if let firstSeason = seasons.first {
            do {
                let seasonEpisodes = try await prov.children(of: firstSeason.ref)
                nextUpEpisode = seasonEpisodes.first
            } catch {
                print("Failed to load first episode: \(error)")
            }
        }
    }

    /// Determine the "next up" episode for seasons.
    ///
    /// Prefers `detail.nextEpisode` (Plex's OnDeck-derived hint, populated
    /// by `loadDetail` before this runs) over scanning the `episodes` list.
    /// `loadDetailData()` schedules `loadEpisodesForSeason()` and
    /// `loadNextUpEpisode()` as parallel `async let`s, so `episodes` is
    /// often still empty when this runs — without the detail.nextEpisode
    /// fallback `nextUpEpisode` would stay nil and the Play button would
    /// remain `.disabled`. This mirrors the show-case logic in
    /// `loadNextUpEpisode()`.
    private func loadNextUpEpisodeForSeason() async {
        if let nextItem = detail?.nextEpisode {
            nextUpEpisode = nextItem
            return
        }
        nextUpEpisode = episodes.first(where: { $0.isInProgress })
            ?? episodes.first(where: { !$0.isWatched })
            ?? episodes.first
    }

    private func loadAndPlayTrailer() async {
        // detail?.trailerURL is a playable URL. We need a PlexMetadata for
        // UniversalPlayerView (escape hatch). Extract the ratingKey from the
        // Plex trailer URL path (/library/metadata/{key}/extras/…) and fetch.
        // TODO(post-wave-1): stream trailer directly via trailerURL without this fetch.
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let trailerURL = detail?.trailerURL else { return }

        let path = trailerURL.path
        let components = path.split(separator: "/")
        if let metaIndex = components.firstIndex(of: "metadata"),
           metaIndex + 1 < components.endIndex {
            let ratingKey = String(components[metaIndex + 1])
            do {
                // Escape hatch: resolve to PlexMetadata for UniversalPlayerView
                let metadata = try await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                playerPlexMeta = metadata
                showTrailerPlayer = true
            } catch {
                print("Failed to load trailer metadata: \(error)")
            }
        }
    }

    private func toggleWatched() async {
        let ratingKey = currentItem.ref.itemID

        do {
            if isWatched {
                if let prov = provider {
                    try await prov.markUnplayed(currentItem.ref)
                } else if let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken {
                    try await networkManager.markUnwatched(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                }
                isWatched = false
                // Mirror MediaItemContextMenu's behaviour: update the
                // PlexDataStore cache so when this view re-mounts (back
                // out and back in) `item.userState.isPlayed` reads the
                // post-toggle state rather than reverting to stale cache.
                PlexDataStore.shared.updateItemWatchStatus(ratingKey: ratingKey, watched: false)
            } else {
                if let prov = provider {
                    try await prov.markPlayed(currentItem.ref)
                } else if let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken {
                    try await networkManager.markWatched(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                }
                // Animate progress bar to 100% before marking as watched
                withAnimation(.easeOut(duration: 0.5)) {
                    displayedProgress = 1.0
                }
                // After animation, mark as watched and hide progress
                try? await Task.sleep(nanoseconds: 500_000_000)
                isWatched = true
                PlexDataStore.shared.updateItemWatchStatus(ratingKey: ratingKey, watched: true)
            }
            // Notify home screen to refresh Continue Watching
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            // Notify any parent MediaDetailView hosting this item in an
            // episode carousel so it can refresh its in-memory episode
            // array. Without this, navigating back from an
            // episode-detail-page-after-toggle reveals the parent show's
            // carousel still showing the pre-toggle watched state.
            NotificationCenter.default.post(
                name: .episodeWatchedStatusChanged,
                object: nil,
                userInfo: ["ratingKey": ratingKey, "watched": isWatched]
            )
        } catch {
            print("Failed to toggle watched status: \(error)")
        }
    }

    // MARK: - Episode Navigation

    /// Navigate to the parent season of the current episode
    private func navigateToParentSeason() async {
        guard let seasonRef = currentItem.parentRef else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            if let prov = provider {
                let d = try await prov.fullDetail(for: seasonRef)
                navigateToSeason = d.item
            } else if let serverURL = authManager.selectedServerURL,
                      let token = authManager.selectedServerToken {
                let seasonMetadata = try await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonRef.itemID
                )
                let prov0 = providerRegistry.primaryProvider
                navigateToSeason = prov0.map {
                    PlexMediaMapper.item(seasonMetadata, providerID: $0.id,
                                        serverURL: serverURL, authToken: token)
                }
            }
        } catch {
            print("Failed to load season metadata: \(error)")
        }
    }

    /// Navigate to the parent show of the current episode
    private func navigateToParentShow() async {
        guard let showRef = currentItem.grandparentRef else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            if let prov = provider {
                let d = try await prov.fullDetail(for: showRef)
                navigateToShow = d.item
            } else if let serverURL = authManager.selectedServerURL,
                      let token = authManager.selectedServerToken {
                let showMetadata = try await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: showRef.itemID
                )
                let prov0 = providerRegistry.primaryProvider
                navigateToShow = prov0.map {
                    PlexMediaMapper.item(showMetadata, providerID: $0.id,
                                        serverURL: serverURL, authToken: token)
                }
            }
        } catch {
            print("Failed to load show metadata: \(error)")
        }
    }

    /// Navigate to the parent show from a season (season's parent is the show)
    private func navigateToParentShowFromSeason() async {
        guard let showRef = currentItem.parentRef else { return }

        isLoadingNavigation = true
        defer { isLoadingNavigation = false }

        do {
            if let prov = provider {
                let d = try await prov.fullDetail(for: showRef)
                navigateToShow = d.item
            } else if let serverURL = authManager.selectedServerURL,
                      let token = authManager.selectedServerToken {
                let showMetadata = try await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: showRef.itemID
                )
                let prov0 = providerRegistry.primaryProvider
                navigateToShow = prov0.map {
                    PlexMediaMapper.item(showMetadata, providerID: $0.id,
                                        serverURL: serverURL, authToken: token)
                }
            }
        } catch {
            print("Failed to load show metadata: \(error)")
        }
    }

    private func loadSeasons() async {
        guard let prov = provider else { return }
        isLoadingSeasons = true
        do {
            let fetchedSeasons = try await prov.children(of: currentItem.ref)
            seasons = fetchedSeasons
            selectedSeason = fetchedSeasons.first
        } catch {
            print("Failed to load seasons: \(error)")
        }
        isLoadingSeasons = false
    }

    /// Load seasons when viewing an episode — displays the parent show's seasons inline.
    private func loadSeasonsForEpisode() async {
        guard let prov = provider,
              let showRef = currentItem.grandparentRef else { return }
        isLoadingSeasons = true
        do {
            let fetchedSeasons = try await prov.children(of: showRef)
            seasons = fetchedSeasons
            // Select the season this episode belongs to
            let currentSeasonID = currentItem.parentRef?.itemID
            selectedSeason = fetchedSeasons.first(where: { $0.ref.itemID == currentSeasonID })
                ?? fetchedSeasons.first
        } catch {
            print("Failed to load seasons for episode: \(error)")
        }
        isLoadingSeasons = false
    }

    /// Load sibling seasons when viewing a season so single-season shows can
    /// keep the season-pill header pattern instead of falling back to `Episodes`.
    private func loadSeasonsForCurrentSeason() async {
        guard let prov = provider,
              let showRef = currentItem.parentRef else { return }
        isLoadingSeasons = true
        do {
            let fetchedSeasons = try await prov.children(of: showRef)
            seasons = fetchedSeasons
            let currentSeasonID = currentItem.ref.itemID
            selectedSeason = fetchedSeasons.first(where: { $0.ref.itemID == currentSeasonID })
                ?? fetchedSeasons.first
        } catch {
            print("Failed to load sibling seasons for season detail: \(error)")
        }
        isLoadingSeasons = false
    }

    /// Load all episodes across all seasons (single provider call).
    private func loadAllEpisodes() async {
        guard let prov = provider else { return }

        let showRef: MediaItemRef
        if currentItem.kind == .show {
            showRef = currentItem.ref
        } else if currentItem.kind == .episode, let grandRef = currentItem.grandparentRef {
            showRef = grandRef
        } else {
            return
        }

        isLoadingEpisodes = true
        do {
            let allEps = try await prov.allEpisodes(of: showRef)
            unifiedEpisodes = allEps

            // When opened from a specific episode, scroll to it.
            if currentItem.kind == .episode {
                let targetKey = currentItem.ref.itemID
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                episodeScrollTarget = targetKey
            }
        } catch {
            print("Failed to load all episodes: \(error)")
        }
        isLoadingEpisodes = false
    }

    /// Load episodes for a season using provider.children.
    /// - Parameter season: The season MediaItem whose episodes to load.
    /// - Parameter crossfade: When true, crossfades rather than showing a loader.
    private func loadEpisodes(for season: MediaItem, crossfade: Bool = false) async {
        guard let prov = provider else { return }
        if !crossfade { isLoadingEpisodes = true }
        do {
            let fetched = try await prov.children(of: season.ref)
            if crossfade {
                withAnimation(.easeInOut(duration: 0.35)) { episodes = fetched }
            } else {
                episodes = fetched
            }
        } catch {
            print("Failed to load episodes: \(error)")
        }
        isLoadingEpisodes = false
    }

    /// Load episodes when viewing a season directly.
    private func loadEpisodesForSeason() async {
        guard let prov = provider else { return }
        isLoadingEpisodes = true
        do {
            episodes = try await prov.children(of: currentItem.ref)
        } catch {
            print("Failed to load episodes for season: \(error)")
        }
        isLoadingEpisodes = false
    }

    /// Update the in-memory `episodes` / `unifiedEpisodes` arrays' watched
    /// state for a single rating key, mirroring what `markPlayed`/`markUnplayed`
    /// would have produced server-side. Used by the
    /// `episodeWatchedStatusChanged` notification observer so a child
    /// MediaDetailView's toggle propagates back up to this carousel.
    private func applyEpisodeWatchedStatusUpdate(ratingKey: String, watched: Bool) {
        func updated(_ original: MediaItem) -> MediaItem {
            let newState = MediaUserState(
                isPlayed: watched,
                viewOffset: 0,
                isFavorite: original.userState.isFavorite,
                lastViewedAt: watched ? Date() : original.userState.lastViewedAt
            )
            return MediaItem(
                ref: original.ref,
                kind: original.kind,
                title: original.title,
                sortTitle: original.sortTitle,
                overview: original.overview,
                year: original.year,
                runtime: original.runtime,
                parentRef: original.parentRef,
                grandparentRef: original.grandparentRef,
                episodeNumber: original.episodeNumber,
                seasonNumber: original.seasonNumber,
                childProgress: original.childProgress,
                userState: newState,
                artwork: original.artwork,
                parentArtwork: original.parentArtwork,
                grandparentArtwork: original.grandparentArtwork
            )
        }
        if let idx = episodes.firstIndex(where: { $0.ref.itemID == ratingKey }) {
            episodes[idx] = updated(episodes[idx])
        }
        if let idx = unifiedEpisodes.firstIndex(where: { $0.ref.itemID == ratingKey }) {
            unifiedEpisodes[idx] = updated(unifiedEpisodes[idx])
        }
    }

    /// Refresh a single episode's watch status without reloading the entire list.
    /// Uses provider.fullDetail to get fresh data, then patches the arrays in place.
    private func refreshEpisodeWatchStatus(itemID: String) async {
        guard let prov = provider else { return }
        let ref = MediaItemRef(providerID: currentItem.ref.providerID, itemID: itemID)
        do {
            let d = try await prov.fullDetail(for: ref)
            let updated = d.item
            if let idx = episodes.firstIndex(where: { $0.ref.itemID == itemID }) {
                episodes[idx] = updated
            }
            if let idx = unifiedEpisodes.firstIndex(where: { $0.ref.itemID == itemID }) {
                unifiedEpisodes[idx] = updated
            }
        } catch {
            print("Failed to refresh episode watch status: \(error)")
        }
    }

    // MARK: - Below-fold Row Helpers (extracted for Swift type-checker)

    @ViewBuilder
    private var recommendedRow: some View {
        if !recommendedItems.isEmpty {
            MediaItemAgnosticRow(
                title: "Related",
                items: recommendedItems,
                onItemSelected: { selected in
                    withAnimation(.easeInOut(duration: 0.35)) {
                        displayedItem = selected
                    }
                }
            )
            .padding(.top, 32)
        }
    }

    @ViewBuilder
    private var collectionRow: some View {
        if !collectionItems.isEmpty, let name = collectionName {
            MediaItemAgnosticRow(
                title: name,
                items: collectionItems,
                onItemSelected: { selected in
                    withAnimation(.easeInOut(duration: 0.35)) {
                        displayedItem = selected
                    }
                }
            )
            .padding(.top, 32)
        }
    }

    @ViewBuilder
    private var castCrewRow: some View {
        if let d = detail, (!d.cast.isEmpty || !d.directors.isEmpty) {
            CastCrewRow(
                cast: d.cast,
                directors: d.directors
            )
            .padding(.top, 32)
        }
    }

    // MARK: - URL Helpers

    /// Poster URL - uses grandparent poster for episodes (series poster)
    private var posterURL: URL? {
        // For TV show episodes/seasons, prefer the series poster (grandparentArtwork)
        if currentItem.kind == .episode || currentItem.kind == .season {
            return currentItem.grandparentArtwork?.poster
                ?? currentItem.parentArtwork?.poster
                ?? currentItem.artwork.poster
        }
        return currentItem.artwork.poster
    }

    private var thumbURL: URL? {
        return currentItem.artwork.thumbnail ?? currentItem.artwork.poster
    }
}

// MARK: - Season Poster Bar (tvOS)

/// Season poster card for the horizontal bar. Click selects, focus only highlights.
struct SeasonBarCard: View {
    let season: MediaItem
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }
    private var titleSize: CGFloat { ScaledDimensions.posterTitleSize * scale }

    @FocusState private var isFocused: Bool

    private var isFullyWatched: Bool {
        guard let cp = season.childProgress, cp.total > 0 else { return false }
        return cp.played >= cp.total
    }

    private var seasonLabel: String {
        if let n = season.seasonNumber {
            return n == 0 ? "Specials" : "Season \(n)"
        }
        return season.title
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 10) {
                posterImage
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay(alignment: .topTrailing) {
                        if isFullyWatched { WatchedCornerTag() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? .white : .clear, lineWidth: 3)
                    )

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
        CachedAsyncImage(url: season.artwork.thumbnail ?? season.artwork.poster) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .empty:
                Rectangle().fill(Color(white: 0.15))
                    .overlay { ProgressView().tint(.white.opacity(0.3)) }
            case .failure:
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Image(systemName: "number.square")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }
}

/// Horizontal scrollable row of season poster cards. Click-to-select only.
struct SeasonPosterBar: View {
    let seasons: [MediaItem]
    @Binding var selectedSeason: MediaItem?
    let onSeasonSelected: (MediaItem) -> Void

    @FocusState private var focusedSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(seasons, id: \.ref.itemID) { season in
                        SeasonBarCard(
                            season: season,
                            isSelected: selectedSeason?.ref.itemID == season.ref.itemID,
                            onSelect: {
                                selectedSeason = season
                                onSeasonSelected(season)
                            }
                        )
                        .focused($focusedSeasonId, equals: season.ref.itemID)
                        .id(season.ref.itemID)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
            .scrollClipDisabled()
            .focusSection()
            .remembersFocus(key: "seasonPosters", focusedId: $focusedSeasonId)
            .onChange(of: selectedSeason?.ref.itemID) { _, newKey in
                guard let key = newKey else { return }
                withAnimation { proxy.scrollTo(key, anchor: .center) }
            }
        }
    }
}


// MARK: - Season Poster Card

struct SeasonPosterCard: View {
    let season: MediaItem
    let isSelected: Bool
    var focusedSeasonId: FocusState<String?>.Binding?
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }
    private var titleSize: CGFloat { ScaledDimensions.posterTitleSize * scale }
    private var subtitleSize: CGFloat { ScaledDimensions.posterSubtitleSize * scale }

    private var isFullyWatched: Bool {
        guard let cp = season.childProgress, cp.total > 0 else { return false }
        return cp.played >= cp.total
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .center, spacing: 12) {
                posterImage
                    .frame(width: posterWidth, height: posterHeight)
                    .overlay(alignment: .topTrailing) {
                        if isFullyWatched { WatchedCornerTag() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 4)
                    )
                    .hoverEffect(.highlight)
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
                    .padding(.bottom, 10)

                VStack(spacing: 4) {
                    Text(seasonLabel)
                        .font(.system(size: titleSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))

                    if let cp = season.childProgress {
                        Text("\(cp.total) episodes")
                            .font(.system(size: subtitleSize))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .modifier(SeasonFocusModifier(focusedSeasonId: focusedSeasonId, seasonItemID: season.ref.itemID))
    }

    private var seasonLabel: String {
        if let n = season.seasonNumber {
            return String(format: "Season %02d", n)
        }
        return season.title
    }

    private var posterImage: some View {
        CachedAsyncImage(url: season.artwork.thumbnail ?? season.artwork.poster) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .empty:
                Rectangle().fill(Color(white: 0.15))
                    .overlay { ProgressView().tint(.white.opacity(0.3)) }
            case .failure:
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Image(systemName: "number.square")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
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
    let seasons: [MediaItem]
    @Binding var selectedSeason: MediaItem?
    let onSeasonSelected: (MediaItem) -> Void

    @FocusState private var focusedSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(seasons, id: \.ref.itemID) { season in
                        let isSelected = selectedSeason?.ref.itemID == season.ref.itemID
                        SeasonPillButton(
                            label: seasonLabel(for: season),
                            isSelected: isSelected,
                            action: {
                                selectedSeason = season
                                onSeasonSelected(season)
                            }
                        )
                        .focused($focusedSeasonId, equals: season.ref.itemID)
                        .id(season.ref.itemID)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
            .focusSection()
            .onAppear {
                guard let key = selectedSeason?.ref.itemID else { return }
                DispatchQueue.main.async { proxy.scrollTo(key, anchor: .center) }
            }
            .onChange(of: selectedSeason?.ref.itemID) { _, newKey in
                guard let newKey else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(newKey, anchor: .center) }
            }
        }
    }

    private func seasonLabel(for season: MediaItem) -> String {
        if let n = season.seasonNumber {
            return n == 0 ? "Specials" : "Season \(n)"
        }
        return season.title
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
    let episode: MediaItem
    let serverURL: String
    let authToken: String
    var focusedEpisodeId: FocusState<String?>.Binding?
    var showSeasonPrefix: Bool = false
    let onPlay: () -> Void
    var onRefreshNeeded: MediaItemRefreshCallback? = nil
    var onShowInfo: MediaItemNavigationCallback? = nil

    @FocusState private var thumbnailFocused: Bool
    @FocusState private var descriptionFocused: Bool
    @Namespace private var cardFocus
    @AppStorage("hideSpoilersForUnwatched") private var hideSpoilersForUnwatched = false

    private let cardWidth: CGFloat = 340
    private let thumbHeight: CGFloat = 192

    /// True when either sub-button has focus. Drives the whole-card scale-up
    /// so the card grows as a unit when it gains focus, regardless of which
    /// sub-button the user lands on.
    private var isFocused: Bool { thumbnailFocused || descriptionFocused }

    /// True when this episode should be blurred to avoid spoilers: setting
    /// is on and the episode hasn't been watched to completion. Matches
    /// Infuse — in-progress episodes stay blurred until fully watched.
    private var blurForSpoilers: Bool {
        hideSpoilersForUnwatched && !episode.isWatched
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Thumbnail — clicking plays. Default focus when entering the
            // card, so left/right between cards always lands here even if
            // the previous card had focus on its description.
            Button(action: onPlay) {
                CachedAsyncImage(url: episode.artwork.thumbnail ?? episode.artwork.poster) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        Rectangle().fill(Color(white: 0.15))
                            .overlay { ProgressView().tint(.white.opacity(0.3)) }
                    case .failure:
                        Rectangle().fill(Color(white: 0.15))
                            .overlay { Image(systemName: "play.rectangle").foregroundStyle(.white.opacity(0.3)) }
                    }
                }
                .frame(width: cardWidth, height: thumbHeight)
                .clipped()
                .blur(radius: blurForSpoilers ? 18 : 0)
                .overlay(alignment: .bottomLeading) {
                    if let duration = episode.durationFormatted {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 10))
                            Text(duration).font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
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
                    if episode.isWatched {
                        WatchedCornerTag(cornerRadius: 8)
                            .accessibilityLabel("Watched")
                    }
                }
                .overlay(
                    Rectangle()
                        .strokeBorder(.white, lineWidth: thumbnailFocused ? 4 : 0)
                )
            }
            .buttonStyle(.plain)
            .focused($thumbnailFocused)
            .prefersDefaultFocus(in: cardFocus)
            .focusEffectDisabled()
            .hoverEffectDisabled()

            // Description — clicking opens the episode detail page so the
            // user can read the full synopsis and pre-play track pickers.
            // Disabled (and unfocusable) when no info callback is wired.
            Button(action: { onShowInfo?() }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(episodeLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(descriptionFocused ? .black.opacity(0.6) : .white.opacity(0.6))
                        .textCase(.uppercase)
                        .padding(.top, 10)

                    Text(episode.title.isEmpty ? "Episode" : episode.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(descriptionFocused ? .black : .white)
                        .lineLimit(1)

                    if let summary = episode.overview, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 16))
                            .foregroundStyle(descriptionFocused ? .black.opacity(0.7) : .white.opacity(0.7))
                            .lineLimit(3)
                            .padding(.top, 1)
                            .blur(radius: blurForSpoilers ? 6 : 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(descriptionFocused ? Color.white.opacity(0.85) : Color.clear)
            }
            .buttonStyle(.plain)
            .focused($descriptionFocused)
            .disabled(onShowInfo == nil)
            .focusEffectDisabled()
            .hoverEffectDisabled()
        }
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .focusSection()
        .focusScope(cardFocus)
        .modifier(EpisodeFocusModifier(focusedEpisodeId: focusedEpisodeId, episodeItemID: episode.ref.itemID))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .mediaItemContextMenu(
            mediaItem: episode,
            serverURL: serverURL,
            authToken: authToken,
            source: .other,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo
        )
    }

    private var episodeLabel: String {
        if showSeasonPrefix, let epString = episode.episodeString { return epString }
        if let n = episode.episodeNumber { return "Episode \(n)" }
        return episode.episodeString ?? "Episode"
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: MediaItem
    let serverURL: String
    let authToken: String
    var isCurrent: Bool = false
    var focusedEpisodeId: FocusState<String?>.Binding?
    let onPlay: () -> Void
    var onPlayFromBeginning: (() -> Void)? = nil
    var onRefreshNeeded: MediaItemRefreshCallback? = nil
    var onShowInfo: MediaItemNavigationCallback? = nil

    @FocusState private var isFocused: Bool
    @AppStorage("hideSpoilersForUnwatched") private var hideSpoilersForUnwatched = false

    /// True when this episode should be blurred to avoid spoilers: setting
    /// is on and the episode hasn't been watched to completion. Matches
    /// Infuse — in-progress episodes stay blurred until fully watched.
    private var blurForSpoilers: Bool {
        hideSpoilersForUnwatched && !episode.isWatched
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 16) {
                CachedAsyncImage(url: episode.artwork.thumbnail ?? episode.artwork.poster) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        Rectangle().fill(Color.gray.opacity(0.3))
                            .overlay { Image(systemName: "play.rectangle").foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .blur(radius: blurForSpoilers ? 18 : 0)
                .overlay(alignment: .bottom) {
                    if let progress = episode.watchProgress, progress > 0 && progress < 1 {
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.5))
                            Color.blue.scaleEffect(x: progress, anchor: .leading)
                        }
                        .frame(height: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    if let epString = episode.episodeString {
                        Text(epString).font(.system(size: 26)).foregroundStyle(.secondary)
                    }
                    Text(episode.title.isEmpty ? "Episode" : episode.title)
                        .font(.system(size: 30, weight: .medium)).lineLimit(1)
                    if let duration = episode.durationFormatted {
                        Text(duration).font(.system(size: 26)).foregroundStyle(.secondary)
                    }
                    if let summary = episode.overview, !summary.isEmpty {
                        Text(summary).font(.system(size: 26)).foregroundStyle(.secondary).lineLimit(2)
                            .blur(radius: blurForSpoilers ? 6 : 0)
                    }
                }

                Spacer()

                if isCurrent {
                    Text("VIEWING")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.blue))
                }

                if episode.isWatched {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 24))
                }
            }
            .padding(.vertical, 18).padding(.horizontal, 22)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isFocused ? .white.opacity(0.25) : .white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(CardButtonStyle())
        .focused($isFocused)
        .modifier(EpisodeFocusModifier(focusedEpisodeId: focusedEpisodeId, episodeItemID: episode.ref.itemID))
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .mediaItemContextMenu(
            mediaItem: episode,
            serverURL: serverURL,
            authToken: authToken,
            source: .other,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo
        )
    }
}

/// Helper modifier to apply focus binding to episode rows
struct EpisodeFocusModifier: ViewModifier {
    var focusedEpisodeId: FocusState<String?>.Binding?
    let episodeItemID: String

    func body(content: Content) -> some View {
        if let binding = focusedEpisodeId {
            content.focused(binding, equals: episodeItemID)
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

/// Helper modifier to apply focus binding to season cards
struct SeasonFocusModifier: ViewModifier {
    var focusedSeasonId: FocusState<String?>.Binding?
    let seasonItemID: String

    func body(content: Content) -> some View {
        if let binding = focusedSeasonId {
            content.focused(binding, equals: seasonItemID)
        } else {
            content
        }
    }
}



// MARK: - Player View Wrapper (non-tvOS)


#Preview {
    let sampleRef = MediaItemRef(providerID: "plex:preview", itemID: "123")
    let sampleMovie = MediaItem(
        ref: sampleRef,
        kind: .movie,
        title: "Sample Movie",
        sortTitle: nil,
        overview: "This is a sample movie summary that describes the plot and gives viewers an idea of what to expect.",
        year: 2024,
        runtime: 7200,
        parentRef: nil,
        grandparentRef: nil,
        episodeNumber: nil,
        seasonNumber: nil,
        childProgress: nil,
        userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
        artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
        parentArtwork: nil,
        grandparentArtwork: nil
    )

    MediaDetailView(item: sampleMovie)
}

// MARK: - MediaItem-based Poster Row

/// Horizontal poster card row backed by [MediaItem]. Replaces the Plex-typed
/// MediaItemRow for the recommended/collection rows inside MediaDetailView.
private struct MediaItemAgnosticRow: View {
    let title: String
    let items: [MediaItem]
    var onItemSelected: ((MediaItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: ScaledDimensions.sectionTitleSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: ScaledDimensions.rowItemSpacing) {
                    ForEach(items, id: \.ref.itemID) { item in
                        Button {
                            onItemSelected?(item)
                        } label: {
                            MediaItemAgnosticPosterCard(item: item)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, ScaledDimensions.rowVerticalPadding)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// Minimal poster card for MediaItem — shows artwork.poster (or backdrop fallback),
/// title, and watched corner tag. Used by MediaItemAgnosticRow.
private struct MediaItemAgnosticPosterCard: View {
    let item: MediaItem

    @Environment(\.uiScale) private var scale

    private var posterWidth: CGFloat { ScaledDimensions.posterWidth * scale }
    private var posterHeight: CGFloat { ScaledDimensions.posterHeight * scale }
    private var cornerRadius: CGFloat { ScaledDimensions.posterCornerRadius }

    var body: some View {
        CachedAsyncImage(url: item.artwork.poster ?? item.artwork.thumbnail) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .empty:
                Rectangle().fill(Color(white: 0.15))
                    .overlay { ProgressView().tint(.white.opacity(0.3)) }
            case .failure:
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                    .overlay { Image(systemName: "photo").foregroundStyle(.white.opacity(0.3)) }
            }
        }
        .frame(width: posterWidth, height: posterHeight)
        .overlay(alignment: .topTrailing) {
            if item.userState.isPlayed { WatchedCornerTag() }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .hoverEffect(.highlight)
    }
}

// MARK: - Navigation Destinations Modifier

/// Conditionally applies .navigationDestination modifiers.
/// Disabled in preview overlay flow (no NavigationStack ancestor).
private struct NavigationDestinationsModifier: ViewModifier {
    @Binding var navigateToSeason: MediaItem?
    @Binding var navigateToShow: MediaItem?
    @Binding var navigateToEpisode: MediaItem?
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .navigationDestination(item: $navigateToSeason) { season in
                    MediaDetailView(item: season)
                }
                .navigationDestination(item: $navigateToShow) { show in
                    MediaDetailView(item: show)
                }
                .navigationDestination(item: $navigateToEpisode) { episode in
                    MediaDetailView(item: episode)
                }
        } else {
            content
        }
    }
}
