//
//  PlexLibraryView.swift
//  Rivulet
//
//  Grid view for browsing a Plex library section
//

import SwiftUI
import UIKit


struct PlexLibraryView: View {
    let libraryKey: String
    let libraryTitle: String

    @Environment(\.nestedNavigationState) private var nestedNavState
    @Environment(\.uiScale) private var scale

    @StateObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var librarySettings = LibrarySettingsManager.shared
    private let dataStore = PlexDataStore.shared
    @AppStorage("showLibraryHero") private var showLibraryHero = false
    @AppStorage("showLibraryRecommendations") private var showLibraryRecommendations = true
    @AppStorage("showLibraryRecentRows") private var showLibraryRecentRows = true
    @State private var currentSortOption: LibrarySortOption = .addedAtDesc
    @State private var items: [PlexMetadata] = []
    @State private var hubs: [PlexHub] = []  // Library-specific hubs from Plex API
    @State private var isLoading = false
    @State private var isLoadingMore = false  // Loading additional pages
    @State private var error: String?
    @State private var selectedItem: MediaItem?

    /// Sub-item navigation requested from inside an expanded preview (e.g.
    /// the user clicked an episode's description tile in `PreviewOverlayHost`).
    /// The preview overlay is presented via UIKit modal and lives outside
    /// our `NavigationStack`, so its `MediaDetailView` cannot push directly.
    /// We dismiss the overlay and `.navigationDestination(item:)` (attached
    /// to the NavigationStack content below) handles the push.
    @State private var pendingPreviewNavigation: MediaItem?
    @State private var heroItems: [PlexMetadata] = []
    @State private var heroCurrentIndex: Int = 0
    @State private var heroScrollOffset: CGFloat = 0
    @State private var lastLoadedLibraryKey: String?  // Track which library is currently loaded
    @State private var hasPrefetched = false  // Track if we've already prefetched for this library
    @State private var hasMoreItems = true  // Whether there are more items to load
    @State private var totalItemCount: Int = 0  // Total items in this library
    @State private var cachedProcessedHubs: [PlexHub] = []  // Memoized hubs to avoid recalculation
    @State private var loadingTask: Task<Void, Never>?  // Track current loading task for cancellation
    // Batching disabled — LazyVGrid handles lazy rendering natively.
    // Uncomment if first-load performance regresses.
    // @State private var visibleItemCount: Int = 0
    // @State private var visibleItemExpandTask: Task<Void, Never>?
    @State private var recommendations: [PlexMetadata] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationsError: String?
    @AppStorage("enablePersonalizedRecommendations") private var enablePersonalizedRecommendations = false

    @FocusState private var focusedItemId: String?  // Track focused item by "context:itemId" format
    @State private var lastFocusedItemId: String?  // Remembers focus for back-from-detail restore
    @State private var rowPreviewRequest: PreviewRequest?
    @State private var previewRestoreTarget: PreviewSourceTarget?
    @State private var capturedSourceFrames: [PreviewSourceTarget: CGRect] = [:]
    @State private var showPreviewCover = false
    @State private var lastPrefetchIndex: Int = -18  // Track last prefetch position for throttling

    // Resume-or-restart prompt for in-progress items launched directly from
    // the hero carousel. Off by default; the "Watch from Beginning"
    // context-menu action bypasses by passing `fromBeginning: true` to
    // `playItemDirectly`.
    @AppStorage("promptResumeOrRestart") private var promptResumeOrRestart = false
    @State private var showResumeChoice = false
    @State private var resumeChoiceTimeMs: Int = 0
    @State private var resumeChoiceLaunch: ((_ playFromBeginning: Bool) -> Void)? = nil

    private var firstDisplayedItem: PlexMetadata? {
        items.first
    }

    /// Create a unique focus ID for a grid item
    private func gridFocusId(for item: PlexMetadata) -> String {
        "libraryGrid:\(item.ratingKey ?? "")"
    }

    private let networkManager = PlexNetworkManager.shared
    private let cacheManager = CacheManager.shared
    private let recommendationService = PersonalizedRecommendationService.shared

    /// Check if this is a music library (uses square posters)
    private var isMusicLibrary: Bool {
        dataStore.libraries.first(where: { $0.key == libraryKey })?.isMusicLibrary ?? false
    }

    private var columns: [GridItem] {
        let minWidth = ScaledDimensions.gridMinWidth * scale
        let maxWidth = ScaledDimensions.gridMaxWidth * scale
        return [GridItem(.adaptive(minimum: minWidth, maximum: maxWidth), spacing: ScaledDimensions.gridSpacing)]
    }

    // private let initialVisibleBatch = 36  // Limit first-frame layout work

    private var recommendationsContentType: RecommendationContentType {
        let libraryType = dataStore.libraries.first(where: { $0.key == libraryKey })?.type
        switch libraryType {
        case "movie":
            return .movies
        case "show":
            return .shows
        default:
            return .moviesAndShows
        }
    }

    private var shouldShowRecommendationsRow: Bool {
        let libraryType = dataStore.libraries.first(where: { $0.key == libraryKey })?.type
        return libraryType == "movie" || libraryType == "show"
    }

    // MARK: - Processed Hubs (merged Continue Watching + On Deck)

    /// Essential hub types that are always shown (Continue Watching, Recently Added, Recently Released, Recently Played)
    private func isEssentialHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""

        // Continue Watching / On Deck
        if identifier.contains("continuewatching") || title.contains("continue watching") ||
           identifier.contains("ondeck") || title.contains("on deck") {
            return true
        }

        // Recently Added (video and music)
        if identifier.contains("recentlyadded") || title.contains("recently added") {
            return true
        }

