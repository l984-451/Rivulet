//
//  PlexHomeView.swift
//  Rivulet
//
//  Home screen for Plex with Continue Watching and Recently Added
//

import SwiftUI
import Combine

struct PlexHomeView: View {
    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var authManager = PlexAuthManager.shared
    @AppStorage("showHomeHero") private var showHomeHero = false
    @AppStorage("enablePersonalizedRecommendations") private var enablePersonalizedRecommendations = false
    @Environment(\.nestedNavigationState) private var nestedNavState
    @Environment(\.focusScopeManager) private var focusScopeManager
    @Environment(\.isSidebarVisible) private var isSidebarVisible
    @State private var selectedItem: PlexMetadata?
    @State private var heroItem: PlexMetadata?
    @State private var cachedProcessedHubs: [PlexHub] = []  // Memoized to avoid recalculation on every render
    @State private var recommendations: [PlexMetadata] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationsError: String?
    @FocusState private var focusedItemId: String?  // Tracks focused item by "context:itemId" format

    private let recommendationService = PersonalizedRecommendationService.shared
    private let recommendationsContentType: RecommendationContentType = .moviesAndShows

    // MARK: - Processed Hubs (merged Continue Watching + On Deck)

    /// Computes processed hubs - called only when dataStore.hubs changes
    private func computeProcessedHubs(from hubsToProcess: [PlexHub]) -> [PlexHub] {
        var result: [PlexHub] = []
        var continueWatchingItems: [PlexMetadata] = []
        var seenRatingKeys: Set<String> = []

        // Check if music library is visible in sidebar
        let showMusicHubs = dataStore.hasMusicLibraryVisible

        for hub in hubsToProcess {
            let identifier = hub.hubIdentifier?.lowercased() ?? ""
            let title = hub.title?.lowercased() ?? ""

            // Filter out playlists - never show on home page
            let isPlaylist = identifier.contains("playlist") || title.contains("playlist")
            if isPlaylist {
                continue
            }

            // Filter out music hubs unless music library is in sidebar
            let isMusicHub = identifier.contains("music") ||
                            identifier.contains("artist") ||
                            identifier.contains("album") ||
                            title.contains("music") ||
                            title.contains("recently added in music")
            if isMusicHub && !showMusicHubs {
                continue
            }

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
                // Keep other hubs as-is
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
            var mergedHub = PlexHub()
            mergedHub.hubIdentifier = "continueWatching"
            mergedHub.title = "Continue Watching"
            mergedHub.Metadata = continueWatchingItems
            // Insert at beginning
            result.insert(mergedHub, at: 0)
        }

        return result
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
                if enablePersonalizedRecommendations {
                    await refreshRecommendations(force: true)
                }
            }
            .onAppear {
                // Initial computation of processed hubs
                if cachedProcessedHubs.isEmpty && !dataStore.hubs.isEmpty {
                    cachedProcessedHubs = computeProcessedHubs(from: dataStore.hubs)
                }
                // Only select hero if we don't have one yet
                if heroItem == nil {
                    selectHeroItem()
                }
                if enablePersonalizedRecommendations && recommendations.isEmpty {
                    Task { await refreshRecommendations(force: false) }
                }
            }
            .onChange(of: dataStore.hubsVersion) { _, _ in
                // Recompute cached hubs when source data changes (including item properties like viewCount)
                cachedProcessedHubs = computeProcessedHubs(from: dataStore.hubs)
                // Only reselect hero if we don't have one yet (avoid redundant selection)
                if heroItem == nil {
                    selectHeroItem()
                }
            }
            .onChange(of: dataStore.hasMusicLibraryVisible) { _, _ in
                // Recompute hubs when music library visibility changes
                // This ensures music hubs appear/disappear when library is pinned/unpinned
                cachedProcessedHubs = computeProcessedHubs(from: dataStore.hubs)
            }
            .onChange(of: enablePersonalizedRecommendations) { _, _ in
                handleRecommendationsToggle()
            }
            // Refresh hubs when notified (e.g., after playback ends, watch status changes)
            .onReceive(NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)) { _ in
                Task {
                    await dataStore.refreshHubs()
                    if enablePersonalizedRecommendations {
                        await refreshRecommendations(force: true)
                    }
                }
            }
            .navigationDestination(item: $selectedItem) { item in
                PlexDetailView(item: item)
            }
        }
        // Tell parent we're in nested navigation when viewing detail
        .onChange(of: selectedItem) { _, newValue in
            let isNested = newValue != nil
            nestedNavState.isNested = isNested
            if isNested {
                // Set the go back action to clear selectedItem
                nestedNavState.goBackAction = { [weak nestedNavState] in
                    selectedItem = nil
                    nestedNavState?.isNested = false
                }
            } else {
                nestedNavState.goBackAction = nil
            }
        }
        // Save focus when it changes (only when content scope is active)
        .onChange(of: focusedItemId) { _, newValue in
            guard focusScopeManager.isScopeActive(.content) else {
                // Scope not active, don't track focus changes
                return
            }
            if let newValue {
                // Parse context:itemId format and save to focus manager
                let parts = newValue.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    focusScopeManager.setFocus(
                        itemId: String(parts[1]),
                        context: String(parts[0]),
                        scope: .content
                    )
                } else {
                    focusScopeManager.setFocus(itemId: newValue, scope: .content)
                }
            }
        }
        // Restore focus when scope becomes active
        .onChange(of: focusScopeManager.restoreTrigger) { _, _ in
            // Only restore focus if not in nested navigation (detail view)
            if selectedItem == nil,
               focusScopeManager.isScopeActive(.content),
               let savedItem = focusScopeManager.focusedItem {
                // Reconstruct the composite ID
                if let context = savedItem.context {
                    focusedItemId = "\(context):\(savedItem.itemId)"
                } else {
                    focusedItemId = savedItem.itemId
                }
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
                        selectedItem = metadata
                    }
                } catch {
                    print("❌ [Navigation] Failed to fetch metadata for ratingKey \(ratingKey): \(error)")
                }
            }
        }
    }

    // MARK: - Hero Selection

    private func selectHeroItem() {
        // Check cache first - hero persists across navigation
        if let cachedHero = dataStore.getCachedHero(forLibrary: "home") {
            heroItem = cachedHero
            return
        }

        // Pick a random item from recently added for the hero
        let recentlyAdded = dataStore.hubs.first { hub in
            hub.hubIdentifier?.contains("recentlyAdded") == true ||
            hub.title?.lowercased().contains("recently added") == true
        }
        if let items = recentlyAdded?.Metadata, !items.isEmpty {
            if let newHero = items.randomElement() {
                heroItem = newHero
                dataStore.cacheHero(newHero, forLibrary: "home")
            }
        } else if let firstHub = dataStore.hubs.first,
                  let items = firstHub.Metadata, !items.isEmpty {
            if let newHero = items.first {
                heroItem = newHero
                dataStore.cacheHero(newHero, forLibrary: "home")
            }
        }
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

    private func isContinueWatchingHub(_ hub: PlexHub) -> Bool {
        let identifier = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return identifier.contains("continuewatching") || title.contains("continue watching")
    }

    // MARK: - Content View

    private var contentView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Connection error banner (when showing cached content while offline)
                if !authManager.isConnected {
                    connectionErrorBanner
                }

                // Hero section (if enabled)
                if showHomeHero, let hero = heroItem {
                    HeroView(
                        item: hero,
                        serverURL: authManager.selectedServerURL ?? "",
                        authToken: authManager.selectedServerToken ?? "",
                        focusTarget: $focusedItemId,
                        targetValue: "hero"
                    ) {
                        selectedItem = hero
                    }
                }

                if enablePersonalizedRecommendations {
                    EmptyView() // Recommendations are injected below Continue Watching
                }

                // Content rows (uses cached processedHubs which merges Continue Watching + On Deck)
                VStack(alignment: .leading, spacing: 48) {
                    let continueWatchingIndex = cachedProcessedHubs.firstIndex(where: isContinueWatchingHub)
                    ForEach(Array(cachedProcessedHubs.enumerated()), id: \.element.id) { index, hub in
                        if let items = hub.Metadata, !items.isEmpty {
                            let isContinueWatching = isContinueWatchingHub(hub)
                            InfiniteContentRow(
                                title: hub.title ?? "Unknown",
                                initialItems: items,
                                hubKey: hub.key ?? hub.hubKey,
                                hubIdentifier: hub.hubIdentifier,
                                serverURL: authManager.selectedServerURL ?? "",
                                authToken: authManager.selectedServerToken ?? "",
                                contextMenuSource: isContinueWatching ? .continueWatching : .other,
                                onItemSelected: { item in
                                    selectedItem = item
                                },
                                onRefreshNeeded: {
                                    await dataStore.refreshHubs()
                                },
                                onGoToSeason: { episode in
                                    navigateToSeason(for: episode)
                                },
                                onGoToShow: { episode in
                                    navigateToShow(for: episode)
                                }
                            )
                        }

                        if enablePersonalizedRecommendations,
                           continueWatchingIndex == index {
                            recommendationsSection
                        }
                    }
                }
                .padding(.top, 48)
                .padding(.bottom, 500)  // Large padding prevents aggressive end-of-content scroll
            }
        }
        .scrollClipDisabled()  // Allow shadow overflow
        #if os(tvOS)
        .ignoresSafeArea(edges: .top)
        .defaultFocus($focusedItemId, "hero")  // Set initial focus to hero
        #endif
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

            Button {
                Task {
                    await authManager.verifyAndFixConnection()
                    if authManager.isConnected {
                        await dataStore.refreshHubs()
                    }
                }
            } label: {
                Text("Retry")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.2))
                    )
            }
            .buttonStyle(.plain)
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
        .padding(.horizontal, 80)
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
            .padding(.horizontal, 80)
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
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 12)
        } else if !recommendations.isEmpty {
            InfiniteContentRow(
                title: "Personalized Recommendations",
                initialItems: recommendations,
                hubKey: nil,
                hubIdentifier: nil,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? "",
                contextMenuSource: .other,
                onItemSelected: { item in
                    selectedItem = item
                },
                onRefreshNeeded: {
                    await refreshRecommendations(force: true)
                },
                onGoToSeason: { episode in
                    navigateToSeason(for: episode)
                },
                onGoToShow: { episode in
                    navigateToShow(for: episode)
                }
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
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.2))
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
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.2))
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

    /// Navigate to the season containing the given episode
    private func navigateToSeason(for episode: PlexMetadata) {
        guard let seasonKey = episode.parentRatingKey,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        Task {
            do {
                let season = try await PlexNetworkManager.shared.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonKey
                )
                await MainActor.run {
                    selectedItem = season
                }
            } catch {
                print("Failed to navigate to season: \(error)")
            }
        }
    }

    /// Navigate to the show containing the given episode
    private func navigateToShow(for episode: PlexMetadata) {
        guard let showKey = episode.grandparentRatingKey,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        Task {
            do {
                let show = try await PlexNetworkManager.shared.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: showKey
                )
                await MainActor.run {
                    selectedItem = show
                }
            } catch {
                print("Failed to navigate to show: \(error)")
            }
        }
    }
}

