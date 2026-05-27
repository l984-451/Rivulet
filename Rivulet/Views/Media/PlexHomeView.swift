//
//  PlexHomeView.swift
//  Rivulet
//
//  Home screen for Plex with Continue Watching and Recently Added
//

import SwiftUI
import Combine
import os.log

private let homeLog = Logger(subsystem: "com.rivulet.app", category: "PlexHome")

struct PlexHomeView: View {
    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var watchlistService = PlexWatchlistService.shared
    @AppStorage("showHomeHero") private var showHomeHero = false
    @AppStorage("enablePersonalizedRecommendations") private var enablePersonalizedRecommendations = false
    @Environment(\.nestedNavigationState) private var nestedNavState
    @State private var selectedItem: MediaItem?
    @State private var selectedMusicItem: PlexMetadata?   // music-only routing (artist/album)
    @State private var heroItems: [PlexMetadata] = []
    @State private var heroCurrentIndex: Int = 0
    @State private var cachedProcessedHubs: [PlexHub] = []  // Memoized to avoid recalculation on every render
    @State private var recommendations: [PlexMetadata] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationsError: String?
    @FocusState private var focusedItemId: String?  // Tracks focused item by "context:itemId" format
    @State private var rowPreviewRequest: PreviewRequest?
    @State private var previewRestoreTarget: PreviewSourceTarget?
    @State private var capturedSourceFrames: [PreviewSourceTarget: CGRect] = [:]
    @State private var showPreviewCover = false
    @State private var heroScrollOffset: CGFloat = 0

    // Resume-or-restart prompt for in-progress items launched directly from
    // Continue Watching / hero carousel (bypassing the detail view). Off
    // by default; the "Watch from Beginning" context-menu action bypasses
    // the prompt by passing `fromBeginning: true` to `playItemDirectly`.
    @AppStorage("promptResumeOrRestart") private var promptResumeOrRestart = false
    @State private var showResumeChoice = false
    @State private var resumeChoiceTimeMs: Int = 0
    @State private var resumeChoiceLaunch: ((_ playFromBeginning: Bool) -> Void)? = nil

    private let recommendationService = PersonalizedRecommendationService.shared
    private let recommendationsContentType: RecommendationContentType = .moviesAndShows

    // MARK: - Processed Hubs (merged Continue Watching + library-specific sections)

    /// Computes processed hubs with library-specific sections
    /// - Continue Watching comes from `dataStore.continueWatchingHub` (Plex's dedicated
    ///   `/hubs/continueWatching` endpoint, matching the Plex app exactly)
    /// - Other hubs come from library-specific endpoints with library name prefixes
    private func computeProcessedHubs(from hubsToProcess: [PlexHub]) -> [PlexHub] {
        var result: [PlexHub] = []

        if let hub = dataStore.continueWatchingHub, hub.Metadata?.isEmpty == false {
            result.append(hub)
        }

        // Add "Recently Added" hub for each library shown on Home (video and music)
        for library in dataStore.librariesForHomeScreen {
            if let hubs = dataStore.libraryHubs[library.key] {
                // Find the "Recently Added" hub for this library
                if let recentlyAddedHub = hubs.first(where: { isRecentlyAddedHub($0) }) {
                    var transformedHub = recentlyAddedHub
                    transformedHub.title = "Recently Added \(library.title)"
                    result.append(transformedHub)
                }
            }
        }

        return result
    }

