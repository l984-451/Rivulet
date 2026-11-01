// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexDataStore.swift
//  Rivulet
//
//  Shared data store for Plex content that persists across view recreations
//

import Foundation
import Combine
import Sentry
import UIKit

@MainActor
class PlexDataStore: ObservableObject {
    static let shared = PlexDataStore()

    // MARK: - Published State

    @Published var hubs: [PlexHub] = []
    /// Continue Watching hub fetched from Plex's dedicated `/hubs/continueWatching`
    /// endpoint — matches what Plex's own apps display (respects user dismissals and
    /// library exclusion settings). Nil until first fetch completes.
    @Published var continueWatchingHub: PlexHub?
    /// True once a Continue Watching fetch has completed (without throwing)
    /// for the current account/profile this session. Gates the launch-ordering
    /// carry-over in `projectHomeItems()`: before the first fresh fetch, a nil
    /// `continueWatchingHub` means "not loaded yet" (keep the cached row);
    /// after it, nil/empty means "this user has no Continue Watching" (drop
    /// the row). Reset on sign-out and profile switch.
    private var hasFetchedContinueWatching = false
    @Published var libraries: [PlexLibrary] = []
    @Published var isLoadingHubs = false
    @Published var isLoadingLibraries = false
    @Published var hubsError: String?
    @Published var librariesError: String?
    @Published private(set) var hasLoadedLibraries = false

    /// Per-library hubs for Home screen (keyed by library key)
    @Published var libraryHubs: [String: [PlexHub]] = [:]
    @Published var isLoadingLibraryHubs = false

    /// First page of each pinned collection (see `HomeCollectionPins`), keyed
    /// by `Pin.id`. nil means not fetched this session; [] means fetched and
    /// empty. `pinRowDecision` needs the difference.
    private var pinnedCollectionItems: [String: [PlexMetadata]] = [:]

    /// Increments whenever hubs content changes (not just count)
    /// Views should watch this to trigger UI updates when items change
    @Published private(set) var hubsVersion: UUID = UUID()

    /// Increments when library hubs content changes
    @Published private(set) var libraryHubsVersion: UUID = UUID()

    // MARK: - MediaItem home projection
    // `MediaItem` rows built by `projectHomeItems()` / `projectLibraryItems(forKey:)`,
    // so Home never materializes the full `PlexMetadata` hubs at launch.

    /// Home's hub rows: Continue Watching, then each pinned library's promoted
    /// hubs. Hero, watchlist and recommendations come from their own services.
    @Published private(set) var homeItems: CachedHomeRail = []

    /// Bumped whenever `homeItems` changes (the projection's content version,
    /// analogous to `hubsVersion`).
    @Published private(set) var homeItemsVersion = UUID()

    /// Per-library-surface projections (mirrors `computeLibrarySections()`'s
    /// one-row-per-library-hub set), keyed by library section key.
    @Published private(set) var libraryItemsByKey: [String: CachedHomeRail] = [:]

    /// Set by the UIKit home (PlexHomeViewController) once the home reaches
    /// any settled state; ContentView's launch splash dismisses on it.
    @Published var isHomeContentReady = false

    /// Set by the UIKit home VC when the hero backdrop image is on screen (or
    /// immediately when no hero will load — disabled, empty, or no URL). The
    /// startup splash waits on this in addition to `isHomeContentReady` so the
    /// hero doesn't pop in after the rows have already painted.
    @Published var isHomeHeroReady = false

    // MARK: - Freshness Tracking

    /// Timestamps of last successful network fetch, keyed by resource identifier
    /// e.g. "libraryItems:/library/sections/1", "libraryHubs:/library/sections/1"
    private var lastFetchTimestamps: [String: Date] = [:]

    /// Record that a resource was just fetched from the network
    func recordFetch(for key: String) {
        lastFetchTimestamps[key] = Date()
    }

    /// Check if a resource was fetched recently enough to skip a refresh
    func isFresh(_ key: String, within interval: TimeInterval) -> Bool {
        guard let timestamp = lastFetchTimestamps[key] else { return false }
        return Date().timeIntervalSince(timestamp) < interval
    }

    /// Clear all freshness timestamps (e.g. on sign out or profile switch)
    func clearFreshnessTimestamps() {
        lastFetchTimestamps.removeAll()
    }

    // MARK: - Logo Metadata Cache (stale-while-revalidate)

    /// Metadata fetched purely to resolve `clearLogoPath`, keyed by ratingKey.
    ///
    /// This holds PLAIN `/library/metadata/{key}` responses, not `getFullMetadata`
    /// ones: every reader wants `clearLogoPath` and nothing else, and the seven
    /// include params cost 28% more bytes and twice the latency (measured against
    /// PMS 1.43.4: 24835B/142ms vs 17962B/71ms, clearLogo present in both). Do not
    /// read extras, markers, chapters, collections or onDeck off these entries;
    /// they are not in there. It is named for what it carries so the next caller
    /// does not assume otherwise.
    private var logoMetadataCache: [String: (metadata: PlexMetadata, fetchedAt: Date)] = [:]
    private let logoMetadataCacheLimit = 50

    /// Get cached logo metadata for a ratingKey (returns nil if not cached)
    func getCachedLogoMetadata(for ratingKey: String) -> PlexMetadata? {
        return logoMetadataCache[ratingKey]?.metadata
    }

    /// Check if cached logo metadata is fresh enough to skip a network request
    func isLogoMetadataFresh(for ratingKey: String, within interval: TimeInterval = 120) -> Bool {
        guard let entry = logoMetadataCache[ratingKey] else { return false }
        return Date().timeIntervalSince(entry.fetchedAt) < interval
    }