// MARK: - Hero View

struct HeroView<FocusTarget: Hashable>: View {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let onSelect: () -> Void

    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.isSidebarVisible) private var isSidebarVisible

    // Hero art image loaded at full size with guaranteed off-main-thread decoding
    @State private var heroArtImage: UIImage?

    // Focus binding - supports both Bool and enum-based patterns
    private let focusBinding: FocusBinding<FocusTarget>

    enum FocusBinding<T: Hashable> {
        case bool(FocusState<Bool>.Binding)
        case enumTarget(FocusState<T?>.Binding, T)
    }

    /// Initialize with boolean focus binding (for PlexHomeView compatibility)
    init(
        item: PlexMetadata,
        serverURL: String,
        authToken: String,
        isPlayButtonFocused: FocusState<Bool>.Binding,
        onSelect: @escaping () -> Void
    ) where FocusTarget == Bool {
        self.item = item
        self.serverURL = serverURL
        self.authToken = authToken
        self.focusBinding = .bool(isPlayButtonFocused)
        self.onSelect = onSelect
    }

    /// Initialize with enum-based focus binding (for unified focus management)
    init(
        item: PlexMetadata,
        serverURL: String,
        authToken: String,
        focusTarget: FocusState<FocusTarget?>.Binding,
        targetValue: FocusTarget,
        onSelect: @escaping () -> Void
    ) {
        self.item = item
        self.serverURL = serverURL
        self.authToken = authToken
        self.focusBinding = .enumTarget(focusTarget, targetValue)
        self.onSelect = onSelect
    }

    private var isFocused: Bool {
        switch focusBinding {
        case .bool(let binding):
            return binding.wrappedValue
        case .enumTarget(let binding, let target):
            return binding.wrappedValue == target
        }
    }

    private var artURL: URL? {
        // Prefer art (backdrop) over thumb (poster)
        let path = item.art ?? item.thumb
        guard let path else { return nil }
        var urlString = "\(serverURL)\(path)"
        if !urlString.contains("X-Plex-Token") {
            urlString += urlString.contains("?") ? "&" : "?"
            urlString += "X-Plex-Token=\(authToken)"
        }
        return URL(string: urlString)
    }

    var body: some View {
        #if os(tvOS)
        heroButtonView
            .task(id: artURL) {
                await loadHeroArt()
            }
        #else
        heroContentView
            .frame(height: 400)
            .task(id: artURL) {
                await loadHeroArt()
            }
        #endif
    }

    /// Load hero art at full size with guaranteed off-main-thread decoding
    private func loadHeroArt() async {
        guard let url = artURL else {
            heroArtImage = nil
            return
        }
        heroArtImage = await ImageCacheManager.shared.imageFullSize(for: url)
    }

    private var heroContentView: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Background art - full width edge to edge
                // Uses imageFullSize() for guaranteed off-main-thread PNG decoding (fixes RIVULET-C)
                if let heroArtImage {
                    Image(uiImage: heroArtImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.15), Color(white: 0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                // Gradient overlay for text legibility (simplified 2-stop gradient)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .init(x: 0.5, y: 0.4),  // Start fade at 40% from top
                    endPoint: .bottom
                )

                // Content info
                VStack(alignment: .leading, spacing: 16) {
                    // Type badge
                    if let type = item.type {
                        Text(type.uppercased())
                            .font(.system(size: 15, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    // Title
                    Text(item.title ?? "")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    // Metadata row
                    HStack(spacing: 16) {
                        if let year = item.year {
                            Text(String(year))
                        }
                        if let rating = item.contentRating {
                            Text(rating)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if let duration = item.duration {
                            Text(formatDuration(duration))
                        }
                    }
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                    // Summary (truncated)
                    if let summary = item.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 19))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .frame(maxWidth: 800, alignment: .leading)
                    }

                    #if os(tvOS)
                    // More Info indicator
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text("More Info")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(isFocused ? 0.3 : 0.15))
                    )
                    .opacity(isFocused ? 1 : 0.7)
                    .padding(.top, 8)
                    #endif
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 70)
            }
        }
    }

    #if os(tvOS)
    @ViewBuilder
    private var heroButtonView: some View {
        switch focusBinding {
        case .bool(let binding):
            Button(action: onSelect) {
                heroContentView
            }
            .buttonStyle(.plain)
            .focused(binding)
            .frame(height: 750)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(.horizontal, 48)
            .padding(.top, 20)
            // Simplified focus effect: removed brightness (CPU-intensive color matrix)
            // Scale + stroke provides sufficient visual feedback
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(.white.opacity(isFocused ? 0.4 : 0), lineWidth: 4)
                    .padding(.horizontal, 48)
                    .padding(.top, 20)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isFocused)  // Faster de-focus
            .onMoveCommand { direction in
                // Ignore input when sidebar is visible
                guard !isSidebarVisible else { return }
                if direction == .left {
                    openSidebar()
                }
            }

        case .enumTarget(let binding, let target):
            Button(action: onSelect) {
                heroContentView
            }
            .buttonStyle(.plain)
            .focused(binding, equals: target)
            .frame(height: 750)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(.horizontal, 48)
            .padding(.top, 20)
            // Simplified focus effect: removed brightness (CPU-intensive color matrix)
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(.white.opacity(isFocused ? 0.4 : 0), lineWidth: 4)
                    .padding(.horizontal, 48)
                    .padding(.top, 20)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isFocused)  // Faster de-focus
            .onMoveCommand { direction in
                // Ignore input when sidebar is visible
                guard !isSidebarVisible else { return }
                if direction == .left {
                    openSidebar()
                }
            }
        }
    }
    #endif

    private func formatDuration(_ ms: Int) -> String {
        let minutes = ms / 60000
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(mins)m"
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
        VStack(alignment: .leading, spacing: 24) {
            // Section title
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 80)

            // Horizontal scroll of posters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
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
                        #if os(tvOS)
                        .buttonStyle(CardButtonStyle())
                        #else
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 32)  // Room for scale effect and shadow
            }
            .scrollClipDisabled()  // Allow shadow overflow
        }
    }
}