        // Recently Released (by year)
        if identifier.contains("recentlyreleased") || title.contains("recently released") ||
           identifier.contains("newestreleases") || title.contains("newest releases") {
            return true
        }

        // Recently Played (music)
        if identifier.contains("recentlyplayed") || title.contains("recently played") {
            return true
        }

        return false
    }

    /// Check if a hub is a "recent" type (Recently Added, Recently Released, Newest Releases)
    private func isRecentHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return identifier.contains("recentlyadded") || title.contains("recently added") ||
               identifier.contains("recentlyreleased") || title.contains("recently released") ||
               identifier.contains("newestreleases") || title.contains("newest releases")
    }

    /// Essential hubs only (Continue Watching, Recently Added, Recently Released)
    private var essentialHubs: [PlexHub] {
        cachedProcessedHubs.filter { isEssentialHub($0) && (showLibraryRecentRows || !isRecentHub($0)) }
    }

    /// Discovery/recommendation hubs (Rediscover, Because you watched, etc.)
    private var discoveryHubs: [PlexHub] {
        cachedProcessedHubs.filter { !isEssentialHub($0) }
    }

    /// Processes hubs to combine Continue Watching and On Deck, similar to PlexHomeView
    /// Called once when hubs change, result is cached in cachedProcessedHubs
    private func computeProcessedHubs(from hubsToProcess: [PlexHub]) -> [PlexHub] {
        var result: [PlexHub] = []
        var continueWatchingItems: [PlexMetadata] = []
        var seenRatingKeys: Set<String> = []

        for hub in hubsToProcess {
            let identifier = hub.hubIdentifier?.lowercased() ?? ""
            let title = hub.title?.lowercased() ?? ""

            // Check if this is a Continue Watching or On Deck hub
            let isContinueWatching = identifier.contains("continuewatching") ||
                                     title.contains("continue watching")
            let isOnDeck = identifier.contains("ondeck") ||
                          title.contains("on deck")

            if isContinueWatching || isOnDeck {
                // Merge items, deduplicating by ratingKey
                if let items = hub.Metadata {
                    for item in items {
                        if let key = item.ratingKey, !seenRatingKeys.contains(key) {
                            seenRatingKeys.insert(key)
                            continueWatchingItems.append(item)
                        }
                    }
                }
            } else {
                // Include all non-continue-watching hubs
                result.append(hub)
            }
        }

        // Sort merged items by lastViewedAt (most recent first)
        continueWatchingItems.sort { item1, item2 in
            let time1 = item1.lastViewedAt ?? 0
            let time2 = item2.lastViewedAt ?? 0
            return time1 > time2
        }

        // Create merged Continue Watching hub if we have items
        if !continueWatchingItems.isEmpty {
            let mergedHub = PlexHub(
                hubIdentifier: "continueWatching",
                title: "Continue Watching",
                Metadata: continueWatchingItems
            )
            // Insert at beginning
            result.insert(mergedHub, at: 0)
        }

        return result
    }

    var body: some View {
        NavigationStack {
            navigationContent
        }
        // Tell parent we're in nested navigation when viewing detail
        .onChange(of: selectedItem) { _, newValue in
            let _ = newValue
            updateNestedNavigationState()
        }
        .onChange(of: enablePersonalizedRecommendations) { _, _ in
            handleRecommendationsToggle()
        }
        // Track last focused item for back-from-detail restore
        .onChange(of: focusedItemId) { _, newValue in
            if let newValue {
                lastFocusedItemId = newValue
            }
        }
        // Resume-or-restart prompt for direct-play paths (hero carousel,
        // Continue Watching primary tap). Gated on the
        // `promptResumeOrRestart` setting; off by default.
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
    }

    @ViewBuilder
    private var libraryStateContent: some View {
        ZStack {
            if !authManager.isAuthenticated {
                notConnectedView
            } else if isLoading && items.isEmpty {
                loadingView
            } else if let error = error, items.isEmpty {
                errorView(error)
            } else if items.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
    }

    private var navigationContent: some View {
        libraryStateContent
            .task(id: libraryKey) {
                await handleLibraryTask()
            }
            .refreshable {
                await refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)) { _ in
                Task {
                    guard let serverURL = authManager.selectedServerURL,
                          let token = authManager.selectedServerToken else { return }
                    await fetchLibraryHubs(serverURL: serverURL, token: token)
                }
            }
            .navigationDestination(item: $selectedItem) { item in
                MediaDetailView(item: item)
            }
            .navigationDestination(item: $pendingPreviewNavigation) { item in
                MediaDetailView(item: item)
            }
            .overlayPreferenceValue(PreviewSourceFramePreferenceKey.self) { anchors in
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

    // MARK: - Preview Presentation (UIKit Modal)

    private func presentPreview(request: PreviewRequest) {
        let menuBridge = PreviewMenuBridge()

        let previewContent = PreviewOverlayHost(
            request: request,
            sourceFrames: capturedSourceFrames,
            onDismiss: { sourceTarget in
                previewRestoreTarget = sourceTarget
                PreviewContainerViewController.dismissTopmost()
            },
            onSubItemNavigation: { item in
                // Dismiss the modal preview first, THEN stage the
                // navigation push inside the completion. Setting the
                // binding before dismiss races with the modal still
                // owning the VC stack and either drops the push or
                // briefly presents it onto an obscured stack.
                PreviewContainerViewController.dismissTopmost {
                    pendingPreviewNavigation = item
                }
            },
            menuBridge: menuBridge
        )

        // Preview is presented via UIKit `present(_:animated:)`, which creates
        // a hosting controller whose SwiftUI environment is NOT inherited from
        // this view's tree. Re-inject the registries so MediaDetailView (and
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

    private func handleLibraryTask() async {
        loadingTask?.cancel()

        error = nil

        let isNewLibrary = lastLoadedLibraryKey != libraryKey

        if authManager.isAuthenticated {
            if isNewLibrary {
                items = []
                hubs = []
                cachedProcessedHubs = []
                isLoading = true
                lastLoadedLibraryKey = libraryKey

                currentSortOption = librarySettings.getSortOption(for: libraryKey)

                focusedItemId = nil
                lastFocusedItemId = nil

                heroItems = dataStore.getCachedHeroItems(forLibrary: libraryKey) ?? []

                hasPrefetched = false
                hasMoreItems = true
                totalItemCount = 0

                let inMemoryHubs = dataStore.libraryHubs[libraryKey]

                let libKey = libraryKey
                let (cachedItems, cachedHubs): ([PlexMetadata], [PlexHub]?) = await Task.detached(priority: .userInitiated) {
                    async let itemsTask = self.getCachedItems()
                    let hubsResult: [PlexHub]?
                    if inMemoryHubs != nil {
                        hubsResult = nil
                    } else {
                        hubsResult = await self.cacheManager.getCachedLibraryHubs(forLibrary: libKey)
                    }
                    return await (itemsTask, hubsResult)
                }.value

                let hubsToUse = inMemoryHubs ?? cachedHubs
                if let hubsToUse, !hubsToUse.isEmpty {
                    hubs = hubsToUse
                    cachedProcessedHubs = computeProcessedHubs(from: hubsToUse)
                }

                if !cachedItems.isEmpty {
                    items = cachedItems
                    isLoading = false

                    if heroItems.isEmpty {
                        selectHeroItemsFromCurrentData()
                    }

                    if !dataStore.isFresh("libraryItems:\(libraryKey)", within: 60) {
                        await loadItemsInBackground()
                    }
                } else {
                    await loadItems()
                }

                if enablePersonalizedRecommendations {
                    Task { await refreshRecommendations(force: false) }
                }
            } else {
                await loadItemsInBackground()
                if enablePersonalizedRecommendations, recommendations.isEmpty {
                    Task { await refreshRecommendations(force: false) }
                }
            }
        } else {
            items = []
            hubs = []
            cachedProcessedHubs = []
            heroItems = []
            lastLoadedLibraryKey = nil
            isLoading = false
        }
    }

    private func libraryRowID(for hub: PlexHub, section: String, index: Int) -> String {
        let identifier = hub.hubIdentifier ?? hub.key ?? hub.hubKey ?? hub.title ?? "row"
        return "library:\(libraryKey):\(section):\(index):\(identifier)"
    }

    private func updateNestedNavigationState() {
        let isNested = selectedItem != nil
        nestedNavState.isNested = isNested
        if !isNested, let targetId = lastFocusedItemId {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                focusedItemId = targetId
            }
        }
    }

    // MARK: - Content View

    private var contentView: some View {
        let heroActive = showLibraryHero && !heroItems.isEmpty
        let screenHeight = UIScreen.main.bounds.height
        // Same sizing as the home hero so both screens feel consistent:
        // full-width, near-full-height with a modest peek for the row below.
        let heroSectionHeight = screenHeight - 200

        let currentHeroItem: PlexMetadata? = {
            guard heroActive, !heroItems.isEmpty else { return nil }
            let clamped = max(0, min(heroCurrentIndex, heroItems.count - 1))
            return heroItems[clamped]
        }()

        return ZStack(alignment: .top) {
            // Layer 0: Fixed backdrop — fills the full screen behind the scroll
            // view. Parallax offset at 40% of scroll speed creates the Apple TV
            // "receding hero" effect as the user scrolls down.
            if heroActive {
                HeroBackdropLayer(
                    currentItem: currentHeroItem,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? ""
                )
                .ignoresSafeArea()
                // Parallax values mirror PlexHomeView so both hero surfaces
                // feel identical. Library used to need more pull (122 / 1.22)
                // because the sections below the hero had accumulated their
                // own top-padding (discovery: +48, section header: +60);
                // those were flattened into a single wrapper VStack so this
                // can match Home's gentler 72 / 0.72.
                .offset(y: -heroScrollOffset * 1.3 - min(72, heroScrollOffset * 0.72))
                .allowsHitTesting(false)
            }

            // Layer 1: Scrollable content
            ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Hero overlay: transparent foreground (logo/buttons/dots)
                    // that scrolls with content. The backdrop behind is fixed.
                    if heroActive {
                        HeroOverlayContent(
                            items: heroItems,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            currentIndex: $heroCurrentIndex,
                            onInfo: { item in selectedItem = selectMediaItem(item) },
                            onPlay: { item in playItemDirectly(item) },
                            onHeroFocused: {
                                // Only snap back to the hero when we're actually
                                // scrolled down into content. On entry the hero is
                                // already at the top, so this scrollTo is redundant.
                                if heroScrollOffset > 1 {
                                    withAnimation(.smooth(duration: 0.8)) {
                                        scrollProxy.scrollTo("libraryHero", anchor: .top)
                                    }
                                }
                            }
                        )
                        .frame(height: heroSectionHeight)
                        .focusSection()
                        .id("libraryHero")
                    }

                    // Single wrapping VStack so everything below the hero scrolls
                    // as one unit with consistent inter-section spacing. Mirrors
                    // PlexHomeView's pattern; each child view has had its own
                    // top-padding removed (see comments at each call site).
                    // The zero-height Color.clear anchor is load-bearing: it
                    // ensures the first real row sits 48pt below the hero
                    // (because VStack spacing applies BETWEEN children) —
                    // matching PlexHomeView's layout so focus-driven scroll
                    // animations land on identical offsets in both views.
                    VStack(alignment: .leading, spacing: 48) {
                        Color.clear
                            .frame(height: 0)
                            .id("libraryContentRowsAnchor")
                        essentialRowsView(scrollProxy: scrollProxy)
                        discoveryRowsView(scrollProxy: scrollProxy)
                        librarySectionHeader
                        libraryGridView
                    }
                    .padding(.top, heroActive ? 0 : 100)

                    // Loading more indicator
                    if isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(1.2)
                            Spacer()
                        }
                        .padding(.bottom, 40)
                    }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offset in
                heroScrollOffset = max(0, offset)
            }
            .scrollClipDisabled()  // Allow shadow overflow
            .ignoresSafeArea(.container, edges: heroActive ? [.top, .horizontal] : [])
            .id(libraryKey)  // Force fresh ScrollView when library changes - starts at top
            } // ScrollViewReader
        }
        .opacity(rowPreviewRequest != nil ? 0.12 : 1)
        .offset(y: rowPreviewRequest != nil ? 20 : 0)
        .allowsHitTesting(rowPreviewRequest == nil)
        .animation(previewEntryAnimation, value: rowPreviewRequest?.id)
        .onAppear {
            // Hero will be selected when items load via task handler
            if heroItems.isEmpty && !items.isEmpty {
                selectHeroItems()
            }
        }
        .onChange(of: items.count) { oldCount, newCount in
            // Consolidated handler: hero selection + prefetch
            if heroItems.isEmpty {
                selectHeroItems()
            }
            handleItemsCountChange(oldCount: oldCount, newCount: newCount)
        }
        .onChange(of: hubs.count) { _, _ in
            // Recompute cached hubs (memoization)
            cachedProcessedHubs = computeProcessedHubs(from: hubs)
            // Pick the hero from hubs only if it isn't already set. We do NOT
            // re-pick an existing hero here: the instant pick and a later hub
            // pick can differ, and swapping a beat after entry is the visible
            // "flash". The hero is chosen once and kept.
            if heroItems.isEmpty {
                selectHeroItems()
            }
        }
    }

    // MARK: - Hero Selection

    private static let heroItemCap = 15

    /// Build the library-scoped hero carousel, preferring the promoted hub,
    /// falling back to Recently Added, then the library's own item list.
    private func selectHeroItems() {
        let next = computeHeroItems(preferItemsFirst: false)
        commitHeroItems(next)
    }

    /// Variant used during instant library-switch restoration. Prefers the
    /// hub-based pick (same priority as `selectHeroItems`) so the instant pick
    /// matches the eventual one and the hero doesn't visibly swap ("flash")
    /// when hubs finish loading. Falls back to the item list when no hubs are
    /// cached yet.
    private func selectHeroItemsFromCurrentData() {
        let next = computeHeroItems(preferItemsFirst: false)
        commitHeroItems(next)
    }

    private func commitHeroItems(_ next: [PlexMetadata]) {
        guard !next.isEmpty else { return }
        let newKeys = next.compactMap { $0.ratingKey }
        let currentKeys = heroItems.compactMap { $0.ratingKey }
        if newKeys != currentKeys {
            heroItems = next
        }
        dataStore.cacheHeroItems(next, forLibrary: libraryKey)
    }

    /// Shared computation — callers decide whether the library's items array
    /// should be consulted before hubs during cold library switches.
    private func computeHeroItems(preferItemsFirst: Bool) -> [PlexMetadata] {
        let promoted = hubs.first { hub in
            (hub.hubIdentifier?.lowercased().contains("promoted") == true)
                && (hub.Metadata?.isEmpty == false)
        }
        if let promotedItems = promoted?.Metadata, !promotedItems.isEmpty {
            return Array(promotedItems.prefix(Self.heroItemCap))
                .filter { $0.ratingKey != nil }
        }

        let recentlyAddedHub = hubs.first { hub in
            let identifier = hub.hubIdentifier?.lowercased() ?? ""
            let title = hub.title?.lowercased() ?? ""
            return identifier.contains("recentlyadded") || title.contains("recently added")
        }

        if preferItemsFirst {
            if let result = topItems(from: items) { return result }
            if let hubItems = recentlyAddedHub?.Metadata, !hubItems.isEmpty {
                return Array(hubItems.prefix(Self.heroItemCap)).filter { $0.ratingKey != nil }
            }
        } else {
            if let hubItems = recentlyAddedHub?.Metadata, !hubItems.isEmpty {
                return Array(hubItems.prefix(Self.heroItemCap)).filter { $0.ratingKey != nil }
            }
            if let result = topItems(from: items) { return result }
        }

        return []
    }

    /// Top-N items by `addedAt` descending — cheaper than a full sort for large
    /// arrays and stable under small insertions.
    private func topItems(from pool: [PlexMetadata]) -> [PlexMetadata]? {
        guard !pool.isEmpty else { return nil }
        let ranked = pool
            .filter { $0.ratingKey != nil }
            .sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
            .prefix(Self.heroItemCap)
        let array = Array(ranked)
        return array.isEmpty ? nil : array
    }

    // MARK: - Essential Rows View (Continue Watching, Recently Added, Recently Released)

    @ViewBuilder
    private func essentialRowsView(scrollProxy: ScrollViewProxy) -> some View {
        if !essentialHubs.isEmpty {
            VStack(alignment: .leading, spacing: 40) {
                let continueWatchingIndex = essentialHubs.firstIndex(where: isContinueWatchingHub)
                ForEach(Array(essentialHubs.enumerated()), id: \.element.hubIdentifier) { index, hub in
                    if let hubItems = hub.Metadata, !hubItems.isEmpty {
                        let isContinueWatching = isContinueWatchingHub(hub)
                        let rowID = libraryRowID(for: hub, section: "essential", index: index)
                        InfiniteContentRow(
                            rowID: rowID,
                            title: hub.title ?? "Untitled",
                            initialItems: hubItems,
                            hubKey: hub.key ?? hub.hubKey,
                            hubIdentifier: hub.hubIdentifier,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            isContinueWatching: isContinueWatching,
                            contextMenuSource: isContinueWatching ? .continueWatching : .library,
                            onItemSelected: { item in
                                selectedItem = selectMediaItem(item)
                            },
                            onPlayItem: { item in
                                playItemDirectly(item)
                            },
                            onPlayFromBeginning: { item in
                                playItemDirectly(item, fromBeginning: true)
                            },
                            onGoToItem: { item in
                                selectedItem = selectMediaItem(item)
                            },
                            onRefreshNeeded: {
                                await refresh()
                            },
                            onPreviewRequested: isContinueWatching ? nil : { request in
                                withAnimation(previewEntryAnimation) {
                                    rowPreviewRequest = request
                                    showPreviewCover = true
                                }
                            },
                            restorePreviewFocusTarget: $previewRestoreTarget,
                            onRowFocused: {
                                withAnimation(.smooth(duration: 0.8)) {
                                    scrollProxy.scrollTo(rowID, anchor: UnitPoint(x: 0.5, y: 0.5))
                                }
                            }
                        )
                        .id(rowID)

                        if enablePersonalizedRecommendations,
                           shouldShowRecommendationsRow,
                           continueWatchingIndex == index {
                            recommendationsSection(scrollProxy: scrollProxy)
                        }
                    }
                }
            }
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
            // Top padding is handled by the wrapping VStack in contentView,
            // which applies the same `heroActive ? 0 : 100` conditional once
            // for the whole block (essential + discovery + header + grid).
        }
    }

    // MARK: - Recommendations Section

    @ViewBuilder
    private func recommendationsSection(scrollProxy: ScrollViewProxy) -> some View {
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
        } else if !recommendations.isEmpty {
            let rowID = "library:\(libraryKey):recommendations"
            InfiniteContentRow(
                rowID: rowID,
                title: "Personalized Recommendations",
                initialItems: recommendations,
                hubKey: nil,
                hubIdentifier: nil,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? "",
                contextMenuSource: .library,
                onItemSelected: { item in
                    selectedItem = selectMediaItem(item)
                },
                onRefreshNeeded: {
                    await refreshRecommendations(force: true)
                },
                onPreviewRequested: { request in
                    withAnimation(previewEntryAnimation) {
                        rowPreviewRequest = request
                        showPreviewCover = true
                    }
                },
                restorePreviewFocusTarget: $previewRestoreTarget,
                onRowFocused: {
                    withAnimation(.smooth(duration: 0.8)) {
                        scrollProxy.scrollTo(rowID, anchor: UnitPoint(x: 0.5, y: 0.5))
                    }
                }
            )
            .id(rowID)
        }
    }

    // MARK: - Discovery Rows View (Rediscover, Recommendations, etc.)

    @ViewBuilder
    private func discoveryRowsView(scrollProxy: ScrollViewProxy) -> some View {
        if showLibraryRecommendations && !discoveryHubs.isEmpty {
            VStack(alignment: .leading, spacing: 40) {
                ForEach(discoveryHubs, id: \.hubIdentifier) { hub in
                    if let hubItems = hub.Metadata, !hubItems.isEmpty {
                        let rowID = libraryRowID(for: hub, section: "discovery", index: discoveryHubs.firstIndex(where: { $0.hubIdentifier == hub.hubIdentifier }) ?? 0)
                        InfiniteContentRow(
                            rowID: rowID,
                            title: hub.title ?? "Untitled",
                            initialItems: hubItems,
                            hubKey: hub.key ?? hub.hubKey,
                            hubIdentifier: hub.hubIdentifier,
                            serverURL: authManager.selectedServerURL ?? "",
                            authToken: authManager.selectedServerToken ?? "",
                            contextMenuSource: .library,
                            onItemSelected: { item in
                                selectedItem = selectMediaItem(item)
                            },
                            onRefreshNeeded: {
                                await refresh()
                            },
                            onPreviewRequested: { request in
                                withAnimation(previewEntryAnimation) {
                                    rowPreviewRequest = request
                                    showPreviewCover = true
                                }
                            },
                            restorePreviewFocusTarget: $previewRestoreTarget,
                            onRowFocused: {
                                withAnimation(.smooth(duration: 0.8)) {
                                    scrollProxy.scrollTo(rowID, anchor: UnitPoint(x: 0.5, y: 0.5))
                                }
                            }
                        )
                        .id(rowID)
                    }
                }
            }
            .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
            // Inter-section spacing handled by the wrapping VStack in contentView.
        }
    }

    // MARK: - Library Section Header

    private var librarySectionHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(libraryTitle)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .id("library-title-\(libraryKey)")  // Force instant update when library changes
                    .transaction { transaction in
                        // Disable animation for instant title update
                        transaction.animation = nil
                    }

                Text("\(totalItemCount > 0 ? totalItemCount : items.count) items")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            sortButton
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        // Inter-section spacing handled by the wrapping VStack in contentView
        // (48pt to the grid below). Previously this had an explicit 32pt
        // bottom padding on top of a 60pt top padding.
    }

    // MARK: - Sort Button

    @FocusState private var isSortButtonFocused: Bool

    private var sortButton: some View {
        Menu {
            ForEach(LibrarySortOption.options(for: currentLibraryType), id: \.self) { option in
                Button {
                    if currentSortOption != option {
                        currentSortOption = option
                        librarySettings.setSortOption(option, for: libraryKey)
                        Task {
                            await reloadWithNewSort(sortOption: option)
                        }
                    }
                } label: {
                    HStack {
                        Text(option.displayName)
                        if currentSortOption == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 20, weight: .semibold))

                Text(currentSortOption.displayName)
                    .font(.system(size: 20, weight: .medium))
            }
            .foregroundStyle(isSortButtonFocused ? .black : .white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSortButtonFocused ? .white : .white.opacity(0.15))
            )
            .scaleEffect(isSortButtonFocused ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
        .focusEffectDisabled()
        .focused($isSortButtonFocused)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSortButtonFocused)
    }

    private var currentLibraryType: String? {
        dataStore.libraries.first(where: { $0.key == libraryKey })?.type
    }

    private func reloadWithNewSort(sortOption: LibrarySortOption) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Clear cache for this library since sort changed
        let itemType = items.first?.type
        if itemType == "movie" {
            await cacheManager.clearMoviesCache(forLibrary: libraryKey)
        } else if itemType == "show" {
            await cacheManager.clearShowsCache(forLibrary: libraryKey)
        }

        // Fetch new sorted items without clearing existing display
        // This keeps the hubs visible and only updates the grid
        hasMoreItems = true

        do {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: pageSize,
                sort: sortOption.apiParameter
            )

            // Update total count
            if let total = result.totalSize {
                totalItemCount = total
                hasMoreItems = result.items.count < total
            } else {
                hasMoreItems = result.items.count >= pageSize
            }

            // Replace items with new sorted results
            items = result.items

            // Cache the new results
            if itemType == "movie" {
                await cacheManager.cacheMovies(result.items, forLibrary: libraryKey)
            } else if itemType == "show" {
                await cacheManager.cacheShows(result.items, forLibrary: libraryKey)
            }
        } catch {
            print("Failed to reload with new sort: \(error)")
        }
    }

    // MARK: - Library Grid View

    private var libraryGridView: some View {
        // NOTE: visibleItemCount batching removed — LazyVGrid already only
        // measures on-screen items. Batching added complexity and could break
        // scroll/focus restoration when returning from detail views.
        // If performance regresses on first load, re-enable the batching logic
        // (see visibleItemCount, updateVisibleItems, initialVisibleBatch).

        LazyVGrid(columns: columns, spacing: 40) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                libraryGridItem(item: item, index: index)
            }
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.vertical, 28)
        .padding(.bottom, 60)
        .focusSection()  // Help focus engine navigate the grid efficiently
    }

    @ViewBuilder
    private func libraryGridItem(item: PlexMetadata, index: Int) -> some View {
        Button {
            selectedItem = selectMediaItem(item)
        } label: {
            // EquatableView tells SwiftUI to use our custom == to skip unnecessary re-renders
            EquatableView(content: MediaPosterCard(
                item: item,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? ""
            ))
        }
        .buttonStyle(CardButtonStyle())
        .focused($focusedItemId, equals: gridFocusId(for: item))
        .onAppear {
            // Trigger loading more items when nearing the end
            if index >= items.count - 12 && hasMoreItems && !isLoadingMore {
                Task { await loadMoreItems() }
            }
            // Prefetch images ahead of scroll position
            if index > lastPrefetchIndex + 3 {
                lastPrefetchIndex = index
                prefetchImagesAhead(from: index)
            }
        }
        .mediaItemContextMenu(
            item: item,
            serverURL: authManager.selectedServerURL ?? "",
            authToken: authManager.selectedServerToken ?? "",
            source: .library,
            onRefreshNeeded: {
                await refresh()
            }
        )
    }

    // MARK: - Loading View (Skeleton Placeholders)

    private var loadingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Skeleton header
                skeletonHeader

                // Skeleton grid
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(0..<18, id: \.self) { _ in
                        skeletonPosterCard
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, 28)
            }
        }
    }

    private var skeletonHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title placeholder
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 200, height: 32)

            // Subtitle placeholder
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.05))
                .frame(width: 80, height: 17)
        }
        .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
        .padding(.top, 60)
        .padding(.bottom, 32)
    }

    private var skeletonPosterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Poster placeholder - square for music, rectangle for video
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 220, height: isMusicLibrary ? 220 : 330)

            // Title placeholder
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
                Task { await refresh() }
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

            Text("This library appears to be empty.")
                .font(.body)
                .foregroundStyle(.secondary)

            Button {
                Task { await refresh() }
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

    // MARK: - Data Loading

    /// Full load with loading state (used when no cache exists)
    private func loadItems() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            error = "Not authenticated"
            items = []
            hubs = []
            return
        }

        // No cache - show loading and fetch both
        isLoading = true
        async let itemsFetch: () = fetchFromServer(serverURL: serverURL, token: token, updateLoading: true)
        async let hubsFetch: () = fetchLibraryHubs(serverURL: serverURL, token: token)
        _ = await (itemsFetch, hubsFetch)
        // Select hero after data loads
        selectHeroItems()
    }

    /// Background refresh without loading state (used when cache exists)
    private func loadItemsInBackground() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Fetch items and hubs silently in background, skipping hubs if recently fetched
        let hubsFresh = dataStore.isFresh("libraryHubs:\(libraryKey)", within: 60)
        async let itemsFetch: () = fetchFromServer(serverURL: serverURL, token: token, updateLoading: false)
        if !hubsFresh {
            async let hubsFetch: () = fetchLibraryHubs(serverURL: serverURL, token: token)
            _ = await (itemsFetch, hubsFetch)
        } else {
            await itemsFetch
        }

        // Refresh the promoted-hub carousel now that hubs may have changed.
        selectHeroItems()
    }

    // MARK: - Direct Playback (used by the hero carousel's Play button)

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

    private func getPlayerImages(for metadata: PlexMetadata, serverURL: String, authToken: String) async -> (UIImage?, UIImage?) {
        let request = metadata.heroBackdropRequest(
            serverURL: serverURL,
            authToken: authToken
        )
        return await HeroBackdropResolver.shared.playerLoadingImages(for: request)
    }

    private func getCachedItems() async -> [PlexMetadata] {
        // Determine type based on library (this is simplified - ideally we'd know the library type)
        if let cached = await cacheManager.getCachedMovies(forLibrary: libraryKey) {
            return cached
        }
        if let cached = await cacheManager.getCachedShows(forLibrary: libraryKey) {
            return cached
        }
        return []
    }

    // MARK: - Personalized Recommendations

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
                contentType: recommendationsContentType,
                libraryKey: shouldShowRecommendationsRow ? libraryKey : nil
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

    private func isContinueWatchingHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return identifier.contains("continuewatching") || title.contains("continue watching")
    }

    private let pageSize = 60  // Smaller initial batch to reduce main-thread layout work

    private func fetchFromServer(serverURL: String, token: String, updateLoading: Bool) async {
        do {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: pageSize,
                sort: currentSortOption.apiParameter
            )

            // Update total count for pagination
            if let total = result.totalSize {
                totalItemCount = total
                hasMoreItems = result.items.count < total
            } else {
                // If no totalSize, assume there might be more if we got a full page
                hasMoreItems = result.items.count >= pageSize
            }

            // Only update items if they're actually different (prevents unnecessary re-renders).
            // When refreshing in background (!updateLoading), don't truncate if we already
            // have more items loaded via infinite scroll — just update the overlapping portion.
            if !updateLoading && items.count > result.items.count {
                // Merge: update existing items with fresh data, keep the rest
                var merged = items
                let existingKeys = Dictionary(uniqueKeysWithValues: result.items.compactMap { item in
                    item.ratingKey.map { ($0, item) }
                })
                for i in merged.indices {
                    if let key = merged[i].ratingKey, let fresh = existingKeys[key] {
                        merged[i] = fresh
                    }
                }
                if !itemsAreEqual(items, merged) {
                    items = merged
                }
            } else if !itemsAreEqual(items, result.items) {
                items = result.items
            }

            // Cache based on type
            if let firstItem = result.items.first {
                if firstItem.type == "movie" {
                    await cacheManager.cacheMovies(result.items, forLibrary: libraryKey)
                } else if firstItem.type == "show" {
                    await cacheManager.cacheShows(result.items, forLibrary: libraryKey)
                }
            }

            dataStore.recordFetch(for: "libraryItems:\(libraryKey)")
            error = nil
        } catch {
            // Ignore cancellation errors - they happen when views are recreated
            if (error as NSError).code == NSURLErrorCancelled {
                if updateLoading { isLoading = false }
                return
            }
            if items.isEmpty {
                self.error = error.localizedDescription
            }
        }
        if updateLoading { isLoading = false }
    }

    /// Load more items for infinite scroll
    private func loadMoreItems() async {
        guard hasMoreItems,
              !isLoadingMore,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        isLoadingMore = true

        do {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: items.count,
                size: pageSize,
                sort: currentSortOption.apiParameter
            )

            // Update total count
            if let total = result.totalSize {
                totalItemCount = total
            }

            if result.items.isEmpty {
                // No more items
                hasMoreItems = false
            } else {
                // Append new items, avoiding duplicates
                let existingKeys = Set(items.compactMap { $0.ratingKey })
                let newItems = result.items.filter { item in
                    guard let key = item.ratingKey else { return false }
                    return !existingKeys.contains(key)
                }

                if !newItems.isEmpty {
                    items.append(contentsOf: newItems)
                    if let firstItem = items.first {
                        if firstItem.type == "movie" {
                            await cacheManager.cacheMovies(items, forLibrary: libraryKey)
                        } else if firstItem.type == "show" {
                            await cacheManager.cacheShows(items, forLibrary: libraryKey)
                        }
                    }
                }

                // Check if we've reached the end
                if let total = result.totalSize {
                    hasMoreItems = items.count < total
                } else {
                    hasMoreItems = result.items.count >= pageSize
                }
            }
        } catch {
            // Ignore errors for pagination - just stop loading more
            if (error as NSError).code != NSURLErrorCancelled {
                print("Failed to load more items: \(error)")
            }
        }

        isLoadingMore = false
    }

    /// Compare two item arrays by ratingKey to avoid unnecessary state updates
    private func itemsAreEqual(_ lhs: [PlexMetadata], _ rhs: [PlexMetadata]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        // Compare by ratingKey which is the unique identifier
        let lhsKeys = lhs.compactMap { $0.ratingKey }
        let rhsKeys = rhs.compactMap { $0.ratingKey }
        return lhsKeys == rhsKeys
    }

    private func fetchLibraryHubs(serverURL: String, token: String) async {
        do {
            let fetchedHubs = try await networkManager.getLibraryHubs(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey
            )

            // Only update hubs if they're actually different
            if !hubsAreEqual(hubs, fetchedHubs) {
                hubs = fetchedHubs
                cachedProcessedHubs = computeProcessedHubs(from: fetchedHubs)
            }

            // Write back to DataStore for cross-view sharing
            dataStore.libraryHubs[libraryKey] = fetchedHubs
            dataStore.recordFetch(for: "libraryHubs:\(libraryKey)")

            // Cache for instant loading next time
            await cacheManager.cacheLibraryHubs(fetchedHubs, forLibrary: libraryKey)
        } catch {
            // Ignore cancellation errors
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            print("📚 Failed to fetch hubs for library \(libraryKey): \(error)")
            // Don't show error for hubs - they're optional enhancement
        }
    }

    /// Compare two hub arrays to avoid unnecessary state updates
    private func hubsAreEqual(_ lhs: [PlexHub], _ rhs: [PlexHub]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        // Compare by hubIdentifier and item counts
        for (l, r) in zip(lhs, rhs) {
            if l.hubIdentifier != r.hubIdentifier { return false }
            if l.Metadata?.count != r.Metadata?.count { return false }
        }
        return true
    }

    private func refresh() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        isLoading = true
        async let itemsFetch: () = fetchFromServer(serverURL: serverURL, token: token, updateLoading: true)
        async let hubsFetch: () = fetchLibraryHubs(serverURL: serverURL, token: token)
        _ = await (itemsFetch, hubsFetch)

        if enablePersonalizedRecommendations {
            await refreshRecommendations(force: true)
        }
    }

    // MARK: - Navigation Helpers

    /// Convert a PlexMetadata item to a MediaItem for navigation.
    private func selectMediaItem(_ meta: PlexMetadata) -> MediaItem? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
        return PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
    }