    /// Check if a hub is a Continue Watching or On Deck hub
    private func isContinueWatchingHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return identifier.contains("continuewatching") ||
               identifier.contains("ondeck") ||
               title.contains("continue watching") ||
               title.contains("on deck")
    }

    /// Check if a hub is a Recently Added hub
    private func isRecentlyAddedHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return identifier.contains("recentlyadded") ||
               title.contains("recently added")
    }

    /// Transform generic hub titles to include library name
    private func transformHubTitle(_ hubTitle: String?, libraryName: String) -> String {
        guard let title = hubTitle else { return libraryName }

        let lowercasedTitle = title.lowercased()

        // Map common hub titles to library-specific versions
        switch lowercasedTitle {
        case "recently added":
            return "\(libraryName) added"
        case "recently released":
            return "\(libraryName) recently released"
        case "recommended":
            return "\(libraryName) recommended"
        case "new releases":
            return "\(libraryName) new releases"
        default:
            // For other hubs, check if library name is already included
            if lowercasedTitle.contains(libraryName.lowercased()) {
                return title
            }
            // Prepend library name for clarity
            return "\(libraryName) - \(title)"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if !authManager.hasCredentials {
                    notConnectedView
                } else if dataStore.isLoadingHubs && dataStore.hubs.isEmpty {
                    loadingView
                } else if let error = dataStore.hubsError, dataStore.hubs.isEmpty {
                    errorView(error)
                } else if dataStore.hubs.isEmpty {
                    emptyView
                } else {
                    contentView
                }
            }
            .refreshable {
                await dataStore.refreshHubs()
                await dataStore.refreshLibraryHubs()
                if enablePersonalizedRecommendations {
                    await refreshRecommendations(force: true)
                }
            }
            .onAppear {
                homeLog.info("PlexHomeView onAppear — cachedHubs=\(self.cachedProcessedHubs.count), dataStoreHubs=\(self.dataStore.hubs.count)")
                // Initial computation of processed hubs
                if cachedProcessedHubs.isEmpty && !dataStore.hubs.isEmpty {
                    cachedProcessedHubs = computeProcessedHubs(from: dataStore.hubs)
                    homeLog.info("Computed \(self.cachedProcessedHubs.count) processed hubs on appear, setting isHomeContentReady=\(!self.cachedProcessedHubs.isEmpty)")
                    dataStore.isHomeContentReady = !cachedProcessedHubs.isEmpty
                }
                // Only select hero if we don't have one yet
                if heroItems.isEmpty {
                    selectHeroItems()
                }
                if enablePersonalizedRecommendations && recommendations.isEmpty {
                    Task { await refreshRecommendations(force: false) }
                }
            }
            .task(id: dataStore.libraries.count) {
                // Load library-specific hubs for Home screen when libraries are available
                // Initialize Home visibility for libraries if not configured
                guard !dataStore.libraries.isEmpty else { return }
                dataStore.librarySettings.initializeHomeVisibility(for: dataStore.libraries)
            }
            .task {
                await watchlistService.fetchWatchlist()
            }
            .watchlistToast(message: watchlistService.transientWriteError)
            .onReceive(NotificationCenter.default.publisher(for: .libraryGUIDIndexDidUpdate)) { _ in
                // Index just (re)built; try to upgrade the hero now that we can
                // resolve TMDB ids against library content.
                Task { await upgradeHeroFromTMDB() }
            }
            .onChange(of: dataStore.hubsVersion) { _, _ in
                // Recompute cached hubs when global hub data changes (for Continue Watching)
                cachedProcessedHubs = computeProcessedHubs(from: dataStore.hubs)
                // Refresh hero items when hubs change; stable comparison prevents unnecessary rebuilds.
                selectHeroItems()
            }
            .onChange(of: dataStore.libraryHubsVersion) { _, _ in
                // Recompute when library-specific hubs change
                cachedProcessedHubs = computeProcessedHubs(from: dataStore.hubs)
            }
            .onChange(of: dataStore.librarySettings.librariesShownOnHome) { _, _ in
                // Recompute and reload when Home library selection changes
                cachedProcessedHubs = computeProcessedHubs(from: dataStore.hubs)
                Task { await dataStore.loadLibraryHubsIfNeeded() }
            }
            .onChange(of: cachedProcessedHubs.isEmpty) { _, isEmpty in
                homeLog.info("cachedProcessedHubs.isEmpty changed to \(isEmpty) (count: \(self.cachedProcessedHubs.count))")
                dataStore.isHomeContentReady = !isEmpty
            }
            .onChange(of: enablePersonalizedRecommendations) { _, _ in
                handleRecommendationsToggle()
            }
            // Refresh hubs when notified (e.g., after playback ends, watch status changes)
            .onReceive(NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)) { _ in
                Task {
                    await dataStore.refreshHubs()
                    await dataStore.refreshLibraryHubs()
                    if enablePersonalizedRecommendations {
                        await refreshRecommendations(force: true)
                    }
                }
            }
            .navigationDestination(item: $selectedItem) { item in
                MediaDetailView(item: item)
            }
            .navigationDestination(item: $selectedMusicItem) { item in
                switch item.type {
                case "artist": MusicSearchDetailRouter(plexMeta: item, kind: .artist)
                case "album": MusicSearchDetailRouter(plexMeta: item, kind: .album)
                default: EmptyView()
                }
            }
            .overlayPreferenceValue(PreviewSourceFramePreferenceKey.self) { anchors in
                // Resolve anchor frames into CGRects
                GeometryReader { proxy in
                    Color.clear
                        .hidden()
                        .task(id: anchors.count) {
                            capturedSourceFrames = Dictionary(uniqueKeysWithValues: anchors.map { ($0.key, proxy[$0.value]) })
                        }
                }
                .allowsHitTesting(false)
            }
            .onChange(of: showPreviewCover) { _, isShowing in
                if isShowing, let request = rowPreviewRequest {
                    presentPreview(request: request)
                }
            }
        }
        .onChange(of: selectedItem) { _, newValue in
            print("[PlexHome] selectedItem changed: \(newValue?.title ?? "nil") (itemID: \(newValue?.ref.itemID ?? "nil"))")
            updateNestedNavigationState()
        }
        // Resume-or-restart prompt for direct-play paths (Continue Watching
        // primary tap, hero carousel Play). Gated on the
        // `promptResumeOrRestart` setting; off by default. The "Watch from
        // Beginning" context-menu action bypasses by passing
        // `fromBeginning: true` to `playItemDirectly`.
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
        // Handle navigation from player (Go to Season / Go to Show)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToContent)) { notification in
            guard let ratingKey = notification.userInfo?["ratingKey"] as? String else { return }

            // Fetch metadata and navigate
            Task {
                do {
                    let metadata = try await PlexNetworkManager.shared.getMetadata(
                        serverURL: authManager.selectedServerURL ?? "",
                        authToken: authManager.selectedServerToken ?? "",
                        ratingKey: ratingKey
                    )
                    await MainActor.run {
                        selectItem(metadata)
                    }
                } catch {
                    print("❌ [Navigation] Failed to fetch metadata for ratingKey \(ratingKey): \(error)")
                }
            }
        }
    }

    // MARK: - Direct Playback (Continue Watching)

    /// Play an item directly without navigating to detail view.
    /// When the resume-or-restart prompt is enabled and the item is in
    /// progress (`fromBeginning == false` path), surfaces the chooser
    /// instead of going straight into playback. Callers that want to
    /// skip the prompt — e.g. the "Watch from Beginning" context-menu
    /// action — pass `fromBeginning: true`.
    private func playItemDirectly(_ item: PlexMetadata, fromBeginning: Bool = false) {
        if promptResumeOrRestart,
           !fromBeginning,
           item.isInProgress,
           let offsetMs = item.viewOffset, offsetMs > 0 {
            resumeChoiceTimeMs = offsetMs
            resumeChoiceLaunch = { fromBegin in
                presentPlayerForItem(item, fromBeginning: fromBegin)
            }
            showResumeChoice = true
        } else {
            presentPlayerForItem(item, fromBeginning: fromBeginning)
        }
    }

    /// Actually present the player for an item (no prompt). Split out from
    /// `playItemDirectly` so the resume-or-restart dialog can call back
    /// into the playback path without re-triggering the prompt.
    private func presentPlayerForItem(_ item: PlexMetadata, fromBeginning: Bool) {
        Task {
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }

            let (artImage, thumbImage) = await getPlayerImages(for: item, serverURL: serverURL, authToken: token)

            await MainActor.run {
                let resumeOffset: Double? = if fromBeginning {
                    nil
                } else {
                    item.viewOffset.map { Double($0) / 1000.0 }
                }

                let viewModel = UniversalPlayerViewModel(
                    metadata: item,
                    serverURL: serverURL,
                    authToken: token,
                    startOffset: resumeOffset != nil && resumeOffset! > 0 ? resumeOffset : nil,
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage
                )
                let useApplePlayer = UserDefaults.standard.bool(forKey: "useApplePlayer")
                let playerVC: UIViewController
                if useApplePlayer {
                    let nativePlayer = NativePlayerViewController(viewModel: viewModel)
                    nativePlayer.onDismiss = {
                        Task { await dataStore.refreshHubs() }
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
                    container.onDismiss = {
                        Task { await dataStore.refreshHubs() }
                    }
                    playerVC = container
                }

                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = scene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    topVC.present(playerVC, animated: true)
                }
            }
        }
    }

    /// Get art and poster images for the player loading screen
    private func getPlayerImages(for metadata: PlexMetadata, serverURL: String, authToken: String) async -> (UIImage?, UIImage?) {
        let request = metadata.heroBackdropRequest(
            serverURL: serverURL,
            authToken: authToken
        )
        return await HeroBackdropResolver.shared.playerLoadingImages(for: request)
    }

    // MARK: - Preview Presentation (UIKit Modal)

    private func presentPreview(request: PreviewRequest) {
        let menuBridge = PreviewMenuBridge()

        let previewContent = PreviewOverlayHost(
            request: request,
            sourceFrames: capturedSourceFrames,
            onDismiss: { [weak menuBridge] sourceTarget in
                _ = menuBridge  // prevent retain cycle warning
                previewRestoreTarget = sourceTarget
                // Find and dismiss the preview VC
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = scene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    if let previewVC = topVC as? PreviewContainerViewController {
                        previewVC.dismissPreview()
                    }
                }
            },
            menuBridge: menuBridge
        )

        // Preview is presented via UIKit `present(_:animated:)`, which creates
        // a hosting controller whose SwiftUI environment is NOT inherited from
        // PlexHomeView's tree. Re-inject the registries so MediaDetailView (and
        // anything else deeper) can resolve @Environment lookups.
        let contentWithRegistries = previewContent
            .environment(MediaProviderRegistry.shared)
            .environment(MusicProviderRegistry.shared)
            .environment(MetadataSourceRegistry.shared)

        let container = PreviewContainerViewController(
            content: contentWithRegistries,
            menuHandler: {
                menuBridge.triggerMenu()
            }
        )
        container.onDismiss = {
            showPreviewCover = false
            rowPreviewRequest = nil
        }

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = scene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(container, animated: false)
        }
    }

    // MARK: - Hero Selection

    private static let heroItemCap = 9
    /// Minimum TMDB-matched in-library items required to use the curated source.
    /// Below this threshold we fall back to Recently Added (small libraries,
    /// or the GUID index hasn't built yet on cold launch).
    private static let heroTMDBMinMatches = 3

    /// Populates `heroItems` for the home screen. Renders an immediate fallback
    /// (cache or Recently Added) so the UI never sits empty, then upgrades to
    /// TMDB-curated picks once that fetch + library lookup completes.
    private func selectHeroItems() {
        // 1) Cached result wins on cold launch — feels instant.
        if heroItems.isEmpty,
           let cached = dataStore.getCachedHeroItems(forLibrary: "home"),
           !cached.isEmpty {
            heroItems = cached
        }

        // 2) Render any hub-derived fallback immediately so we have something
        //    on screen while TMDB resolves.
        if heroItems.isEmpty {
            let candidates = computeHubBackedHero(from: dataStore.hubs)
            if !candidates.isEmpty {
                heroItems = candidates
                dataStore.cacheHeroItems(candidates, forLibrary: "home")
            }
        }

        // 3) Try to upgrade to a TMDB-curated set in the background.
        Task { await upgradeHeroFromTMDB() }
    }

    /// Fetches Popular Movies + Popular TV from TMDB, filters to items the user
    /// already has in their library (via the GUID index), and merges the result
    /// into `heroItems` so the currently-visible item stays put.
    ///
    /// Stable-merge strategy:
    ///   1. Compute the curated list (capped at `heroItemCap`).
    ///   2. If the currently-displayed item is in the curated set, reorder the
    ///      curated set so it stays at the user's current index — preserving
    ///      backdrop/logo so nothing visually swaps under them.
    ///   3. If not, keep the currently-displayed item at index 0 and append the
    ///      curated items behind it (deduped by ratingKey).
    @MainActor
    private func upgradeHeroFromTMDB() async {
        let curated = await Self.computeTMDBHero(cap: Self.heroItemCap)

        guard curated.count >= Self.heroTMDBMinMatches else {
            homeLog.info("[Hero] TMDB upgrade skipped: only \(curated.count) library matches")
            return
        }

        let mergedItems: [PlexMetadata]
        if let current = displayedHeroItem,
           let currentKey = current.ratingKey {
            if curated.contains(where: { $0.ratingKey == currentKey }) {
                // Current item is in the curated set — rotate so it occupies
                // `heroCurrentIndex` and the rest fills around it without
                // disturbing the visible item.
                let withoutCurrent = curated.filter { $0.ratingKey != currentKey }
                let targetIndex = max(0, min(heroCurrentIndex, withoutCurrent.count))
                var rotated = withoutCurrent
                rotated.insert(current, at: targetIndex)
                mergedItems = rotated
            } else {
                // Current item isn't curated — keep it visible at the front,
                // append curated behind it (de-duped).
                var merged: [PlexMetadata] = [current]
                let seen = Set([currentKey])
                for item in curated where !(item.ratingKey.map(seen.contains) ?? false) {
                    merged.append(item)
                }
                mergedItems = Array(merged.prefix(Self.heroItemCap))
                // Ensure the visible index still points at the (still-front) item.
                if heroCurrentIndex != 0 {
                    heroCurrentIndex = 0
                }
            }
        } else {
            mergedItems = curated
        }

        let newKeys = mergedItems.compactMap { $0.ratingKey }
        let currentKeys = heroItems.compactMap { $0.ratingKey }
        guard newKeys != currentKeys else { return }

        homeLog.info("[Hero] Merged TMDB-curated set: \(mergedItems.count) items (preserving displayed)")
        heroItems = mergedItems
        dataStore.cacheHeroItems(mergedItems, forLibrary: "home")
    }

    /// Currently-displayed hero item (clamped). Used by `upgradeHeroFromTMDB`
    /// to keep the visible backdrop stable across the curated-set merge.
    private var displayedHeroItem: PlexMetadata? {
        guard !heroItems.isEmpty else { return nil }
        let clamped = max(0, min(heroCurrentIndex, heroItems.count - 1))
        return heroItems[clamped]
    }

    /// Pure async helper. Returns up to `cap` library items chosen by
    /// interleaving Popular Movies and Popular TV from TMDB, filtered to items
    /// the user already owns.
    static func computeTMDBHero(cap: Int) async -> [PlexMetadata] {
        async let movies = TMDBDiscoverService.shared.fetchSection(.moviePopular)
        async let shows = TMDBDiscoverService.shared.fetchSection(.tvPopular)
        let (m, s) = await (movies, shows)

        // Interleave [m0, s0, m1, s1, ...] preserving TMDB's popularity order.
        var interleaved: [TMDBListItem] = []
        let count = max(m.count, s.count)
        for i in 0..<count {
            if i < m.count { interleaved.append(m[i]) }
            if i < s.count { interleaved.append(s[i]) }
        }

        var matches: [PlexMetadata] = []
        for item in interleaved {
            if let plex = await LibraryGUIDIndex.shared.lookup(tmdbId: item.id, type: item.mediaType) {
                matches.append(plex)
                if matches.count >= cap { break }
            }
        }
        return matches
    }

    /// Hub-derived fallback. Used to render something immediately while the
    /// async TMDB upgrade is in flight.
    private func computeHubBackedHero(from hubs: [PlexHub]) -> [PlexMetadata] {
        let allIdentifiers = hubs.compactMap { $0.hubIdentifier }.joined(separator: ", ")
        homeLog.debug("[Hero] available hubs: \(allIdentifiers, privacy: .public)")

        // Some servers expose a curated hub even without Plex Pass — keep
        // matching it as a higher-priority fallback than Recently Added.
        let curatedKeywords = ["recommended", "promoted", "featured", "spotlight"]
        let curated = hubs.first { hub in
            guard let id = hub.hubIdentifier?.lowercased(),
                  hub.Metadata?.isEmpty == false else { return false }
            return curatedKeywords.contains(where: id.contains)
        }
        if let items = curated?.Metadata, !items.isEmpty {
            homeLog.info("[Hero] Using curated hub \(curated?.hubIdentifier ?? "?", privacy: .public) with \(items.count) items")
            return Array(items.prefix(Self.heroItemCap)).filter { $0.ratingKey != nil }
        }

        let recentlyAdded = hubs.first { isRecentlyAddedHub($0) && ($0.Metadata?.isEmpty == false) }
        if let items = recentlyAdded?.Metadata, !items.isEmpty {
            homeLog.info("[Hero] Fallback to Recently Added hub with \(items.count) items")
            return Array(items.prefix(Self.heroItemCap)).filter { $0.ratingKey != nil }
        }

        if let firstHub = hubs.first(where: { $0.Metadata?.isEmpty == false }),
           let items = firstHub.Metadata, !items.isEmpty {
            homeLog.info("[Hero] Fallback to first non-empty hub \(firstHub.hubIdentifier ?? "?", privacy: .public)")
            return Array(items.prefix(Self.heroItemCap)).filter { $0.ratingKey != nil }
        }

        return []
    }

    // MARK: - Recommendations

    private func refreshRecommendations(force: Bool = false) async {
        guard enablePersonalizedRecommendations else { return }
        await MainActor.run {
            if force || recommendations.isEmpty {
                isLoadingRecommendations = true
            }
            recommendationsError = nil
        }

        do {
            let items = try await recommendationService.recommendations(
                forceRefresh: force,
                contentType: recommendationsContentType
            )
            await MainActor.run {
                recommendations = items
                isLoadingRecommendations = false
            }
        } catch {
            await MainActor.run {
                recommendations = []
                recommendationsError = error.localizedDescription
                isLoadingRecommendations = false
            }
        }
    }

    private func handleRecommendationsToggle() {
        if enablePersonalizedRecommendations {
            Task { await refreshRecommendations(force: true) }
        } else {
            recommendations = []
            recommendationsError = nil
            isLoadingRecommendations = false
        }
    }

    private func homeRowID(for hub: PlexHub, index: Int) -> String {
        let identifier = hub.hubIdentifier ?? hub.key ?? hub.hubKey ?? hub.title ?? "row"
        return "home:\(index):\(identifier)"
    }

    private func updateNestedNavigationState() {
        nestedNavState.isNested = selectedItem != nil
    }

    // MARK: - Content View

    private var contentView: some View {
        let heroActive = showHomeHero && !heroItems.isEmpty
        let screenHeight = UIScreen.main.bounds.height
        // Leave a modest peek for Continue Watching at the bottom of the hero
        // at the top scroll position. The backdrop fills the full screen behind
        // the scroll view; this height controls where the overlay content ends.
        let heroSectionHeight = screenHeight - 200

        let currentHeroItem: PlexMetadata? = {
            guard heroActive, !heroItems.isEmpty else { return nil }
            let clamped = max(0, min(heroCurrentIndex, heroItems.count - 1))
            return heroItems[clamped]
        }()

        return ZStack(alignment: .top) {
            // Layer 0: Fixed backdrop — fills the screen behind the scroll view.
            // Parallax offset at 40% of scroll speed creates the Apple TV
            // "receding hero" effect as the user scrolls down.
            if heroActive {
                HeroBackdropLayer(
                    currentItem: currentHeroItem,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? ""
                )
                .ignoresSafeArea()
                .offset(y: -heroScrollOffset * 1.3 - min(72, heroScrollOffset * 0.72))
                .allowsHitTesting(false)
            }

            // Layer 1: Scrollable content — hero overlay (transparent) scrolls
            // normally so focus management works, backdrop shows through.
            ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Connection error banner (when showing cached content while offline)
                    if !authManager.isConnected {
                        connectionErrorBanner
                    }

                    // Hero overlay: transparent foreground (logo/buttons/dots)
                    // that scrolls with content. The backdrop behind is fixed.
                    if heroActive {
                        HeroOverlayContent(
                            items: heroItems,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            currentIndex: $heroCurrentIndex,
                            onInfo: { item in selectItem(item) },
                            onPlay: { item in playItemDirectly(item) },
                            onHeroFocused: {
                                withAnimation(.smooth(duration: 0.8)) {
                                    scrollProxy.scrollTo("homeHero", anchor: .top)
                                }
                            },
                            onHeroExited: nil
                        )
                        .frame(height: heroSectionHeight)
                        .focusSection()
                        .id("homeHero")
                    }

                    // Content rows (uses cached processedHubs which merges Continue Watching + On Deck)
                    VStack(alignment: .leading, spacing: 48) {
                        // Invisible anchor so we can scroll to place Continue
                        // Watching at roughly mid-screen (matching Apple TV).
                        Color.clear
                            .frame(height: 0)
                            .id("contentRowsAnchor")

                        ForEach(Array(cachedProcessedHubs.enumerated()), id: \.element.id) { index, hub in
                            if let items = hub.Metadata, !items.isEmpty {
                                let isContinueWatching = isContinueWatchingHub(hub)
                                InfiniteContentRow(
                                    rowID: homeRowID(for: hub, index: index),
                                    title: hub.title ?? "Unknown",
                                    initialItems: items,
                                    hubKey: hub.key ?? hub.hubKey,
                                    hubIdentifier: hub.hubIdentifier,
                                    serverURL: authManager.selectedServerURL ?? "",
                                    authToken: authManager.selectedServerToken ?? "",
                                    isContinueWatching: isContinueWatching,
                                    contextMenuSource: isContinueWatching ? .continueWatching : .other,
                                    onItemSelected: { item in selectItem(item) },
                                    onPlayItem: { item in
                                        playItemDirectly(item)
                                    },
                                    onPlayFromBeginning: { item in
                                        playItemDirectly(item, fromBeginning: true)
                                    },
                                    onGoToItem: { item in selectItem(item) },
                                    onRefreshNeeded: {
                                        await dataStore.refreshHubs()
                                    },
                                    onPreviewRequested: isContinueWatching ? nil : { request in
                                        homeLog.info("[Preview] Opening carousel: \(request.items.count) items, tapped index=\(request.selectedIndex), title=\(request.items[request.selectedIndex].title ?? "?")")
                                        rowPreviewRequest = request
                                        showPreviewCover = true
                                    },
                                    restorePreviewFocusTarget: $previewRestoreTarget,
                                    onRowFocused: {
                                        let targetID = homeRowID(for: hub, index: index)
                                        withAnimation(.smooth(duration: 0.8)) {
                                            scrollProxy.scrollTo(targetID, anchor: UnitPoint(x: 0.5, y: 0.5))
                                        }
                                    }
                                )
                                .id(homeRowID(for: hub, index: index))
                            }
                        }

                        // Watchlist sits between Recently Added rows and Suggestions
                        WatchlistHubRow(
                            watchlist: watchlistService,
                            onPreviewRequested: { request in
                                rowPreviewRequest = request
                                showPreviewCover = true
                            },
                            // Fallbacks — the preview handler above is set, so
                            // these only fire if something upstream drops it.
                            // TMDB-only entries still route through
                            // MediaDetailView via TMDBMediaMapper.
                            onSelectPlex: { item in selectItem(item) },
                            onSelectTMDB: { tmdb in selectedItem = TMDBMediaMapper.item(tmdb) },
                            onRowFocused: {
                                withAnimation(.smooth(duration: 0.8)) {
                                    scrollProxy.scrollTo("watchlistHubRow", anchor: UnitPoint(x: 0.5, y: 0.5))
                                }
                            }
                        )
                        .id("watchlistHubRow")

                        // Recommendations at the end of all library hubs
                        if enablePersonalizedRecommendations {
                            recommendationsSection
                        }
                    }
                    .padding(.top, heroActive ? 0 : 48)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                heroScrollOffset = max(0, offset)
            }
            .scrollClipDisabled()  // Allow shadow overflow
            .ignoresSafeArea(.container, edges: heroActive ? [.top, .horizontal] : [])
            } // ScrollViewReader
        }
    }

    // MARK: - Connection Error Banner

    private var connectionErrorBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cannot Connect to Plex")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text(authManager.connectionError ?? "Showing cached content")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Button("Retry") {
                Task {
                    await authManager.verifyAndFixConnection()
                    if authManager.isConnected {
                        await dataStore.refreshHubs()
                    }
                }
            }
            .buttonStyle(AppStoreButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.yellow.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.yellow.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.top, 100)  // Below safe area
        .padding(.bottom, 20)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Recommendations Section

    @ViewBuilder
    private var recommendationsSection: some View {
        if isLoadingRecommendations && recommendations.isEmpty {
            HStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Building Personalized Recommendations")
                        .font(.system(size: 22, weight: .semibold))
                    Text("This may take a moment")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
            .padding(.top, 24)
        } else if let error = recommendationsError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Personalized Recommendations Unavailable")
                        .font(.system(size: 20, weight: .semibold))
                    Text(error)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Retry") {
                    Task { await refreshRecommendations(force: true) }
                }
                .buttonStyle(AppStoreButtonStyle())
            }
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
            .padding(.vertical, 12)
        } else if !recommendations.isEmpty {
            InfiniteContentRow(
                rowID: "home:recommendations",
                title: "Personalized Recommendations",
                initialItems: recommendations,
                hubKey: nil,
                hubIdentifier: nil,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? "",
                contextMenuSource: .other,
                onItemSelected: { item in selectItem(item) },
                onRefreshNeeded: {
                    await refreshRecommendations(force: true)
                },
                onPreviewRequested: { request in
                    rowPreviewRequest = request
                    showPreviewCover = true
                },
                restorePreviewFocusTarget: $previewRestoreTarget
            )
        }
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Unable to Load")
                .font(.title2)
                .fontWeight(.medium)

            Text(error)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                Task { await dataStore.refreshHubs() }
            } label: {
                Text("Try Again")
                    .fontWeight(.medium)
            }
            .buttonStyle(AppStoreButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 24) {
            Image(systemName: "film.stack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("No Content")
                .font(.title2)
                .fontWeight(.medium)

            Text("Your Plex library appears to be empty.")
                .font(.body)
                .foregroundStyle(.secondary)

            Button {
                Task { await dataStore.refreshHubs() }
            } label: {
                Text("Refresh")
                    .fontWeight(.medium)
            }
            .buttonStyle(AppStoreButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Not Connected View

    private var notConnectedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "server.rack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Not Connected")
                .font(.title2)
                .fontWeight(.medium)

            Text("Connect to your Plex server in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Navigation Helpers

    /// Convert a PlexMetadata item to MediaItem for navigation, routing music
    /// items to `selectedMusicItem` and all others to `selectedItem`.
    private func selectItem(_ meta: PlexMetadata) {
        switch meta.type {
        case "artist", "album":
            selectedMusicItem = meta
        case "track":
            playMusicTrack(meta)
        default:
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }
            let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
            selectedItem = PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
        }
    }

    // MARK: - Music Helpers

    private func playMusicTrack(_ plexMeta: PlexMetadata) {
        guard let provider = MusicProviderRegistry.shared.primaryProvider,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let track = PlexMusicMapper.track(
            plexMeta,
            providerID: provider.id,
            serverURL: serverURL,
            authToken: token
        )
        MusicQueue.shared.playNow(track: track)
    }
}

// MARK: - Continue Watching Context Menu

/// Switches between a custom Continue Watching context menu and the standard one
struct ContinueWatchingContextMenuModifier: ViewModifier {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let isContinueWatching: Bool
    let contextMenuSource: MediaItemContextSource
    var onGoToItem: ((PlexMetadata) -> Void)?
    var onPlayFromBeginning: ((PlexMetadata) -> Void)?
    var onRefreshNeeded: MediaItemRefreshCallback?

    @State private var isPerformingAction = false
    private let networkManager = PlexNetworkManager.shared
    private let dataStore = PlexDataStore.shared

    func body(content: Content) -> some View {
        if isContinueWatching {
            content.contextMenu {
                // Watch from Beginning
                Button {
                    onPlayFromBeginning?(item)
                } label: {
                    Label("Watch from Beginning", systemImage: "arrow.counterclockwise")
                }

                // Go to Episode
                Button {
                    onGoToItem?(item)
                } label: {
                    Label("Go to Episode", systemImage: "info.circle")
                }

                Divider()

                // Mark as Watched
                Button {
                    performAction(optimisticWatched: true) {
                        try await networkManager.markWatched(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Mark as Watched", systemImage: "rectangle.badge.checkmark")
                }

                // Remove from Continue Watching
                Button {
                    performAction {
                        try await networkManager.removeFromContinueWatching(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Remove from Continue Watching", systemImage: "trash")
                }

                Divider()

                // Refresh Metadata
                Button {
                    performAction {
                        try await networkManager.refreshMetadata(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Refresh Metadata", systemImage: "arrow.clockwise")
                }
            }
        } else {
            content.mediaItemContextMenu(
                item: item,
                serverURL: serverURL,
                authToken: authToken,
                source: contextMenuSource,
                onRefreshNeeded: onRefreshNeeded
            )
        }
    }

    private func performAction(optimisticWatched: Bool? = nil, _ action: @escaping () async throws -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        Task {
            do {
                try await action()
                if let watched = optimisticWatched, let ratingKey = item.ratingKey {
                    await MainActor.run {
                        dataStore.updateItemWatchStatus(ratingKey: ratingKey, watched: watched)
                    }
                }
                await onRefreshNeeded?()
            } catch {}
            isPerformingAction = false
        }
    }
}

// MARK: - Content Row (replaces MediaRow for Home)

struct ContentRow: View {
    let title: String
    let items: [PlexMetadata]
    let serverURL: String
    let authToken: String
    var onItemSelected: ((PlexMetadata) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Section title
            Text(title)
                .font(.system(size: ScaledDimensions.sectionTitleSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)

            // Horizontal scroll of posters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ScaledDimensions.rowItemSpacing) {
                    ForEach(items, id: \.ratingKey) { item in
                        Button {
                            onItemSelected?(item)
                        } label: {
                            MediaPosterCard(
                                item: item,
                                serverURL: serverURL,
                                authToken: authToken
                            )
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, ScaledDimensions.rowVerticalPadding)  // Room for scale effect and shadow
            }
            .scrollClipDisabled()  // Allow shadow overflow
        }
    }
}

// MARK: - Infinite Content Row (with endless scrolling)

/// A content row that loads more items as the user scrolls near the end
struct InfiniteContentRow: View {
    let rowID: String
    let title: String
    let initialItems: [PlexMetadata]
    let hubKey: String?  // The hub's key for fetching more items
    let hubIdentifier: String?  // The hub's identifier (e.g., "home.movies.recent") - needed for /hubs/items endpoint
    let serverURL: String
    let authToken: String
    var isContinueWatching: Bool = false
    var contextMenuSource: MediaItemContextSource = .other
    var onItemSelected: ((PlexMetadata) -> Void)?
    var onPlayItem: ((PlexMetadata) -> Void)?
    var onPlayFromBeginning: ((PlexMetadata) -> Void)?
    var onGoToItem: ((PlexMetadata) -> Void)?
    var onRefreshNeeded: MediaItemRefreshCallback?
    var onPreviewRequested: ((PreviewRequest) -> Void)?
    var restorePreviewFocusTarget: Binding<PreviewSourceTarget?> = .constant(nil)
    var onRowFocused: (() -> Void)?

    @State private var items: [PlexMetadata] = []
    @State private var isLoadingMore = false
    @State private var hasReachedEnd = false
    @State private var totalSize: Int?
    @FocusState private var focusedItemId: String?  // Track which item is focused (format: "context:itemId")
    @Environment(\.uiScale) private var uiScale

    /// Create a unique focus ID for an item in this row
    private func focusId(for item: PlexMetadata) -> String {
        focusId(forItemID: sourceItemID(for: item))
    }

    private func focusId(forItemID itemID: String) -> String {
        "\(rowID):\(itemID)"
    }

    private func sourceItemID(for item: PlexMetadata, index: Int? = nil) -> String {
        if let ratingKey = item.ratingKey {
            return ratingKey
        }
        let suffix = index.map(String.init) ?? "unknown"
        return "\(rowID)-\(suffix)"
    }

    private let networkManager = PlexNetworkManager.shared
    private let pageSize = 24

    /// Check if this row contains music items (uses square posters)
    private var isMusicRow: Bool {
        guard let firstItem = items.first ?? initialItems.first else { return false }
        return firstItem.type == "album" || firstItem.type == "artist" || firstItem.type == "track"
    }

    /// Hash that changes when items or their watch status changes
    /// Note: Excludes viewOffset as it changes during playback and would cause unnecessary resets
    private var initialItemsHash: Int {
        var hasher = Hasher()
        hasher.combine(initialItems.count)
        for item in initialItems.prefix(20) {
            hasher.combine(item.ratingKey)
            hasher.combine(item.viewCount)
            // viewOffset excluded - it changes during playback and triggers unwanted list resets
        }
        return hasher.finalize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section title with item count
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))

                if let total = totalSize, total > items.count {
                    Text("\(items.count) of \(total)")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                } else if hasReachedEnd && items.count > pageSize {
                    Text("All \(items.count)")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)

            // Horizontal scroll of posters with infinite loading
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: ScaledDimensions.rowItemSpacing) {  // Lazy to avoid laying out hundreds of offscreen posters
                    ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                        Button {
                            if isContinueWatching {
                                onPlayItem?(item)
                            } else if let onPreviewRequested {
                                // Convert Plex row items to agnostic MediaItems at the
                                // carousel boundary. InfiniteContentRow is the last
                                // Plex-typed renderer in the chain; PreviewRequest and
                                // everything below speaks MediaItem.
                                let providerID = MediaProviderRegistry.shared.primaryProvider?.id
                                    ?? "plex:\(serverURL)"
                                let mediaItems = items.map {
                                    PlexMediaMapper.item(
                                        $0, providerID: providerID,
                                        serverURL: serverURL, authToken: authToken
                                    )
                                }
                                onPreviewRequested(
                                    PreviewRequest(
                                        items: mediaItems,
                                        selectedIndex: index,
                                        sourceRowID: rowID,
                                        sourceItemID: sourceItemID(for: item, index: index)
                                    )
                                )
                            } else {
                                onItemSelected?(item)
                            }
                        } label: {
                            if isContinueWatching {
                                ContinueWatchingCard(
                                    item: item,
                                    serverURL: serverURL,
                                    authToken: authToken,
                                    isFocused: focusedItemId == focusId(for: item)
                                )
                            } else {
                                // Whole tile scales uniformly on focus (poster +
                                // title + year together) so the label below
                                // doesn't get covered by MediaPosterCard's inner
                                // hover-highlight.
                                let tileFocused = focusedItemId == focusId(for: item)
                                VStack(alignment: .leading, spacing: 10) {
                                    MediaPosterCard(
                                        item: item,
                                        serverURL: serverURL,
                                        authToken: authToken
                                    )
                                    .hoverEffectDisabled()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title ?? "")
                                            .font(.system(size: 18, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineLimit(1)
                                        if let year = item.year, item.type == "movie" {
                                            Text(verbatim: "\(year)")
                                                .font(.system(size: 14))
                                                .foregroundStyle(.white.opacity(0.55))
                                        }
                                    }
                                    // Cap label to poster width so a long
                                    // title truncates rather than stretching
                                    // the tile (LazyHStack doesn't enforce
                                    // a per-item width the way LazyVGrid's
                                    // columns do for the library grid).
                                    .frame(width: ScaledDimensions.posterWidth * uiScale, height: 44, alignment: .topLeading)
                                }
                                .scaleEffect(tileFocused ? 1.10 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: tileFocused)
                            }
                        }
                        .previewSourceAnchor(rowID: rowID, itemID: sourceItemID(for: item, index: index))
                        .buttonStyle(CardButtonStyle())
                        .focused($focusedItemId, equals: focusId(for: item))
                        .modifier(ContinueWatchingContextMenuModifier(
                            item: item,
                            serverURL: serverURL,
                            authToken: authToken,
                            isContinueWatching: isContinueWatching,
                            contextMenuSource: contextMenuSource,
                            onGoToItem: onGoToItem,
                            onPlayFromBeginning: onPlayFromBeginning,
                            onRefreshNeeded: onRefreshNeeded
                        ))
                        .onAppear {
                            // Load more when user is 5 items from the end
                            if index >= items.count - 5 {
                                Task {
                                    await loadMoreIfNeeded()
                                }
                            }
                        }
                    }

                    // Loading indicator at the end
                    if isLoadingMore {
                        loadingIndicator
                    } else if hasReachedEnd && items.count > pageSize {
                        endIndicator
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, ScaledDimensions.rowVerticalPadding)  // Room for scale effect and shadow
            }
            .scrollClipDisabled()  // Allow shadow overflow
        }
        .onAppear {
            if items.isEmpty {
                items = initialItems
                // Check if we already have all items
                if let size = totalSize, items.count >= size {
                    hasReachedEnd = true
                }
            }
        }
        .onChange(of: initialItemsHash) { _, _ in
            // Reset when initial items change (e.g., on refresh or watch status change)
            let savedFocusId = focusedItemId
            items = initialItems
            hasReachedEnd = false
            // Restore focus after items reset to prevent focus loss (e.g., after marking watched)
            if let savedFocusId {
                let parts = savedFocusId.split(separator: ":", maxSplits: 1)
                let savedKey = parts.count == 2 ? String(parts[1]) : nil
                if let savedKey, items.contains(where: { $0.ratingKey == savedKey }) {
                    // Must nil first then restore async — SwiftUI ignores setting the same value
                    focusedItemId = nil
                    DispatchQueue.main.async {
                        focusedItemId = savedFocusId
                    }
                }
            }
        }
        .onChange(of: focusedItemId) { oldValue, newValue in
            if oldValue == nil && newValue != nil {
                onRowFocused?()
            }
        }
        .onChange(of: restorePreviewFocusTarget.wrappedValue) { _, target in
            guard let target, target.rowID == rowID else { return }

            let targetFocusID = focusId(forItemID: target.itemID)
            guard items.contains(where: { sourceItemID(for: $0) == target.itemID }) else { return }

            focusedItemId = nil
            DispatchQueue.main.async {
                focusedItemId = targetFocusID
                restorePreviewFocusTarget.wrappedValue = nil
            }
        }
        .focusSection()
    }

    /// Skeleton placeholder card shown while loading more items
    private var loadingIndicator: some View {
        skeletonPosterCard
    }

    /// Single skeleton card matching the appropriate card dimensions
    private var skeletonPosterCard: some View {
        Group {
            if isContinueWatching {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .frame(
                        width: ScaledDimensions.continueWatchingWidth,
                        height: ScaledDimensions.continueWatchingHeight
                    )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .frame(width: 220, height: isMusicRow ? 220 : 330)

                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .frame(width: 160, height: 14)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.white.opacity(0.04))
                            .frame(width: 100, height: 12)
                    }
                    .frame(height: 52, alignment: .top)
                }
            }
        }
    }

    private var endIndicator: some View {
        EmptyView()
    }

    private func loadMoreIfNeeded() async {
        // Don't load if we're already loading, reached the end, or have no hub key
        guard !isLoadingMore,
              !hasReachedEnd,
              let hubKey = hubKey,
              !hubKey.isEmpty else {
            return
        }

        // Check if we might have more items based on totalSize
        if let total = totalSize, items.count >= total {
            hasReachedEnd = true
            return
        }

        isLoadingMore = true

        do {
            let result = try await networkManager.getHubItems(
                serverURL: serverURL,
                authToken: authToken,
                hubKey: hubKey,
                hubIdentifier: hubIdentifier,
                start: items.count,
                count: pageSize
            )

            // Update total size if we got it
            if let size = result.totalSize {
                totalSize = size
            }

            if result.items.isEmpty {
                // No more items
                hasReachedEnd = true
            } else {
                // Append new items, deduplicating by ratingKey
                let existingKeys = Set(items.compactMap { $0.ratingKey })
                let newItems = result.items.filter { item in
                    guard let key = item.ratingKey else { return false }
                    return !existingKeys.contains(key)
                }

                if newItems.isEmpty {
                    // All items were duplicates, we've reached the end
                    hasReachedEnd = true
                } else {
                    items.append(contentsOf: newItems)

                    // Check if we've loaded everything
                    if let total = totalSize, items.count >= total {
                        hasReachedEnd = true
                    }
                }
            }
        } catch {
            // Don't mark as reached end on error - user can retry by scrolling
        }

        isLoadingMore = false
    }
}

#Preview {
    PlexHomeView()
}