// MARK: - Infinite Content Row (with endless scrolling)

/// A content row that loads more items as the user scrolls near the end
struct InfiniteContentRow: View {
    let title: String
    let initialItems: [PlexMetadata]
    let hubKey: String?  // The hub's key for fetching more items
    let hubIdentifier: String?  // The hub's identifier (e.g., "home.movies.recent") - needed for /hubs/items endpoint
    let serverURL: String
    let authToken: String
    var contextMenuSource: MediaItemContextSource = .other
    var onItemSelected: ((PlexMetadata) -> Void)?
    var onRefreshNeeded: MediaItemRefreshCallback?
    var onGoToSeason: ((PlexMetadata) -> Void)?
    var onGoToShow: ((PlexMetadata) -> Void)?

    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.focusScopeManager) private var focusScopeManager
    @Environment(\.isSidebarVisible) private var isSidebarVisible

    @State private var items: [PlexMetadata] = []
    @State private var isLoadingMore = false
    @State private var hasReachedEnd = false
    @State private var totalSize: Int?
    @FocusState private var focusedItemId: String?  // Track which item is focused (format: "context:itemId")

    /// Create a unique focus ID for an item in this row
    private func focusId(for item: PlexMetadata) -> String {
        "\(title):\(item.ratingKey ?? "")"
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
        VStack(alignment: .leading, spacing: 2) {
            // Section title with item count
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                if let total = totalSize, total > items.count {
                    Text("\(items.count) of \(total)")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                } else if hasReachedEnd && items.count > pageSize {
                    Text("All \(items.count)")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 80)

            // Horizontal scroll of posters with infinite loading
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {  // Lazy to avoid laying out hundreds of offscreen posters
                    ForEach(Array(items.enumerated()), id: \.element.ratingKey) { index, item in
                        Button {
                            onItemSelected?(item)
                        } label: {
                            MediaPosterCard(
                                item: item,
                                serverURL: serverURL,
                                authToken: authToken
                            )
                        }
                        #if os(tvOS)
                        .buttonStyle(CardButtonStyle())
                        .focused($focusedItemId, equals: focusId(for: item))
                        .modifier(LeftEdgeSidebarTrigger(isFirstItem: index == 0, openSidebar: openSidebar))
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .mediaItemContextMenu(
                            item: item,
                            serverURL: serverURL,
                            authToken: authToken,
                            source: contextMenuSource,
                            onRefreshNeeded: onRefreshNeeded,
                            onGoToSeason: onGoToSeason != nil ? { onGoToSeason?(item) } : nil,
                            onGoToShow: onGoToShow != nil ? { onGoToShow?(item) } : nil
                        )
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
                .padding(.horizontal, 80)
                .padding(.vertical, 32)  // Room for scale effect and shadow
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
            items = initialItems
            hasReachedEnd = false
        }
        .focusSection()
        #if os(tvOS)
        // Save focus when it changes (only when content scope is active)
        .onChange(of: focusedItemId) { _, newValue in
            guard focusScopeManager.isScopeActive(.content) else { return }
            if let newValue {
                // Parse context:itemId format
                let parts = newValue.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    focusScopeManager.setFocus(
                        itemId: String(parts[1]),
                        context: String(parts[0]),
                        scope: .content
                    )
                }
            }
        }
        // Restore focus when scope becomes active
        .onChange(of: focusScopeManager.restoreTrigger) { _, _ in
            guard focusScopeManager.isScopeActive(.content),
                  let savedItem = focusScopeManager.focusedItem,
                  savedItem.context == title else { return }
            // Check if this row contains the saved item
            if items.contains(where: { $0.ratingKey == savedItem.itemId }) {
                focusedItemId = "\(title):\(savedItem.itemId)"
            }
        }
        #endif
    }

    /// Skeleton placeholder card shown while loading more items
    private var loadingIndicator: some View {
        skeletonPosterCard
    }

    /// Single skeleton poster card matching MediaPosterCard dimensions
    private var skeletonPosterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Poster placeholder - square for music, rectangle for video
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
                #if os(tvOS)
                .frame(width: 220, height: isMusicRow ? 220 : 330)
                #else
                .frame(width: 180, height: isMusicRow ? 180 : 270)
                #endif

            // Title placeholder
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.04))
                    .frame(width: 100, height: 12)
            }
            #if os(tvOS)
            .frame(height: 52, alignment: .top)
            #else
            .frame(height: 44, alignment: .top)
            #endif
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

// MARK: - Left Edge Sidebar Trigger Modifier

/// A modifier that only adds onMoveCommand to the first item in a row
struct LeftEdgeSidebarTrigger: ViewModifier {
    let isFirstItem: Bool
    let openSidebar: () -> Void

    @Environment(\.isSidebarVisible) private var isSidebarVisible

    func body(content: Content) -> some View {
        if isFirstItem {
            content.onMoveCommand { direction in
                // Ignore input when sidebar is visible
                guard !isSidebarVisible else { return }
                if direction == .left {
                    openSidebar()
                }
            }
        } else {
            content
        }
    }
}

#Preview {
    PlexHomeView()
        .preferredColorScheme(.dark)
}