// MARK: - Focus Management

    /// Prefetch poster images for visible and upcoming items
    private func prefetchImages() {
        guard !items.isEmpty,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        hasPrefetched = true

        // Prefetch first 20 items (visible + next row)
        let prefetchCount = min(20, items.count)
        let urlsToPreload: [URL] = items.prefix(prefetchCount).compactMap { item in
            guard let thumb = posterThumb(for: item) else { return nil }
            var urlString = "\(serverURL)\(thumb)"
            if !urlString.contains("X-Plex-Token") {
                urlString += urlString.contains("?") ? "&" : "?"
                urlString += "X-Plex-Token=\(token)"
            }
            return URL(string: urlString)
        }

        // Fire off prefetch in background
        Task.detached(priority: .background) {
            await ImageCacheManager.shared.prefetch(urls: urlsToPreload)
        }
    }

    /// Prefetch images ahead of the current scroll position
    /// Called frequently to ensure images are loaded before user reaches them
    private func prefetchImagesAhead(from index: Int) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Prefetch the next 30 items (~5 rows of 6) ahead of current position
        let prefetchStart = index + 3  // Start just ahead of current position
        let prefetchEnd = min(prefetchStart + 30, items.count)

        guard prefetchStart < items.count else { return }

        let itemsToPrefetch = Array(items[prefetchStart..<prefetchEnd])
        guard !itemsToPrefetch.isEmpty else { return }

        let urlsToPreload: [URL] = itemsToPrefetch.compactMap { item in
            guard let thumb = posterThumb(for: item) else { return nil }
            var urlString = "\(serverURL)\(thumb)"
            if !urlString.contains("X-Plex-Token") {
                urlString += urlString.contains("?") ? "&" : "?"
                urlString += "X-Plex-Token=\(token)"
            }
            return URL(string: urlString)
        }

        guard !urlsToPreload.isEmpty else { return }

        // Fire off prefetch with utility priority for timely loading
        Task.detached(priority: .utility) {
            await ImageCacheManager.shared.prefetch(urls: urlsToPreload)
        }
    }

    /// Handle items count change - triggers prefetch on tvOS
    private func handleItemsCountChange(oldCount: Int, newCount: Int) {
        // Batching disabled — LazyVGrid handles lazy rendering natively.
        // if newCount == 0 {
        //     visibleItemExpandTask?.cancel()
        //     visibleItemCount = 0
        // } else if oldCount == 0 {
        //     updateVisibleItems(for: newCount, animated: true)
        // } else if newCount > visibleItemCount {
        //     updateVisibleItems(for: newCount, animated: false)
        // }

        if oldCount == 0 && newCount > 0 {
            prefetchImages()
        } else if !hasPrefetched && newCount > 0 {
            prefetchImages()
        }
        ensureInitialFocusIfNeeded()
    }

    // Batching disabled — LazyVGrid handles lazy rendering natively.
    // Uncomment if first-load performance regresses.
    /*
    /// Limit first-frame grid layout to a small batch, then reveal the rest
    private func updateVisibleItems(for total: Int, animated: Bool) {
        guard total > 0 else {
            visibleItemCount = 0
            return
        }

        visibleItemExpandTask?.cancel()

        // If we're already showing most items, just jump to total
        if !animated || total <= initialVisibleBatch {
            visibleItemCount = total
            return
        }

        let initial = min(initialVisibleBatch, total)
        visibleItemCount = initial

        visibleItemExpandTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
            await MainActor.run {
                visibleItemCount = total
            }
        }
    }
    */

    /// Whether the library hero is currently on screen.
    private var heroIsActive: Bool {
        showLibraryHero && !heroItems.isEmpty
    }

    /// Ensure the first grid item receives focus when entering a library.
    ///
    /// When the library hero is on screen it owns the initial focus (its Play
    /// button), so we must NOT pull focus down into the grid; doing so buries
    /// the hero under the poster rows. This only bit freshly-loaded libraries:
    /// their items arrive via an `items.count` change that fires this, whereas
    /// cache-warm libraries never trip it. `selectHeroItems()` runs just before
    /// this in the same change handler, so `heroIsActive` is already true here
    /// for hero libraries.
    private func ensureInitialFocusIfNeeded() {
        guard !heroIsActive else { return }
        guard focusedItemId == nil else { return }
        guard let first = firstDisplayedItem else { return }

        focusedItemId = gridFocusId(for: first)
    }

    private func posterThumb(for item: PlexMetadata) -> String? {
        if item.type == "episode" {
            return item.grandparentThumb ?? item.parentThumb ?? item.thumb
        }
        return item.thumb
    }
}

#Preview {
    NavigationStack {
        PlexLibraryView(libraryKey: "1", libraryTitle: "Movies")
    }
}