    /// Cache logo metadata with LRU eviction at 50 entries
    func cacheLogoMetadata(_ metadata: PlexMetadata, for ratingKey: String) {
        // LRU eviction: remove oldest entry if at capacity and this is a new key
        if logoMetadataCache[ratingKey] == nil && logoMetadataCache.count >= logoMetadataCacheLimit {
            if let oldestKey = logoMetadataCache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
                logoMetadataCache.removeValue(forKey: oldestKey)
            }
        }
        logoMetadataCache[ratingKey] = (metadata: metadata, fetchedAt: Date())
    }

    // MARK: - Hero Cache (per library)

    /// Cached hero items per library key - persists across navigation.
    /// Keys: "home" for the home screen, each library key for library-scoped carousels.
    private var heroItemsCache: [String: [PlexMetadata]] = [:]

    /// Get cached hero items for a library (returns nil if not cached)
    func getCachedHeroItems(forLibrary libraryKey: String) -> [PlexMetadata]? {
        return heroItemsCache[libraryKey]
    }

    /// Cache hero items for a library
    func cacheHeroItems(_ items: [PlexMetadata], forLibrary libraryKey: String) {
        heroItemsCache[libraryKey] = items
    }

    /// Clear hero cache (e.g., on sign out)
    func clearHeroCache() {
        heroItemsCache.removeAll()
    }

    // MARK: - Dependencies

    private let networkManager = PlexNetworkManager.shared
    private let cacheManager = CacheManager.shared
    private let authManager = PlexAuthManager.shared
    private let profileManager = PlexUserProfileManager.shared
    let librarySettings = LibrarySettingsManager.shared

    // MARK: - Computed Properties

    /// Libraries filtered by visibility settings and sorted by user preference
    /// Use this for displaying in the sidebar
    var visibleLibraries: [PlexLibrary] {
        librarySettings.filterAndSortLibraries(libraries)
    }

    /// Video libraries only (movies, shows), filtered and sorted
    var visibleVideoLibraries: [PlexLibrary] {
        visibleLibraries.filter { $0.isVideoLibrary }
    }

    /// Music libraries only (artist), filtered and sorted
    var visibleMusicLibraries: [PlexLibrary] {
        visibleLibraries.filter { $0.isMusicLibrary }
    }

    /// Video and music libraries: the ones Home rows, library hubs and the
    /// prefetch are built from. Photo libraries have none of those.
    var visibleMediaLibraries: [PlexLibrary] {
        visibleLibraries.filter { $0.isVideoLibrary || $0.isMusicLibrary }
    }

    /// Every library the sidebar lists, photo libraries included.
    var visibleSidebarLibraries: [PlexLibrary] {
        visibleLibraries.filter(\.hasBrowseSurface)
    }

    /// Check if any music library is visible in the sidebar
    var hasMusicLibraryVisible: Bool {
        !visibleMusicLibraries.isEmpty
    }

    /// The libraries that contribute Home rows, in Home's order: pinned by Plex
    /// (`isPinnedToHome`) and visible in Settings > Libraries. Rivulet can drop
    /// a Plex-pinned library but never add one.
    /// Order is this device's sidebar order, as Plex's own rule says; it is
    /// never server-side, and `/library/sections` order is wrong (#295).
    var librariesPinnedToHome: [PlexLibrary] {
        visibleMediaLibraries.filter { $0.isPinnedToHome }
    }

    // Track if initial load has been attempted
    private var hubsLoadTask: Task<Void, Never>?
    private var librariesLoadTask: Task<Void, Never>?
    private var libraryHubsLoadTask: Task<Void, Never>?

    /// Track whether we've already attempted connection recovery this session
    /// Reset on successful fetch
    private var hasAttemptedConnectionRecovery = false

    /// True once a `/hubs` fetch has returned WITHOUT throwing this session
    /// (even if the account has zero rows). Distinguishes a genuinely empty,
    /// settled Home from one that is empty only because the first post-sign-in
    /// fetch lost the race with the just-established server connection and
    /// threw. Reset on sign-out / profile switch. See
    /// Docs/bugs/fresh-signin-blank-home.md.
    private var didCompleteInitialHubFetch = false

    /// Background recovery task for the cold-launch Home when the first fetch
    /// races the server connection. Re-attempts with backoff while keeping the
    /// loading state up. Cancelled on sign-out / profile switch.
    private var initialHomeRetryTask: Task<Void, Never>?

    // MARK: - Background Polling

    /// Timer for periodic *full* hub refresh (`/hubs` + `/hubs/continueWatching`).
    /// The global `/hubs` payload is large (~395KB) and its rows (Recently Added,
    /// genres) change slowly, so this stays at 3 minutes.
    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 180 // 3 minutes

    /// Timer for the fast Continue-Watching-only refresh
    /// (`/hubs/continueWatching`, a small payload). Continue Watching is the one
    /// Home row that changes on this cadence — resume position advances and items
    /// reorder as you watch — so it's polled more often than the full `/hubs`
    /// fetch without paying that fetch's cost. See `fetchContinueWatchingOnly`.
    private var continueWatchingPollingTimer: Timer?
    private let continueWatchingPollingInterval: TimeInterval = 30 // 30 seconds

    /// Track if playback is active (pause polling during playback)
    private(set) var isPlaybackActive = false

    /// Track if app is in foreground
    private var isInForeground = true

    /// When the last full `/hubs` fetch completed and when the last
    /// Continue Watching fetch STARTED (either path). Used to gate the
    /// foreground-return and surface-appearance refreshes so they never
    /// duplicate a fetch the timers or the post-playback path just did.
    private var lastHubsFetchAt: Date?
    private var lastContinueWatchingFetchAt: Date?

    /// Identity of the newest added item at the last poll. nil means the poll
    /// has not established its baseline yet, which is not a change.
    private var lastRecentlyAddedStamp: String?

    /// Staggered Continue-Watching-only re-fetches after playback ends. The
    /// player's single 2s-delayed refresh races the server committing the
    /// final timeline/scrobble into the hub — when the server is slower, that
    /// one refresh fetches pre-play data, the equality gate judges it
    /// unchanged, and the row sits stale until the 30s poll. The burst
    /// re-checks on a short tail so a late server commit still lands within
    /// seconds. Each fetch is the small CW payload and equality-gated, so
    /// already-fresh data makes the burst a no-op.
    private var postPlaybackRefreshTask: Task<Void, Never>?

    private init() {
        setupPollingObservers()

        // Hiding a Home row is a projection change, not a data change: the hubs
        // are already in memory. Re-project immediately so Home repaints on the
        // way back out of Settings instead of at the next 3 minute poll.
        NotificationCenter.default.addObserver(
            forName: HomeRowSettings.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.projectHomeItems()
                await TopShelfFeed.refresh()
            }
        }

        // A pin change is also a data change: a new pin has nothing fetched.
        // Project first so an unpin vanishes at once, then fetch and project
        // again. Kept apart from the observer above so a hide toggle never
        // fetches.
        NotificationCenter.default.addObserver(
            forName: HomeCollectionPins.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.projectHomeItems()
                guard let serverURL = self.authManager.selectedServerURL,
                      let token = self.authManager.selectedServerToken else { return }
                await self.loadPinnedCollections(serverURL: serverURL, token: token)
                self.projectHomeItems()
            }
        }

        // Same for the sidebar order — it decides Home's row order too
        // (`librariesPinnedToHome`), so a reorder in Settings has to repaint on
        // the way back out. `dropFirst` skips the initial value; the
        // `syncOrderWithLibraries` append inside the library fetch is followed
        // by its own projection either way.
        librarySettings.$libraryOrder
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.projectHomeItems() }
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func setupPollingObservers() {
        // Observe app lifecycle
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isInForeground = true
                self.startPollingIfNeeded()
                await self.refreshOnForegroundReturn()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isInForeground = false
                self?.stopPolling()
            }
        }

        // Observe playback state
        NotificationCenter.default.addObserver(
            forName: .plexPlaybackStarted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaybackActive = true
                self?.stopPolling()
                self?.postPlaybackRefreshTask?.cancel()
                self?.postPlaybackRefreshTask = nil
            }
        }

        NotificationCenter.default.addObserver(
            forName: .plexPlaybackStopped,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaybackActive = false
                self?.startPollingIfNeeded()
                self?.schedulePostPlaybackRefreshBurst()
            }
        }
    }

    /// See `postPlaybackRefreshTask`. Fires CW-only fetches ~5s / 13s / 28s
    /// after dismissal (the player's own refresh covers ~2s), then stops.
    /// Cancelled if playback starts again.
    private func schedulePostPlaybackRefreshBurst() {
        postPlaybackRefreshTask?.cancel()
        postPlaybackRefreshTask = Task { [weak self] in
            for delay: Double in [5, 8, 15] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                guard self.isInForeground, !self.isPlaybackActive else { return }
                await self.pollContinueWatching()
            }
        }
    }

    /// Refresh on return to foreground, since the resumed timers' first tick is a full
    /// interval away. Continue Watching always re-checks; `/hubs` only when older than its
    /// interval. Skipped on launch activation so it never contends with first paint.
    private func refreshOnForegroundReturn() async {
        guard didCompleteInitialHubFetch, isInForeground, !isPlaybackActive else { return }
        await pollContinueWatching()
        if let last = lastHubsFetchAt, Date().timeIntervalSince(last) < pollingInterval { return }
        await pollHubs()
    }

    /// Nonblocking refresh for a surface (re)appearing — e.g. the home tab
    /// being navigated back to. Fetches only the small Continue Watching hub,
    /// and only when the last CW fetch (any path) is older than `interval`,
    /// so appear-driven calls can't stack on top of the timers or the
    /// post-playback burst.
    func refreshContinueWatchingIfStale(olderThan interval: TimeInterval = 10) async {
        guard !isPlaybackActive else { return }
        if let last = lastContinueWatchingFetchAt, Date().timeIntervalSince(last) < interval { return }
        await pollContinueWatching()
    }

    /// Start polling if conditions are met (foreground, not playing, authenticated)
    func startPollingIfNeeded() {
        guard isInForeground,
              !isPlaybackActive,
              authManager.selectedServerURL != nil else { return }

        if pollingTimer == nil {
            pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.pollHubs()
                }
            }
        }

        if continueWatchingPollingTimer == nil {
            continueWatchingPollingTimer = Timer.scheduledTimer(withTimeInterval: continueWatchingPollingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.pollContinueWatching()
                }
            }
        }
    }

    /// Stop polling (both the full and Continue-Watching-only timers)
    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        continueWatchingPollingTimer?.invalidate()
        continueWatchingPollingTimer = nil
    }

    /// Poll hubs silently (no loading indicator)
    private func pollHubs() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        await fetchHubsFromServer(serverURL: serverURL, token: token, updateLoading: false)
    }

    /// Fast poll: refresh only the Continue Watching hub (small payload). When
    /// this tick coincides with the full poll the equality gate makes the second
    /// fetch a no-op, so the overlap is harmless.
    private func pollContinueWatching() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        await fetchContinueWatchingOnly(serverURL: serverURL, token: token)
        await refreshLibraryHubsIfContentAdded()
    }

    /// Refetches `libraryHubs` when the server's newest item changes, so Home picks up
    /// titles added after launch (#315). The one-item `/library/recentlyAdded` probe is
    /// 1.7 KB against ~100 KB per library's hubs (PMS 1.43.4). Why the section
    /// timestamps don't work: CLAUDE.md, "Plex server API gotchas".
    private func refreshLibraryHubsIfContentAdded() async {
        guard didCompleteInitialHubFetch,
              let serverURL = authManager.selectedServerURL,
              let authToken = authManager.selectedServerToken else { return }

        let newest = try? await networkManager.getRecentlyAdded(
            serverURL: serverURL,
            authToken: authToken,
            start: 0,
            limit: 1
        ).first
        guard let stamp = Self.recentlyAddedStamp(newest) else { return }

        let previous = lastRecentlyAddedStamp
        lastRecentlyAddedStamp = stamp
        guard let previous, previous != stamp else { return }

        await loadLibraryHubsIfNeeded(forceRefresh: true)
    }

    /// Identity of the newest added item, as the change token for the poll
    /// above. `ratingKey` alone is not enough: a new episode dropped into the
    /// season that is already newest keeps that season's key and only moves its
    /// timestamps, so both are part of the token.
    nonisolated static func recentlyAddedStamp(_ newest: PlexMetadata?) -> String? {
        guard let newest, let ratingKey = newest.ratingKey else { return nil }
        return "\(ratingKey)/\(newest.addedAt ?? 0)/\(newest.updatedAt ?? 0)"
    }

    // MARK: - Connection Recovery

    /// Check if an error indicates a connection problem that might be fixable
    private func isConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError

        // Network-level connection errors
        let connectionErrorCodes = [
            NSURLErrorCannotConnectToHost,      // -1004
            NSURLErrorTimedOut,                  // -1001
            NSURLErrorNotConnectedToInternet,   // -1009
            NSURLErrorNetworkConnectionLost,    // -1005
            NSURLErrorCannotFindHost,           // -1003
            NSURLErrorDNSLookupFailed,          // -1006
            NSURLErrorSecureConnectionFailed    // -1200
        ]

        if connectionErrorCodes.contains(nsError.code) {
            return true
        }

        // HTTP errors that suggest the server URL is wrong/stale
        if case PlexAPIError.httpError(let statusCode, _) = error {
            // 5xx errors often mean the URL is wrong (server not at that address)
            return (500...599).contains(statusCode)
        }

        return false
    }

    /// Attempt to recover from a connection error by verifying/fixing the connection
    /// Returns true if recovery was attempted and connection is now working
    private func attemptConnectionRecovery() async -> Bool {
        guard !hasAttemptedConnectionRecovery else {
            return false
        }

        hasAttemptedConnectionRecovery = true

        await authManager.verifyAndFixConnection()

        if authManager.isConnected {
            return true
        } else {
            DiagLog.error(.connection, "Recovery failed, still disconnected")
            return false
        }
    }

    // MARK: - Server Switching

    /// Moves the app to a different server on the account.
    /// If the app cannot connect, this returns false and the current server stays in use.
    func switchServer(to server: PlexDevice) async -> Bool {
        guard await authManager.selectServer(server) else { return false }
        // The music queue sends progress to the server that started it.
        MusicQueue.shared.stop()
        MusicQueue.shared.clear()
        // The profile switch clears all caches that are specific to a server.
        await onProfileSwitched()
        return true
    }

    // MARK: - Profile Switching

    /// Called when the user switches Plex Home profiles
    /// Clears all user-specific cached data and reloads content
    func onProfileSwitched() async {
        // Cancel any in-flight library hub loading
        libraryHubsLoadTask?.cancel()
        libraryHubsLoadTask = nil

        // Switch library settings to the new user's preferences
        LibrarySettingsManager.shared.onProfileSwitched()

        // Clear user-specific caches
        clearHeroCache()
        clearNextEpisodeCache()
        clearFreshnessTimestamps()
        logoMetadataCache.removeAll()

        // Clear in-memory data (libraries may differ per user)
        hubs = []
        continueWatchingHub = nil
        hasFetchedContinueWatching = false
        libraries = []
        hasLoadedLibraries = false
        // A fetch still out for the previous profile must not dedupe the reload below.
        isLoadingLibraries = false
        libraryHubs.removeAll()
        pinnedCollectionItems.removeAll()
        lastRecentlyAddedStamp = nil
        homeItems = []
        libraryItemsByKey.removeAll()
        hubsVersion = UUID()
        libraryHubsVersion = UUID()
        homeItemsVersion = UUID()
        isHomeContentReady = false
        isHomeHeroReady = false
        // Stop any in-flight cold-launch recovery and re-arm the cold path for
        // the next account/profile (see startInitialHomeContentRetry).
        initialHomeRetryTask?.cancel()
        initialHomeRetryTask = nil
        didCompleteInitialHubFetch = false

        // The tvOS Home screen row and the "in your library" index are the
        // previous profile's too.
        TopShelfCache.shared.clear()
        await LibraryGUIDIndex.shared.profileChanged()

        // Clear on-deck/continue watching cache
        await cacheManager.clearOnDeckCache()

        // Clear library caches (different users may have different library access)
        await cacheManager.clearLibraryCache()

        // Clear the hub + MediaItem-rail disk caches. The home launch-paints
        // from home_items_cache.json and the Recently Added rows come from
        // library_hubs_*; left behind, the previous profile's rows would
        // repaint (and the CW row could outlive the switch entirely).
        await cacheManager.clearHubsCache()
        await cacheManager.clearLibraryHubsCache()
        await cacheManager.clearHomeItemsCache()
        await cacheManager.clearHomeHeroItemsCache()
        await cacheManager.clearLibraryItemsCache()

        // Reset connection recovery flag (new profile may have different access)
        hasAttemptedConnectionRecovery = false

        // Reload content for new profile (libraries + hubs in parallel, then library hubs)
        async let libs: () = refreshLibraries()
        async let hubsRefresh: () = refreshHubs()
        _ = await (libs, hubsRefresh)
        await refreshLibraryHubs()

    }

    // MARK: - Hubs (Home View)

    func loadHubsIfNeeded() async {
        // If we already have data, skip. The home now renders rows from the
        // MediaItem projection (`homeItems`), so "already loaded" keys off
        // EITHER the projection OR the heavyweight hubs (a prior network
        // refresh may have populated hubs without us re-reading the cache).
        if !homeItems.isEmpty || !hubs.isEmpty {
            return
        }

        // If already loading, wait for that task
        if let existingTask = hubsLoadTask {
            await existingTask.value
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            // Withheld is signed in: content loads once a profile is entered.
            if !authManager.isContentWithheld { hubsError = "Not authenticated" }
            return
        }

        isLoadingHubs = true
        hubsError = nil

        // Create a non-cancellable task for the launch paint.
        hubsLoadTask = Task {
            // LAUNCH-CRITICAL: paint from the FLAT MediaItem cache first. This
            // is a small/flat decode (~15-field structs) vs. the ~116
            // 65-field PlexMetadata the [PlexHub] cache materializes. We do
            // NOT decode getCachedHubs() on the launch-critical path anymore —
            // the deferred network refresh re-fetches hubs and re-projects.
            StartupTimer.mark("getCachedHomeItems start")
            async let cachedItemsTask = cacheManager.getCachedHomeItems()
            async let cachedHeroItemsTask = cacheManager.getCachedHomeHeroItems()
            let (cachedItems, cachedHeroItems) = await (cachedItemsTask, cachedHeroItemsTask)
            StartupTimer.mark("getCachedHomeItems returned (\(cachedItems?.count ?? -1) rows)")

            var painted = false
            if let cachedItems, !cachedItems.isEmpty {
                await MainActor.run {
                    if let cachedHeroItems, !cachedHeroItems.isEmpty {
                        self.cacheHeroItems(cachedHeroItems, forLibrary: "home")
                    }
                    self.setHomeItemsFromCache(cachedItems)
                    self.isLoadingHubs = false
                }
                StartupTimer.mark("cached home items painted")
                painted = true
            } else {
                // MIGRATION: existing installs have a [PlexHub] cache but no
                // MediaItem cache yet. Do a ONE-TIME projection from the
                // [PlexHub] cache so the very first post-update launch isn't
                // blank, then write the MediaItem cache for subsequent launches.
                // Acceptable to pay the heavy decode ONCE here; warm launches
                // after this take the flat-cache fast path above.
                StartupTimer.mark("home items cache miss — trying [PlexHub] migration")
                let cachedHubs = await cacheManager.getCachedHubs()
                if let cachedHubs, !cachedHubs.isEmpty {
                    await MainActor.run {
                        self.hubs = cachedHubs
                        self.hubsVersion = UUID()
                        // projectHomeItems() also needs the Continue Watching
                        // hub + per-library hubs; those land on the deferred
                        // refresh. This first projection covers whatever the
                        // [PlexHub] cache held (CW is fetched separately so it
                        // may be empty here — the deferred refresh fills it in).
                        self.projectHomeItems()
                        self.isLoadingHubs = false
                    }
                    StartupTimer.mark("migrated [PlexHub] cache -> MediaItem projection")
                    painted = true
                }
            }

            if painted {
                // DEFER the background network refresh. The cache paint is the
                // end of the launch-critical path; the fat /hubs re-decode
                // (~4.5s) + its network must NOT contend with first paint and
                // cell realization (that contention was inflating the cache
                // decode itself on the core-limited Apple TV). Runs 2.5s later.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2.5))
                    await self?.fetchHubsFromServer(serverURL: serverURL, token: token, updateLoading: false)
                }
            } else {
                // Cold launch (no cache at all). Keep `isLoadingHubs` true
                // (set above) across the whole cold load — pass
                // `updateLoading: false` so a fast failure from the
                // post-sign-in connection race can't flip it to false and
                // dismiss the splash / paint a blank Home. We own the flag and
                // clear it once content lands (or recovery gives up).
                await fetchHubsFromServer(serverURL: serverURL, token: token, updateLoading: false)

                if didCompleteInitialHubFetch {
                    // Connection was ready and hubs are in. Fill the rail from
                    // the library hubs the Home actually renders (Recently
                    // Added rows) BEFORE settling, so the first paint isn't a
                    // sparse/blank flash. These normally load via a 2s-deferred
                    // task that races the same just-established connection.
                    await loadLibrariesIfNeeded()
                    await loadLibraryHubsIfNeeded()
                    isLoadingHubs = false
                } else {
                    // The cold fetch lost the race with the just-established
                    // server connection and threw. Recover in the background
                    // with backoff, keeping the loading state up (splash in
                    // release, spinner in debug) until content lands or we give
                    // up — never a blank, focus-trapped Home. The data is
                    // provably fetchable seconds later.
                    startInitialHomeContentRetry(serverURL: serverURL, token: token)
                }
            }
        }

        await hubsLoadTask?.value
        hubsLoadTask = nil
    }

    private func fetchHubsFromServer(serverURL: String, token: String, updateLoading: Bool) async {
        // A token captured before a profile change must not fetch, paint or cache.
        guard authManager.selectedServerToken == token else {
            if updateLoading { isLoadingHubs = false }
            return
        }
        let userId = profileManager.selectedUserId

        do {
            async let hubsTask = fetchHubsOffMain(serverURL: serverURL, token: token, userId: userId)
            async let continueWatchingTask = fetchContinueWatchingOffMain(serverURL: serverURL, token: token, userId: userId)
            let fetchedHubs = try await hubsTask
            // A thrown CW fetch (transient network error) must not be
            // conflated with a successful empty result: only a completed fetch
            // is allowed to clear `continueWatchingHub` and arm
            // `hasFetchedContinueWatching` (which lets projectHomeItems() drop
            // the cached CW row for users who genuinely have none).
            var fetchedContinueWatching: PlexHub?
            var continueWatchingFetchCompleted = false
            do {
                fetchedContinueWatching = try await continueWatchingTask
                continueWatchingFetchCompleted = true
            } catch {
                DiagLog.error(.home, "Continue Watching fetch failed, keeping current hub: \(DiagLog.describe(error))")
            }
            guard authManager.selectedServerToken == token else {
                if updateLoading { isLoadingHubs = false }
                return
            }

            // Reset recovery flag on success
            hasAttemptedConnectionRecovery = false

            // Only update if hubs actually changed (prevents unnecessary re-renders)
            if !hubsAreEqual(self.hubs, fetchedHubs) {
                self.hubs = fetchedHubs
                self.hubsVersion = UUID()  // Signal that content changed
            } else {
            }

            if continueWatchingFetchCompleted {
                hasFetchedContinueWatching = true
                lastContinueWatchingFetchAt = Date()
                if !continueWatchingHubsAreEqual(self.continueWatchingHub, fetchedContinueWatching) {
                    self.continueWatchingHub = fetchedContinueWatching
                    self.hubsVersion = UUID()
                }
            }

            DiagLog.notice(.home, "Hubs fetched: \(fetchedHubs.count) hubs, Continue Watching " + (continueWatchingFetchCompleted ? fetchedContinueWatching.map { "\($0.Metadata?.count ?? 0) items" } ?? "no hub" : "failed"))
            // Always update Top Shelf cache after fetching (composites logo art)
            await TopShelfFeed.refresh()
            self.hubsError = nil
            if updateLoading {
                self.isLoadingHubs = false
            }
            await cacheManager.cacheHubs(fetchedHubs)
            // Hubs or Continue Watching changed: re-project Home.
            projectHomeItems()
            // The fetch returned cleanly: the server connection is up. A still
            // empty Home from here on is genuine, not the post-sign-in race.
            didCompleteInitialHubFetch = true
            lastHubsFetchAt = Date()
        } catch {
            let nsError = error as NSError
            DiagLog.error(.home, "Hubs fetch failed: \(DiagLog.describe(error))")

            // Ignore cancellation errors
            if nsError.code == NSURLErrorCancelled {
                return
            }

            // Attempt connection recovery for connection-related errors
            if isConnectionError(error) {
                if await attemptConnectionRecovery(),
                   let newServerURL = authManager.selectedServerURL,
                   let newToken = authManager.selectedServerToken {
                    // Retry with new connection
                    print("📦 PlexDataStore: Retrying hubs fetch after connection recovery...")
                    await fetchHubsFromServer(serverURL: newServerURL, token: newToken, updateLoading: updateLoading)
                    return
                }
            }

            if self.hubs.isEmpty {
                self.hubsError = error.localizedDescription
            }
            if updateLoading {
                self.isLoadingHubs = false
            }
        }
    }

    /// The 30 s fast poll: refreshes only `/hubs/continueWatching`, the one row that moves
    /// that often, instead of the ~395 KB `/hubs`. Same fetch, equality gate and projection
    /// as `fetchHubsFromServer`.
    private func fetchContinueWatchingOnly(serverURL: String, token: String) async {
        lastContinueWatchingFetchAt = Date()
        let userId = profileManager.selectedUserId
        let fetched: PlexHub?
        do {
            fetched = try await fetchContinueWatchingOffMain(serverURL: serverURL, token: token, userId: userId)
        } catch {
            // Transient error: keep the current hub, same as the full path.
            DiagLog.error(.home, "Continue Watching poll failed, keeping current hub: \(DiagLog.describe(error))")
            return
        }
        guard authManager.selectedServerToken == token else { return }

        hasFetchedContinueWatching = true
        guard !continueWatchingHubsAreEqual(self.continueWatchingHub, fetched) else { return }
        DiagLog.notice(.home, "Continue Watching changed: \(fetched.map { "\($0.Metadata?.count ?? 0) items" } ?? "no hub")")
        self.continueWatchingHub = fetched
        self.hubsVersion = UUID()
        await TopShelfFeed.refresh()
        projectHomeItems()
    }

    /// Recover the cold-launch Home when the first `/hubs` fetch loses the race
    /// with the just-established Plex connection and throws. Re-attempts hubs +
    /// the library hubs the Home rail is built from, with backoff, keeping
    /// `isLoadingHubs` true (so the splash / loading state stays up instead of
    /// dismissing to a blank, focus-trapped Home) until content lands or we
    /// exhaust attempts. The total backoff (~12s) stays under ContentView's 15s
    /// splash safety timeout so the splash never force-dismisses mid-retry onto
    /// a non-focusable spinner. See Docs/bugs/fresh-signin-blank-home.md.
    private func startInitialHomeContentRetry(serverURL: String, token: String) {
        initialHomeRetryTask?.cancel()
        // The failed cold fetch left `isLoadingHubs` true (updateLoading:false);
        // assert it so the loading state is up while we recover.
        isLoadingHubs = true
        initialHomeRetryTask = Task { [weak self] in
            guard let self else { return }
            let backoffSeconds: [Double] = [1, 2, 3, 3, 3]   // ~12s total
            for delay in backoffSeconds {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                await self.fetchHubsFromServer(serverURL: serverURL, token: token, updateLoading: false)
                if self.didCompleteInitialHubFetch {
                    // Connection recovered. Fill the rail from the library hubs,
                    // then stop retrying.
                    await self.loadLibrariesIfNeeded()
                    await self.loadLibraryHubsIfNeeded()
                    break
                }
            }
            if Task.isCancelled { return }
            // Settle. Dropping `isLoadingHubs` lets updateHomeState resolve to
            // content (rows landed), empty (connected, genuinely no rows), or
            // error (gave up — `hubsError` is set by the failed fetch). Each of
            // those presents a focus target, so the Home is never a dead end.
            self.isLoadingHubs = false
            self.initialHomeRetryTask = nil
        }
    }

    func refreshHubs() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        StartupTimer.mark("refreshHubs start (url=\(URL(string: serverURL)?.host ?? serverURL))")
        isLoadingHubs = true
        await StartupTimer.measure("clear caches (onDeck/hubs/nextEp)") {
            await cacheManager.clearOnDeckCache()
            await cacheManager.clearHubsCache()
            await cacheManager.clearHomeHeroItemsCache()
            clearNextEpisodeCache()
        }
        await StartupTimer.measure("fetchHubsFromServer") {
            await fetchHubsFromServer(serverURL: serverURL, token: token, updateLoading: true)
        }
    }

    // MARK: - Library-Specific Hubs (for separated Home screen)

    /// Load hubs for each library that should appear on the Home screen
    func loadLibraryHubsIfNeeded(forceRefresh: Bool = false) async {
        // If already loading, wait for that task (deduplication)
        if let existingTask = libraryHubsLoadTask {
            await existingTask.value
            if !forceRefresh { return }
        }

        // Home reads `promoted` off these hubs (see `projectHomeItems`), so every
        // library that contributes a Home row has to be fetched or its row is
        // silently missing. Union with the rest of the sidebar so the library
        // pages that rely on this prefetch keep theirs too.
        var librariesToLoad = librariesPinnedToHome
        let pinnedKeys = Set(librariesToLoad.map { $0.key })
        librariesToLoad += visibleMediaLibraries.filter { !pinnedKeys.contains($0.key) }

        // Skip if no libraries configured for Home
        guard !librariesToLoad.isEmpty else {
            return
        }

        // Skip if we already have hubs for all libraries, unless the caller is
        // explicitly doing stale-while-revalidate for Home rows.
        let missingLibraries = librariesToLoad.filter { libraryHubs[$0.key] == nil }
        guard forceRefresh || !missingLibraries.isEmpty else {
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            return
        }

        let userId = profileManager.selectedUserId
        let librariesToFetch = forceRefresh ? librariesToLoad : missingLibraries
        print("📦 PlexDataStore: Loading hubs for \(librariesToFetch.count) libraries... (userId: \(userId.map(String.init) ?? "none"), force=\(forceRefresh))")
        isLoadingLibraryHubs = true

        libraryHubsLoadTask = Task {
            // Try cache first for each missing library
            var librariesNeedingFetch: [PlexLibrary] = []
            for library in librariesToFetch {
                if !forceRefresh,
                   let cached = await cacheManager.getCachedLibraryHubs(forLibrary: library.key), !cached.isEmpty {
                    libraryHubs[library.key] = cached
                } else {
                    librariesNeedingFetch.append(library)
                }
            }

            // If cache provided some data, update UI immediately
            if librariesNeedingFetch.count < librariesToFetch.count {
                libraryHubsVersion = UUID()
                isLoadingLibraryHubs = false
                // Home rows and library pages both derive from libraryHubs.
                projectAllLoadedItems()
            }

            // Fetch remaining libraries from network in parallel
            if !librariesNeedingFetch.isEmpty {
                await withTaskGroup(of: (String, String, [PlexHub]?).self) { group in
                    for library in librariesNeedingFetch {
                        let sectionId = library.key.replacingOccurrences(of: "/library/sections/", with: "")
                        group.addTask {
                            do {
                                let hubs = try await self.networkManager.getLibraryHubs(
                                    serverURL: serverURL,
                                    authToken: token,
                                    sectionId: sectionId,
                                    userId: userId,
                                    count: 24
                                )
                                return (library.key, library.title, hubs)
                            } catch {
                                DiagLog.error(.home, "Library \(library.key) (\(library.type)) hubs failed: \(DiagLog.describe(error))")
                                Self.reportLibraryHubFetchFailure(library: library, error: error)
                                return (library.key, library.title, nil)
                            }
                        }
                    }

                    for await (key, _, hubs) in group where authManager.selectedServerToken == token {
                        await noteLibraryHubFetchResult(key: key, hubs: hubs)
                    }
                }
            }

            // Also background-refresh libraries that were served from cache
            let fetchKeys = Set(librariesNeedingFetch.map { $0.key })
            let cachedLibraries = librariesToFetch.filter { !fetchKeys.contains($0.key) }
            if !cachedLibraries.isEmpty {
                await withTaskGroup(of: (String, String, [PlexHub]?).self) { group in
                    for library in cachedLibraries {
                        let sectionId = library.key.replacingOccurrences(of: "/library/sections/", with: "")
                        group.addTask {
                            do {
                                let hubs = try await self.networkManager.getLibraryHubs(
                                    serverURL: serverURL,
                                    authToken: token,
                                    sectionId: sectionId,
                                    userId: userId,
                                    count: 24
                                )
                                return (library.key, library.title, hubs)
                            } catch {
                                DiagLog.error(.home, "Library \(library.key) (\(library.type)) hubs refresh failed: \(DiagLog.describe(error))")
                                Self.reportLibraryHubFetchFailure(library: library, error: error)
                                return (library.key, library.title, nil)
                            }
                        }
                    }

                    for await (key, _, hubs) in group where authManager.selectedServerToken == token {
                        await noteLibraryHubFetchResult(key: key, hubs: hubs)
                    }
                }
            }

            libraryHubsVersion = UUID()
            isLoadingLibraryHubs = false
            // Final projection once every library's hubs have landed.
            projectAllLoadedItems()
            // Top Shelf shows Recently Added after Continue Watching, or alone when it is empty.
            await TopShelfFeed.refresh()

            // Pinned collections load in their own task. The projection above
            // has already painted every promoted row and library page, and
            // neither it nor a caller awaiting this task waits on a pin fetch,
            // which can take up to the request timeout. This one site covers
            // launch, the #315 content-added poll and `refreshLibraryHubs`.
            // No pins, no second projection: `setHomeItems` bumps
            // `homeItemsVersion` unconditionally, and an identical repaint
            // behind every hub load is a cost only a pinned collection earns.
            if !HomeCollectionPins.pins.isEmpty {
                Task {
                    await self.loadPinnedCollections(serverURL: serverURL, token: token)
                    self.projectHomeItems()
                }
            }
        }

        await libraryHubsLoadTask?.value
        libraryHubsLoadTask = nil
    }

    /// Refresh hubs for all libraries on Home screen
    func refreshLibraryHubs() async {
        libraryHubs.removeAll()
        await cacheManager.clearLibraryHubsCache()
        await loadLibraryHubsIfNeeded()
    }

    /// Fetches the first page of each pinned collection into `pinnedCollectionItems`;
    /// callers project afterwards. Only pins in this server's Home video libraries are
    /// asked for, or another server's pins answer 404 and get pruned.
    /// A 404 unpins: PMS 1.43.4 answers 404 for a deleted collection and for one this
    /// profile cannot see. Any other error keeps the last items.
    /// Results are dropped if the pin store key or token changed mid-fetch. The key is
    /// `HomeCollectionPins.storageKey`, not `profileManager.selectedUserId`, which is nil
    /// on cold launch until `fetchHomeUsers` lands (10 to 28 s).
    func loadPinnedCollections(serverURL: String, token: String) async {
        let pinStoreKey = HomeCollectionPins.storageKey
        let libraryUUIDs = Set(librariesPinnedToHome.filter(\.isVideoLibrary).map(\.uuid))
        let pins = HomeCollectionPins.pins.filter { libraryUUIDs.contains($0.libraryUUID) }
        guard !pins.isEmpty else { return }

        typealias Fetch = (pin: HomeCollectionPins.Pin, items: [PlexMetadata]?, gone: Bool)
        let fetches = await withTaskGroup(of: Fetch.self) { group in
            for pin in pins {
                group.addTask {
                    do {
                        let page = try await self.networkManager.getHubItems(
                            serverURL: serverURL,
                            authToken: token,
                            hubKey: pin.childrenKey,
                            hubIdentifier: nil,
                            start: 0,
                            count: 24
                        )
                        return (pin, page.items, false)
                    } catch PlexAPIError.httpError(let statusCode, _) where statusCode == 404 {
                        return (pin, nil, true)
                    } catch {
                        return (pin, nil, false)
                    }
                }
            }
            var fetches: [Fetch] = []
            for await fetch in group { fetches.append(fetch) }
            return fetches
        }

        guard HomeCollectionPins.storageKey == pinStoreKey,
              authManager.selectedServerToken == token else { return }

        for fetch in fetches {
            if fetch.gone {
                pinnedCollectionItems[fetch.pin.id] = nil
                HomeCollectionPins.unpin(ratingKey: fetch.pin.ratingKey, libraryUUID: fetch.pin.libraryUUID)
            } else if let items = fetch.items {
                pinnedCollectionItems[fetch.pin.id] = items
            }
        }
    }

    /// The `key` of every hub Plex promotes to Home for this library, which for
    /// a collection's promoted hub is the same string as
    /// `HomeCollectionPins.Pin.childrenKey`. A pinned collection whose key is
    /// in this set is already a Plex row (P1 wins). `projectHomeItems` uses it
    /// to drop that duplicate, and the tile menu's Pin to Home uses it to not
    /// offer a pin Plex already provides, so both must read this one
    /// derivation. Empty for a library whose hubs have not loaded.
    func promotedHubKeys(forLibraryKey key: String) -> Set<String> {
        Set((libraryHubs[key] ?? []).filter { $0.promoted == true }.compactMap(\.key))
    }

    /// Applies one library's hub-fetch outcome. Failure (nil) keeps the last-known hubs.
    /// The disk write lives here because every successful fetch passes through (#315).
    private func noteLibraryHubFetchResult(key: String, hubs: [PlexHub]?) async {
        guard let hubs else { return }
        libraryHubs[key] = hubs
        recordFetch(for: "libraryHubs:\(key)")
        await cacheManager.cacheLibraryHubs(hubs, forLibrary: key)
    }

    /// Breadcrumb a per-library hub fetch failure so a missing Home shelf is
    /// diagnosable in the field (GitHub #236). Carries only the library's
    /// title/type and an error description — never a request URL. The
    /// description is redacted anyway because a `URLError`'s own text embeds
    /// the failing URL, and a Plex URL carries `X-Plex-Token`.
    nonisolated private static func reportLibraryHubFetchFailure(library: PlexLibrary, error: Error) {
        let breadcrumb = Breadcrumb(level: .warning, category: "plex_home")
        breadcrumb.message = "Library hubs fetch failed"
        breadcrumb.data = [
            "library_title": library.title,
            "library_type": library.type,
            "error": SensitiveDataRedactor.redact(error.localizedDescription)
        ]
        SentryBridge.addBreadcrumb(breadcrumb)
    }

    // MARK: - Home projection
    // Builds `homeItems`, which Home and Settings read.
    func projectHomeItems() {
        // Home mirrors the server's own state. Measured on PMS 1.43.3:
        // - `PlexLibrary.hidden` (/library/sections) picks libraries: 0 pinned to Home,
        //   1 hidden from Home, 2 hidden from Home and the sidebar ("Pin to home").
        // - `PlexHub.promoted` (/hubs/sections/{key}) is set on exactly one hub per
        //   library. It is `promotedToOwnHome`, not `promotedToRecommended`.
        // - Global `/hubs` is the wrong source: it merges movie libraries into one
        //   row and adds `home.playlists`, which the Plex app never shows.
        // - `/hubs/continueWatching` is the merged in-progress + On Deck hub.
        var rail: CachedHomeRail = []
        var carriedContinueWatching = false

        // Continue Watching. Not gated on promotion: it is a global row that
        // every scoped `/hubs/promoted` call returns, and PMS already scopes its
        // items to pinned libraries (measured: every item came from a
        // `hidden == 0` library).
        if let cw = continueWatchingHub, let metas = cw.Metadata, !metas.isEmpty,
           !HomeRowSettings.isHidden(cw.hubIdentifier) {
            rail.append(makeCachedHub(
                id: "hub:\(cw.id)",
                title: cw.title ?? "",
                isContinueWatching: true,
                hubKey: cw.key ?? cw.hubKey,
                hubIdentifier: cw.hubIdentifier,
                metas: metas
            ))
        } else if let cached = homeItems.first(where: \.isContinueWatching),
                  Self.carriesOverContinueWatching(hasFetched: hasFetchedContinueWatching,
                                                   isHidden: HomeRowSettings.isHidden(cached.hubIdentifier)) {
            rail.append(cached)
            carriedContinueWatching = true
        }

        // One row per promoted hub, per pinned library. Library order is the
        // sidebar's (see `librariesPinnedToHome`); the rows WITHIN a library
        // stay in the server's order, which is where Plex's own drag-to-reorder
        // in Manage Recommendations lands.
        let pins = HomeCollectionPins.pins
        for library in librariesPinnedToHome {
            for hub in libraryHubs[library.key] ?? [] {
                guard hub.promoted == true else { continue }
                // A library's own in-progress hub would duplicate the global
                // Continue Watching row above.
                guard !Self.isContinueWatchingFamily(hubIdentifier: hub.hubIdentifier) else { continue }
                // Local subtractive filter — see `HomeRowSettings`.
                guard !HomeRowSettings.isHidden(hub.hubIdentifier) else { continue }
                guard let metas = hub.Metadata, !metas.isEmpty else { continue }

                var row = makeCachedHub(
                    id: "hub:\(hub.id)",
                    title: hub.title ?? "",
                    isContinueWatching: false,
                    hubKey: hub.key ?? hub.hubKey,
                    hubIdentifier: hub.hubIdentifier,
                    metas: metas
                )
                row.libraryKey = library.key
                rail.append(row)
            }

            // Collections pinned in Rivulet (see `HomeCollectionPins`), after
            // Plex's own rows for this library, in pin order.
            let promotedKeys = promotedHubKeys(forLibraryKey: library.key)
            for pin in pins where pin.libraryUUID == library.uuid {
                let rowID = "hub:\(pin.rowIdentifier)"
                let cachedRow = homeItems.first { $0.id == rowID }
                switch Self.pinRowDecision(
                    isPromotedDuplicate: promotedKeys.contains(pin.childrenKey),
                    fetched: pinnedCollectionItems[pin.id],
                    hasCachedRow: cachedRow != nil
                ) {
                case .render:
                    var row = makeCachedHub(
                        id: rowID,
                        title: pin.title,
                        isContinueWatching: false,
                        hubKey: pin.childrenKey,
                        hubIdentifier: pin.rowIdentifier,
                        metas: pinnedCollectionItems[pin.id] ?? []
                    )
                    row.libraryKey = library.key
                    rail.append(row)
                case .carryOver:
                    if var cachedRow {
                        cachedRow.libraryKey = library.key
                        rail.append(cachedRow)
                    }
                case .omit:
                    break
                }
            }
        }

        // An empty rail replaces Home only after a fetch completes: `setHomeItems`
        // persists it, so an early call would bake an empty Home into warm launches (#236).
        guard rail.count > (carriedContinueWatching ? 1 : 0) || didCompleteInitialHubFetch else { return }

        setHomeItems(rail)
    }

    /// Whether a promoted hub belongs to the Continue Watching family, meaning
    /// it gets the backdrop-and-logo resume tiles and its items come from the
    /// dedicated fast-refresh fetch.
    ///
    /// Matched on the identifier: `/hubs` says `home.continue` where
    /// `/hubs/continueWatching` says `continueWatching`, so comparing the two never matches.
    /// On Deck is in the family because `/hubs/continueWatching` already merges it.
    nonisolated static func isContinueWatchingFamily(hubIdentifier: String?) -> Bool {
        let id = (hubIdentifier ?? "").lowercased()
        guard !id.isEmpty else { return false }
        return id.contains("continue") || id.contains("inprogress") || id.contains("ondeck")
    }

    /// A hub key the pagination path can actually call, or nil.
    ///
    /// Most `/hubs` rows have no `hubKey` and a `key` that is an id list
    /// (`/library/metadata/209601,209469,…`); paging that re-appends the same items.
    private func paginableHubKey(_ hub: PlexHub) -> String? {
        Self.paginableHubKey(hubKey: hub.hubKey, key: hub.key)
    }

    nonisolated static func paginableHubKey(hubKey: String?, key: String?) -> String? {
        for candidate in [hubKey, key] {
            guard let candidate, candidate.hasPrefix("/hubs") else { continue }
            return candidate
        }
        return nil
    }

    /// One library page's hub rows, in Plex's order and de-duped by hub identity,
    /// stored in `libraryItemsByKey`.
    func projectLibraryItems(forKey key: String) {
        var rail: CachedHomeRail = []
        var seenIDs = Set<String>()
        for hub in libraryHubs[key] ?? [] {
            guard let items = hub.Metadata, !items.isEmpty else { continue }
            // Same hub-identity chain and de-dupe as computeLibrarySections.
            let hubID = hub.hubIdentifier ?? hub.key ?? hub.hubKey ?? hub.title ?? "row"
            guard seenIDs.insert(hubID).inserted else { continue }
            rail.append(makeCachedHub(
                id: "hub:\(key):\(hubID)",
                title: hub.title ?? "",
                isContinueWatching: isContinueWatchingHub(hub),
                hubKey: hub.key ?? hub.hubKey,
                hubIdentifier: hub.hubIdentifier,
                metas: items
            ))
        }
        libraryItemsByKey[key] = rail
        // Bump so library-mode home observers (which watch libraryHubsVersion)
        // re-apply their snapshot from the refreshed per-library projection.
        libraryHubsVersion = UUID()
        Task { await cacheManager.cacheLibraryItems(rail, forLibrary: key) }
    }

    /// Assigns `homeItems`, bumps `homeItemsVersion`, and persists the rail.
    private func setHomeItems(_ rail: CachedHomeRail) {
        homeItems = rail
        homeItemsVersion = UUID()
        let totalItems = rail.reduce(0) { $0 + $1.items.count }
        DiagLog.notice(.home, "Home rows=\(rail.count) items=\(totalItems) per row=\(rail.map(\.items.count)) cw_row=\(rail.contains(where: \.isContinueWatching))")
        Task { await cacheManager.cacheHomeItems(rail) }
    }

    /// Launch fast-paint from the on-disk cache, without writing it back.
    private func setHomeItemsFromCache(_ rail: CachedHomeRail) {
        homeItems = rail
        homeItemsVersion = UUID()
    }

    /// Library launch fast-paint from the on-disk cache, without writing it back.
    private func setLibraryItemsFromCache(_ rail: CachedHomeRail, forKey key: String) {
        libraryItemsByKey[key] = rail
        libraryHubsVersion = UUID()
    }

    /// Paints a library page from the MediaItem cache, skipping the [PlexHub]
    /// decode before first paint. Returns true if a non-empty cache was painted.
    func paintLibraryItemsFromCacheIfNeeded(forKey key: String) async -> Bool {
        if let existing = libraryItemsByKey[key], !existing.isEmpty { return true }
        guard authManager.selectedServerToken != nil else { return false }
        guard let cached = await cacheManager.getCachedLibraryItems(forLibrary: key),
              !cached.isEmpty else { return false }
        setLibraryItemsFromCache(cached, forKey: key)
        return true
    }

    /// Maps a hub's `[PlexMetadata]` to `[MediaItem]`, de-duped by ratingKey.
    /// Provider id, server URL and token come the same way the home VC's cells get them.
    private func makeCachedHub(
        id: String,
        title: String,
        isContinueWatching: Bool,
        hubKey: String?,
        hubIdentifier: String?,
        metas: [PlexMetadata]
    ) -> CachedHomeHub {
        let serverURL = authManager.selectedServerURL ?? ""
        let token = authManager.selectedServerToken ?? ""
        let providerID = MediaProviderRegistry.shared.plexProvider?.id ?? "plex:\(serverURL)"
        var seen = Set<String>()
        let items: [MediaItem] = metas.compactMap { meta in
            var item = PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
            // The cross-server Continue Watching merge matches on these.
            if isContinueWatching { item.identity = ContinueWatchingMerge.plexKeys(meta) }
            // De-dupe by ref.itemID (== ratingKey). computeSections drops
            // repeated ratingKeys; an empty itemID (no ratingKey) can't be
            // identity-keyed, so keep it (matches the snapshot's fallback id).
            if item.ref.itemID.isEmpty { return item }
            return seen.insert(item.ref.itemID).inserted ? item : nil
        }
        return CachedHomeHub(
            id: id,
            title: title,
            isContinueWatching: isContinueWatching,
            hubKey: hubKey,
            hubIdentifier: hubIdentifier,
            totalSize: nil,
            items: items
        )
    }

    /// Refresh the home projection plus every currently-loaded library page
    /// projection. Used by the library-hub load path, which changes both the
    /// home's "Recently Added" rows and the per-library rows at once.
    private func projectAllLoadedItems() {
        projectHomeItems()
        for key in libraryHubs.keys {
            projectLibraryItems(forKey: key)
        }
    }

    /// What `projectHomeItems` does with one pinned collection (see
    /// `HomeCollectionPins`). Plain values so it can be tested.
    nonisolated enum PinRowDecision { case render, carryOver, omit }

    /// A hub Plex already promotes for the collection wins. Not fetched yet: keep the cached
    /// row, since `setHomeItems` persists the rail (#236). Fetched empty: omit, keep the pin.
    nonisolated static func pinRowDecision(
        isPromotedDuplicate: Bool,
        fetched: [PlexMetadata]?,
        hasCachedRow: Bool
    ) -> PinRowDecision {
        if isPromotedDuplicate { return .omit }
        guard let fetched else { return hasCachedRow ? .carryOver : .omit }
        return fetched.isEmpty ? .omit : .render
    }

    /// Before the session's first Continue Watching fetch, no hub means "not
    /// loaded yet": the row the launch cache painted stays instead of dropping
    /// out until the fetch returns. After it, no hub means the user has none.
    nonisolated static func carriesOverContinueWatching(hasFetched: Bool, isHidden: Bool) -> Bool {
        !hasFetched && !isHidden
    }

    /// Replica of `PlexHomeViewController.isContinueWatchingHub(_:)` for the
    /// per-library projection's CW detection.
    private func isContinueWatchingHub(_ hub: PlexHub) -> Bool {
        let identifier = (hub.hubIdentifier ?? "").lowercased()
        if identifier.contains("continue") || identifier.contains("inprogress") || identifier.contains("ondeck") {
            return true
        }
        return (hub.title ?? "").lowercased().contains("continue")
    }

    // MARK: - Libraries

    func loadLibrariesIfNeeded() async {
        // If we already have data, skip
        if !libraries.isEmpty {
            hasLoadedLibraries = true
            return
        }

        // If already loading, wait for that task
        if let existingTask = librariesLoadTask {
            await existingTask.value
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            if !authManager.isContentWithheld { librariesError = "Not authenticated" }
            return
        }

        isLoadingLibraries = true
        librariesError = nil

        // Create a non-cancellable task for the network request
        librariesLoadTask = Task {
            // Try cache first
            if let cached = await cacheManager.getCachedLibraries(), !cached.isEmpty {
                await MainActor.run {
                    self.libraries = cached
                    self.isLoadingLibraries = false
                }
                // Background refresh
                await fetchLibrariesFromServer(serverURL: serverURL, token: token, updateLoading: false)
            } else {
                await fetchLibrariesFromServer(serverURL: serverURL, token: token, updateLoading: true)
            }
        }

        await librariesLoadTask?.value
        librariesLoadTask = nil
        hasLoadedLibraries = true
    }

    private func fetchLibrariesFromServer(serverURL: String, token: String, updateLoading: Bool) async {
        let userId = profileManager.selectedUserId

        do {
            let fetched = try await fetchLibrariesOffMain(serverURL: serverURL, token: token, userId: userId)
            guard authManager.selectedServerToken == token else {
                if updateLoading { isLoadingLibraries = false }
                return
            }

            // Reset recovery flag on success
            hasAttemptedConnectionRecovery = false

            // Only update if libraries actually changed (prevents unnecessary re-renders)
            if !librariesAreEqual(self.libraries, fetched) {
                self.libraries = fetched
            } else {
            }
            self.librariesError = nil
            if updateLoading {
                self.isLoadingLibraries = false
            }
            DiagLog.notice(.home, "Libraries fetched: \(fetched.map(\.type))")
            // Sync library order settings with current libraries
            self.librarySettings.syncOrderWithLibraries(fetched)
            await cacheManager.cacheLibraries(fetched)
        } catch {
            let nsError = error as NSError
            DiagLog.error(.home, "Libraries fetch failed: \(DiagLog.describe(error))")

            // Ignore cancellation errors
            if nsError.code == NSURLErrorCancelled {
                return
            }

            // Attempt connection recovery for connection-related errors
            if isConnectionError(error) {
                if await attemptConnectionRecovery(),
                   let newServerURL = authManager.selectedServerURL,
                   let newToken = authManager.selectedServerToken {
                    // Retry with new connection
                    print("📦 PlexDataStore: Retrying libraries fetch after connection recovery...")
                    await fetchLibrariesFromServer(serverURL: newServerURL, token: newToken, updateLoading: updateLoading)
                    return
                }
            }

            if self.libraries.isEmpty {
                self.librariesError = error.localizedDescription
            }
            if updateLoading {
                self.isLoadingLibraries = false
            }
        }
    }

    // MARK: - Off-main fetch helpers

    private func fetchHubsOffMain(serverURL: String, token: String, userId: Int?) async throws -> [PlexHub] {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await PlexNetworkManager.shared.getHubs(serverURL: serverURL, authToken: token, userId: userId)
        }.value
    }

    private func fetchContinueWatchingOffMain(serverURL: String, token: String, userId: Int?) async throws -> PlexHub? {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await PlexNetworkManager.shared.getContinueWatching(serverURL: serverURL, authToken: token, userId: userId)
        }.value
    }

    private func continueWatchingHubsAreEqual(_ lhs: PlexHub?, _ rhs: PlexHub?) -> Bool {
        // Compares per-item state, not just ratingKeys, so a `viewOffset` change repaints
        // the progress bars. Shared with `hubsAreEqual`.
        PlexHub.metadataStateEqual(lhs?.Metadata, rhs?.Metadata)
    }

    private func fetchLibrariesOffMain(serverURL: String, token: String, userId: Int?) async throws -> [PlexLibrary] {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await PlexNetworkManager.shared.getLibraries(serverURL: serverURL, authToken: token, userId: userId)
        }.value
    }

    func refreshLibraries() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Dedup concurrent calls. scenePhase->.active + a settings page appearing
        // can fire back-to-back; the second would just overwrite the first's result.
        guard !isLoadingLibraries else { return }

        isLoadingLibraries = true
        await fetchLibrariesFromServer(serverURL: serverURL, token: token, updateLoading: true)
    }

    // MARK: - Background Prefetch

    private var prefetchTask: Task<Void, Never>?

    /// Prefetch library content in the background for faster navigation
    /// Call this on app start after authentication is verified
    /// Pass libraries directly to avoid polling loops
    func startBackgroundPrefetch(libraries: [PlexLibrary]) {
        // Cancel any existing prefetch
        prefetchTask?.cancel()

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            print("📦 PlexDataStore: Cannot prefetch - not authenticated")
            return
        }

        // Run heavy prefetch work off the main actor; only hop back when touching UI state.
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            for library in libraries {
                guard !Task.isCancelled else { break }

                let libraryKey = library.key

                // Check if already cached
                let hasMoviesCache = await self.cacheManager.getCachedMovies(forLibrary: libraryKey) != nil
                let hasShowsCache = await self.cacheManager.getCachedShows(forLibrary: libraryKey) != nil
                let hasHubsCache = await self.cacheManager.getCachedLibraryHubs(forLibrary: libraryKey) != nil

                // The ITEMS half is video-only: `cacheMovies`/`cacheShows` are the
                // only item caches, so an artist library would spend a request and
                // then have nowhere to put the result. The HUBS half below is not,
                // and must not be — a pinned music library needs its hubs on disk
                // for its Home row to survive a cold launch. Passing only video
                // libraries in was what left "Recently Added in Music" waiting on
                // the network every time while the movie rows came back instantly.
                if hasMoviesCache || hasShowsCache || !library.isVideoLibrary {
                } else {
                    // Fetch and cache library items
                    do {
                        let result = try await self.networkManager.getLibraryItemsWithTotal(
                            serverURL: serverURL,
                            authToken: token,
                            sectionId: libraryKey,
                            start: 0,
                            size: 30
                        )

                        // Cache based on type
                        if let firstItem = result.items.first {
                            if firstItem.type == "movie" {
                                await self.cacheManager.cacheMovies(result.items, forLibrary: libraryKey)
                            } else if firstItem.type == "show" {
                                await self.cacheManager.cacheShows(result.items, forLibrary: libraryKey)
                            }
                        }
                        await MainActor.run {
                            self.recordFetch(for: "libraryItems:\(libraryKey)")
                        }

                        // Prefetch poster images for first 30 items
                        self.prefetchImages(for: result.items, serverURL: serverURL, token: token)
                    } catch {
                        print("📦 PlexDataStore: ⚠️ Failed to prefetch items for \(library.title): \(error.localizedDescription)")
                    }
                }

                // Prefetch library hubs
                if hasHubsCache {
                } else {
                    do {
                        let hubs = try await self.networkManager.getLibraryHubs(
                            serverURL: serverURL,
                            authToken: token,
                            sectionId: libraryKey
                        )
                        await self.cacheManager.cacheLibraryHubs(hubs, forLibrary: libraryKey)
                        await MainActor.run {
                            self.recordFetch(for: "libraryHubs:\(libraryKey)")
                        }
                    } catch {
                        print("📦 PlexDataStore: ⚠️ Failed to prefetch hubs for \(library.title): \(error.localizedDescription)")
                    }
                }

                // No delay needed — Plex server handles concurrent requests fine on local network
            }

            guard !Task.isCancelled else { return }

            // Prefetch home hub images and next episodes for Continue Watching
            await self.prefetchHubContent(serverURL: serverURL, token: token)

        }
    }

    // MARK: - Image Prefetching

    /// Build image URL for a metadata item
    nonisolated private func buildImageURL(for item: PlexMetadata, serverURL: String, token: String) -> URL? {
        // For episodes, prefer the series poster
        let thumb: String?
        if item.type == "episode" {
            thumb = item.grandparentThumb ?? item.parentThumb ?? item.thumb
        } else {
            thumb = item.thumb
        }

        guard let thumbPath = thumb else { return nil }
        var urlString = "\(serverURL)\(thumbPath)"
        if !urlString.contains("X-Plex-Token") {
            urlString += urlString.contains("?") ? "&" : "?"
            urlString += "X-Plex-Token=\(token)"
        }
        return URL(string: urlString)
    }

    /// Prefetch poster images for a list of items
    nonisolated private func prefetchImages(for items: [PlexMetadata], serverURL: String, token: String) {
        let imageURLs = items.compactMap { buildImageURL(for: $0, serverURL: serverURL, token: token) }
        guard !imageURLs.isEmpty else { return }

        Task.detached(priority: .utility) {
            await ImageCacheManager.shared.prefetch(urls: imageURLs)
        }
    }

    /// Prefetch hub content including images and next episodes for Continue Watching
    private func prefetchHubContent(serverURL: String, token: String) async {
        guard !hubs.isEmpty else { return }

        // Collect all hub items for image prefetching
        var allHubItems: [PlexMetadata] = []
        var continueWatchingEpisodes: [PlexMetadata] = []

        for hub in hubs {
            guard let items = hub.Metadata else { continue }
            allHubItems.append(contentsOf: items)

            // Identify Continue Watching / On Deck hubs
            let identifier = hub.hubIdentifier?.lowercased() ?? ""
            let isContinueWatching = identifier.contains("continuewatching") ||
                                     identifier.contains("ondeck") ||
                                     identifier.contains("inprogress")

            if isContinueWatching {
                // Collect TV episodes for next episode prefetching
                let episodes = items.filter { $0.type == "episode" }
                continueWatchingEpisodes.append(contentsOf: episodes)
            }
        }

        // Prefetch poster images for all hub items
        prefetchImages(for: allHubItems, serverURL: serverURL, token: token)

        // Prefetch next episodes for Continue Watching TV episodes
        if !continueWatchingEpisodes.isEmpty {
            await prefetchNextEpisodes(for: continueWatchingEpisodes, serverURL: serverURL, token: token)
        }
    }

    // MARK: - Next Episode Prefetching

    /// Cache for prefetched next episodes (keyed by current episode ratingKey)
    private(set) var nextEpisodeCache: [String: PlexMetadata] = [:]

    /// Prefetch next episodes for Continue Watching items
    private func prefetchNextEpisodes(for episodes: [PlexMetadata], serverURL: String, token: String) async {
        // Limit to first 5 episodes to avoid too many requests
        let episodesToProcess = Array(episodes.prefix(5))

        for episode in episodesToProcess {
            guard !Task.isCancelled else { break }

            guard let ratingKey = episode.ratingKey else { continue }

            // Skip if already cached
            if nextEpisodeCache[ratingKey] != nil { continue }

            do {
                // Fetch full metadata if parent keys are missing
                var workingEpisode = episode
                if workingEpisode.parentRatingKey == nil || workingEpisode.index == nil {
                    let fullMetadata = try await networkManager.getMetadata(
                        serverURL: serverURL,
                        authToken: token,
                        ratingKey: ratingKey
                    )
                    workingEpisode.parentRatingKey = fullMetadata.parentRatingKey
                    workingEpisode.grandparentRatingKey = fullMetadata.grandparentRatingKey
                    workingEpisode.parentIndex = fullMetadata.parentIndex
                    workingEpisode.index = fullMetadata.index
                }

                guard let seasonKey = workingEpisode.parentRatingKey,
                      let currentIndex = workingEpisode.index else { continue }

                // Get episodes in current season
                let seasonEpisodes = try await networkManager.getChildren(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: seasonKey
                )

                // Find next episode
                if let nextEp = seasonEpisodes.first(where: { $0.index == currentIndex + 1 }) {
                    nextEpisodeCache[ratingKey] = nextEp

                    // Prefetch the next episode's thumbnail
                    if let imageURL = buildImageURL(for: nextEp, serverURL: serverURL, token: token) {
                        Task.detached(priority: .utility) {
                            _ = await ImageCacheManager.shared.image(for: imageURL)
                        }
                    }
                }
                // Note: We don't try next season here to keep prefetch fast
            } catch {
                print("📦 PlexDataStore: ⚠️ Failed to prefetch next episode for \(episode.title ?? "?"): \(error.localizedDescription)")
            }

            // Small delay between requests
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    /// Get cached next episode for a given episode ratingKey
    func getCachedNextEpisode(for ratingKey: String) -> PlexMetadata? {
        return nextEpisodeCache[ratingKey]
    }

    /// Clear next episode cache
    func clearNextEpisodeCache() {
        nextEpisodeCache.removeAll()
    }

    // MARK: - Reset (on sign out)

    func reset() {
        stopPolling()
        hubsLoadTask?.cancel()
        librariesLoadTask?.cancel()
        libraryHubsLoadTask?.cancel()
        prefetchTask?.cancel()
        hubsLoadTask = nil
        librariesLoadTask = nil
        libraryHubsLoadTask = nil
        prefetchTask = nil
        hubs = []
        continueWatchingHub = nil
        hasFetchedContinueWatching = false
        libraries = []
        hasLoadedLibraries = false
        libraryHubs.removeAll()
        pinnedCollectionItems.removeAll()
        lastRecentlyAddedStamp = nil
        homeItems = []
        libraryItemsByKey.removeAll()
        hubsVersion = UUID()
        libraryHubsVersion = UUID()
        homeItemsVersion = UUID()
        isHomeContentReady = false
        isHomeHeroReady = false
        // Stop any in-flight cold-launch recovery and re-arm the cold path
        // (see startInitialHomeContentRetry).
        initialHomeRetryTask?.cancel()
        initialHomeRetryTask = nil
        didCompleteInitialHubFetch = false
        hubsError = nil
        librariesError = nil
        isLoadingHubs = false
        isLoadingLibraries = false
        nextEpisodeCache.removeAll()
        heroItemsCache.removeAll()
        clearFreshnessTimestamps()
        logoMetadataCache.removeAll()
        TopShelfCache.shared.clear()
        // Wipe ALL on-disk content caches. Sign-out must leave nothing of the
        // previous account behind: the home launch-paints straight from
        // home_items_cache.json (and library_hubs_* / library_items_* feed the
        // Recently Added / library rows), so any survivor here resurfaces the
        // previous account's content after the next sign-in.
        Task { await cacheManager.clearAllCache() }
    }

    // MARK: - Diffing Helpers

    /// Compare two hub arrays to avoid unnecessary state updates
    private func hubsAreEqual(_ lhs: [PlexHub], _ rhs: [PlexHub]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (l, r) in zip(lhs, rhs) {
            if l.hubIdentifier != r.hubIdentifier { return false }
            // Per-item watch-state comparison (ratingKey + viewOffset +
            // viewCount) is shared with the Continue Watching path so the two
            // can't diverge — see `PlexHub.metadataStateEqual`.
            if !PlexHub.metadataStateEqual(l.Metadata, r.Metadata) { return false }
        }
        return true
    }

    /// Compare two library arrays to avoid unnecessary state updates.
    /// Includes `title` so a server-side rename (same key, new title)
    /// surfaces on the next refresh — keys alone would treat the
    /// renamed list as equal and the UI would stay stale until an
    /// app restart. `type` is included too because a library
    /// retype (movie ⇄ show, rare) also has to invalidate.
    private func librariesAreEqual(_ lhs: [PlexLibrary], _ rhs: [PlexLibrary]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (l, r) in zip(lhs, rhs) {
            if l.key != r.key || l.title != r.title || l.type != r.type {
                return false
            }
        }
        return true
    }
}

extension PlexLibrary {
    /// The sections tvOS has a page for: the sidebar and Settings list these.
    var hasBrowseSurface: Bool { isVideoLibrary || isMusicLibrary || isPhotoLibrary }
}
