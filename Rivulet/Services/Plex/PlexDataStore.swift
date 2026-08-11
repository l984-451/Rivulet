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

    /// Library keys whose most recent hub fetch THREW (timeout, transport
    /// error, server 500). Distinguishes the two meanings a nil
    /// `libraryHubs[key]` otherwise conflates: "never loaded" vs. "tried and
    /// failed". `projectHomeItems()` needs the difference — a failed library
    /// must carry its previously-projected Recently Added row over rather than
    /// silently drop the shelf (GitHub #236). Cleared per key on a successful
    /// fetch, and wholesale on sign-out / profile switch.
    private var libraryHubFetchFailures: Set<String> = []

    /// Increments whenever hubs content changes (not just count)
    /// Views should watch this to trigger UI updates when items change
    @Published private(set) var hubsVersion: UUID = UUID()

    /// Increments when library hubs content changes
    @Published private(set) var libraryHubsVersion: UUID = UUID()

    // MARK: - MediaItem home projection (Stage 1 — additive, no consumer yet)
    //
    // A lightweight, `MediaItem`-based mirror of the home/library hub rows,
    // derived from `hubs` + `continueWatchingHub` + `libraryHubs` by
    // `projectHomeItems()` / `projectLibraryItems(forKey:)` to EXACTLY match
    // the row set `PlexHomeViewController.computeSections()` /
    // `computeLibrarySections()` produce. Nothing renders from these yet; a
    // later stage will swap the home over to them to avoid materializing ~116
    // 65-field `PlexMetadata` at launch (see
    // `perf-spike/MEDIAITEM_HOME_PLAN.md`). Produced OFF the launch-critical
    // path (only on the deferred network-refresh assignments).

    /// Home-surface projection (mirrors `computeSections()` row order:
    /// Continue Watching, then Recently Added per home library). Hero,
    /// watchlist and recommendations rows are intentionally excluded — they
    /// do not originate from the hub store this projection mirrors.
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

    // MARK: - Full Metadata Cache (stale-while-revalidate)

    /// Cached full metadata responses keyed by ratingKey, with fetch timestamp
    private var fullMetadataCache: [String: (metadata: PlexMetadata, fetchedAt: Date)] = [:]
    private let fullMetadataCacheLimit = 50

    /// Get cached full metadata for a ratingKey (returns nil if not cached)
    func getCachedFullMetadata(for ratingKey: String) -> PlexMetadata? {
        return fullMetadataCache[ratingKey]?.metadata
    }

    /// Check if cached full metadata is fresh enough to skip a network request
    func isFullMetadataFresh(for ratingKey: String, within interval: TimeInterval = 120) -> Bool {
        guard let entry = fullMetadataCache[ratingKey] else { return false }
        return Date().timeIntervalSince(entry.fetchedAt) < interval
    }

    /// Cache full metadata with LRU eviction at 50 entries
    func cacheFullMetadata(_ metadata: PlexMetadata, for ratingKey: String) {
        // LRU eviction: remove oldest entry if at capacity and this is a new key
        if fullMetadataCache[ratingKey] == nil && fullMetadataCache.count >= fullMetadataCacheLimit {
            if let oldestKey = fullMetadataCache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
                fullMetadataCache.removeValue(forKey: oldestKey)
            }
        }
        fullMetadataCache[ratingKey] = (metadata: metadata, fetchedAt: Date())
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

    /// Video and music libraries combined (for sidebar display)
    var visibleMediaLibraries: [PlexLibrary] {
        visibleLibraries.filter { $0.isVideoLibrary || $0.isMusicLibrary }
    }

    /// Check if any music library is visible in the sidebar
    var hasMusicLibraryVisible: Bool {
        !visibleMusicLibraries.isEmpty
    }

    /// Video and music libraries that should appear on the Home screen
    var librariesForHomeScreen: [PlexLibrary] {
        visibleMediaLibraries.filter { librarySettings.isLibraryShownOnHome($0.key) }
    }

    /// Libraries the user pinned to Home in Plex, in the server's order. This is
    /// the ONLY thing that decides which libraries contribute a Home row; see
    /// `projectHomeItems`. Deliberately not filtered by Rivulet's own
    /// shown-on-Home / visibility settings, so Home matches the Plex app rather
    /// than being a second, silently diverging configuration.
    var librariesPinnedToHome: [PlexLibrary] {
        libraries.filter { ($0.isVideoLibrary || $0.isMusicLibrary) && $0.isPinnedToHome }
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
    private var isPlaybackActive = false

    /// Track if app is in foreground
    private var isInForeground = true

    /// When the last full `/hubs` fetch completed and when the last
    /// Continue Watching fetch STARTED (either path). Used to gate the
    /// foreground-return and surface-appearance refreshes so they never
    /// duplicate a fetch the timers or the post-playback path just did.
    private var lastHubsFetchAt: Date?
    private var lastContinueWatchingFetchAt: Date?

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
            Task { @MainActor in self?.projectHomeItems() }
        }
    }

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

    /// Immediate stale-while-revalidate when the app returns to the
    /// foreground: the poll timers resume on `didBecomeActive` but their
    /// FIRST tick is a full interval away (30s / 3min), so without this a
    /// return from background shows whatever the home looked like when the
    /// app was suspended. CW always re-checks (small payload, equality-gated);
    /// the fat `/hubs` fetch only re-runs when older than its poll interval.
    /// Skipped on the launch activation (`didCompleteInitialHubFetch` false)
    /// so it never contends the launch-critical first paint.
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
            print("📦 PlexDataStore: ❌ Connection recovery failed")
            return false
        }
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
        fullMetadataCache.removeAll()

        // Clear in-memory data (libraries may differ per user)
        hubs = []
        continueWatchingHub = nil
        hasFetchedContinueWatching = false
        libraries = []
        hasLoadedLibraries = false
        libraryHubs.removeAll()
        libraryHubFetchFailures.removeAll()
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
            hubsError = "Not authenticated"
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
                print("📦 PlexDataStore: Continue Watching fetch error (keeping current hub): \(error)")
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

            // Always update Top Shelf cache after fetching (composites logo art)
            await updateTopShelfCache()
            self.hubsError = nil
            if updateLoading {
                self.isLoadingHubs = false
            }
            await cacheManager.cacheHubs(fetchedHubs)
            // Stage 1: refresh the additive MediaItem projection now that
            // hubs / continueWatchingHub changed. Off the launch-critical path
            // (this is the deferred network refresh) and a no-op for consumers
            // until a later stage renders from it.
            projectHomeItems()
            // The fetch returned cleanly: the server connection is up. A still
            // empty Home from here on is genuine, not the post-sign-in race.
            didCompleteInitialHubFetch = true
            lastHubsFetchAt = Date()
        } catch {
            let nsError = error as NSError
            print("📦 PlexDataStore: ❌ Hubs fetch error: \(error)")
            print("📦 PlexDataStore: Error domain: \(nsError.domain), code: \(nsError.code)")

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

    /// Refresh *only* the Continue Watching hub (`/hubs/continueWatching`), not
    /// the fat global `/hubs` payload. This is the fast-poll path: Continue
    /// Watching is the only Home row that meaningfully changes on a 30s cadence
    /// (resume position advances, items reorder as you watch), whereas Recently
    /// Added / genre rows barely move. Polling just this small hub keeps the row
    /// fresh without re-pulling the ~395KB `/hubs` response 6× as often.
    ///
    /// Reuses the same fetch call, equality gate, and projection as the full
    /// path (`fetchHubsFromServer`) so the two can't diverge. A thrown fetch is
    /// swallowed (keep the current hub) exactly as the full path does.
    private func fetchContinueWatchingOnly(serverURL: String, token: String) async {
        lastContinueWatchingFetchAt = Date()
        let userId = profileManager.selectedUserId
        let fetched: PlexHub?
        do {
            fetched = try await fetchContinueWatchingOffMain(serverURL: serverURL, token: token, userId: userId)
        } catch {
            // Transient error: keep the current hub, same as the full path.
            print("📦 PlexDataStore: Continue Watching fast-poll error (keeping current hub): \(error)")
            return
        }

        hasFetchedContinueWatching = true
        guard !continueWatchingHubsAreEqual(self.continueWatchingHub, fetched) else { return }
        self.continueWatchingHub = fetched
        self.hubsVersion = UUID()
        await updateTopShelfCache()
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
        // library PINNED IN PLEX has to be fetched or its row is silently
        // missing. Union with Rivulet's own shown-on-Home set so the library
        // pages that rely on this prefetch keep theirs too.
        var librariesToLoad = librariesPinnedToHome
        let pinnedKeys = Set(librariesToLoad.map { $0.key })
        librariesToLoad += librariesForHomeScreen.filter { !pinnedKeys.contains($0.key) }

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
                // Stage 1: refresh the additive MediaItem projection — the
                // home's "Recently Added <Library>" rows are derived from
                // libraryHubs, plus each library's own page projection.
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
                                print("📦 PlexDataStore: ❌ Failed to load hubs for \(library.title): \(error)")
                                Self.reportLibraryHubFetchFailure(library: library, error: error)
                                return (library.key, library.title, nil)
                            }
                        }
                    }

                    for await (key, _, hubs) in group {
                        noteLibraryHubFetchResult(key: key, hubs: hubs)
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
                                print("📦 PlexDataStore: ❌ Failed to refresh hubs for \(library.title): \(error)")
                                Self.reportLibraryHubFetchFailure(library: library, error: error)
                                return (library.key, library.title, nil)
                            }
                        }
                    }

                    for await (key, _, hubs) in group {
                        noteLibraryHubFetchResult(key: key, hubs: hubs)
                    }
                }
            }

            libraryHubsVersion = UUID()
            isLoadingLibraryHubs = false
            // Stage 1: final projection refresh after all library hubs land.
            projectAllLoadedItems()
        }

        await libraryHubsLoadTask?.value
        libraryHubsLoadTask = nil
    }

    /// Refresh hubs for all libraries on Home screen
    func refreshLibraryHubs() async {
        libraryHubs.removeAll()
        libraryHubFetchFailures.removeAll()
        await cacheManager.clearLibraryHubsCache()
        await loadLibraryHubsIfNeeded()
    }

    /// Apply one library's hub-fetch outcome. Success stores the hubs and
    /// clears any prior failure mark; failure (nil) leaves the last-known hubs
    /// in place and marks the key so `projectHomeItems()` carries that
    /// library's Recently Added row over instead of dropping it.
    private func noteLibraryHubFetchResult(key: String, hubs: [PlexHub]?) {
        guard let hubs else {
            libraryHubFetchFailures.insert(key)
            return
        }
        libraryHubs[key] = hubs
        libraryHubFetchFailures.remove(key)
        recordFetch(for: "libraryHubs:\(key)")
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

    // MARK: - MediaItem home projection (Stage 1 — additive, no UI consumer)
    //
    // `projectHomeItems()` builds `homeItems` to mirror EXACTLY the row set
    // that `PlexHomeViewController.computeSections()` produces for `.home`
    // mode, so a later stage can rebuild identical sections from this flat
    // `MediaItem` projection instead of the heavyweight `PlexMetadata` hubs.
    //
    // 1:1 mapping of computeSections() (PlexHomeViewController.swift:1589):
    //   • Hero row              — EXCLUDED. Hero items come from a separate
    //     selection (`selectHeroItemsIfNeeded`), not the hub store, so they
    //     are not part of this hub projection. A later stage's hero stays on
    //     its own path.
    //   • Continue Watching     — `continueWatchingHub` when it has Metadata.
    //         id = HomeSectionID.hub(cw.id).raw  ("hub:<cw.id>")
    //         title = cw.title ?? "Continue Watching"
    //         isContinueWatching = true
    //         hubKey = cw.key ?? cw.hubKey ; hubIdentifier = cw.hubIdentifier
    //   • Recently Added rows   — one per `librariesForHomeScreen` (same order),
    //     taking that library's first hub matching `isRecentlyAdded`, when it
    //     has Metadata.
    //         id = HomeSectionID.hub("<library.key>:recent").raw
    //         title = recent.title (the server's own, localized)
    //         isContinueWatching = false
    //         hubKey = recent.key ?? recent.hubKey ; hubIdentifier = recent.hubIdentifier
    //   • Watchlist / Recommendations — EXCLUDED. Both come from services
    //     (`PlexWatchlistService` / `PersonalizedRecommendationService`), not
    //     the hub store; they remain on their own paths in a later stage.
    //
    // Item de-dupe mirrors computeSections' end-to-end identity: it keys
    // diffable items by `meta.ratingKey` and drops repeats (applySnapshot,
    // PlexHomeViewController.swift:1561-1566). Here we de-dupe the mapped
    // `MediaItem`s by `ref.itemID` (== ratingKey via PlexMediaMapper.item),
    // keeping first occurrence. We do NOT apply the per-row pagination
    // `mergedItems` accumulation (that's runtime VC state, not part of the
    // initial server projection) — `totalSize` is therefore left nil until a
    // later stage threads pagination through; the initial render set matches.
    func projectHomeItems() {
        // Home is the user's Plex home, reproduced from the server's own state.
        //
        // TWO server-side fields decide it, and both arrive on endpoints this
        // store already fetches. Verified against a live PMS 1.43.3:
        //
        //   1. WHICH LIBRARIES contribute — `PlexLibrary.hidden` from
        //      `/library/sections`. 0 = pinned to Home, 1 = hidden from Home,
        //      2 = hidden from Home and the sidebar. This is what the Plex app's
        //      "Pin to home" control writes. On the reference server the six
        //      `hidden == 0` libraries were exactly the six with a Home-promoted
        //      hub, and the seven hidden ones had none.
        //
        //   2. WHICH HUB inside a pinned library — `PlexHub.promoted` from
        //      `/hubs/sections/{key}`. Exactly one hub per library carries it
        //      (`movie.recentlyadded.1`, `tv.recentlyadded.2`, …); every other
        //      hub in the same response has it absent. It is the section
        //      endpoint's spelling of `promotedToOwnHome` from `.../manage`, NOT
        //      of `promotedToRecommended` (which is true for nearly everything).
        //
        // The obvious-looking source, the global `/hubs` payload, is the WRONG
        // one and is what this projection used to read. `/hubs` is a legacy
        // aggregate: it collapses every movie library into one cross-library
        // "Recently Added Movies" row, and it carries a `home.playlists` row
        // that the Plex app never shows. The Plex app calls
        // `/hubs/promoted?contentDirectoryID={key}&pinnedContentDirectoryID={csv}`
        // once per pinned library and concatenates; scoping by
        // `contentDirectoryID` is precisely what drops `home.playlists`.
        // Reading `promoted` off the per-library hubs Rivulet already has gives
        // the same row set without the extra N requests.
        //
        // Continue Watching stays first and comes from `/hubs/continueWatching`,
        // which is the MERGED hub: on the reference server it held 18 of the 19
        // items in the union of `home.continue` (in-progress) and `home.ondeck`
        // (next up), so the two collapse into one row rather than duplicating
        // most of a shelf. Plex has no flag for that; it has this endpoint.
        //
        // The old app-composed row set is kept below, commented, until this has
        // had a real look on device.
        var rail: CachedHomeRail = []

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
        }

        // One row per promoted hub, per pinned library, in the server's order.
        for library in librariesPinnedToHome {
            for hub in libraryHubs[library.key] ?? [] {
                guard hub.promoted == true else { continue }
                // A library's own in-progress hub would duplicate the global
                // Continue Watching row above.
                guard !Self.isContinueWatchingFamily(hubIdentifier: hub.hubIdentifier) else { continue }
                // Local subtractive filter — see `HomeRowSettings`.
                guard !HomeRowSettings.isHidden(hub.hubIdentifier) else { continue }
                guard let metas = hub.Metadata, !metas.isEmpty else { continue }

                rail.append(makeCachedHub(
                    id: "hub:\(hub.id)",
                    title: hub.title ?? "",
                    isContinueWatching: false,
                    hubKey: hub.key ?? hub.hubKey,
                    hubIdentifier: hub.hubIdentifier,
                    metas: metas
                ))
            }
        }

        // An empty projection is only allowed to replace a populated Home once a
        // fetch has actually completed. Before that the sources are empty
        // because nothing has landed yet, and blanking the rail here is
        // permanent: `setHomeItems` re-persists it, so one early call would bake
        // an empty Home into every subsequent warm launch (the trap #236 hit).
        guard !rail.isEmpty || didCompleteInitialHubFetch else { return }

        setHomeItems(rail)
    }

    /// Whether a promoted hub belongs to the Continue Watching family, meaning
    /// it gets the backdrop-and-logo resume tiles and its items come from the
    /// dedicated fast-refresh fetch.
    ///
    /// Matched on the identifier alone. The obvious-looking alternative, testing
    /// the `/hubs` row against `continueWatchingHub`'s identifier so the server
    /// names its own row, is WRONG: the two endpoints do not agree. `/hubs`
    /// calls it `home.continue` and `/hubs/continueWatching` calls itself
    /// `continueWatching`, so comparing them matched nothing, `isContinueWatching`
    /// came out false, and the row rendered as an ordinary poster shelf.
    ///
    /// On Deck is deliberately IN the family. Plex has folded the two concepts
    /// together (the server's own `OnDeckWindow` / `OnDeckLimit` prefs are
    /// labelled "Continue Watching"), the rows share most of their items, and
    /// `/hubs/continueWatching` returns the merge. The projection emits the
    /// first family member and drops the rest, so they collapse into one row.
    nonisolated static func isContinueWatchingFamily(hubIdentifier: String?) -> Bool {
        let id = (hubIdentifier ?? "").lowercased()
        guard !id.isEmpty else { return false }
        return id.contains("continue") || id.contains("inprogress") || id.contains("ondeck")
    }

    /// A hub key the pagination path can actually call, or nil.
    ///
    /// Most `/hubs` rows carry no `hubKey` and a `key` that is a literal id list
    /// (`/library/metadata/209601,209469,…`), which is a metadata fetch, not a
    /// hub endpoint. Handing that to `loadMoreIfNeeded` would page against the
    /// wrong URL and re-append the items already on screen. Returning nil turns
    /// pagination off for the row instead, which is correct rather than merely
    /// safe: the row is the fixed set the server promoted.
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

    // MARK: - Superseded: app-composed Home rows
    //
    // Rivulet's own Home composition, replaced by the promoted-hub projection
    // above. Kept commented rather than deleted while the server-driven set is
    // evaluated on device; delete once it has stuck.
    //
    // private func projectHomeItemsAppComposed() {
    //     var rail: CachedHomeRail = []
    //
    // Continue Watching
    //
    //     // `/hubs/continueWatching` is an ACCOUNT-level endpoint: one flat list
    //     // spanning every library on the server, with no way to scope the
    //     // request. Rivulet's shown-on-Home set is client-side UserDefaults that
    //     // Plex never sees, so a library the user removed from Home still
    //     // contributes rows here. Filter before `makeCachedHub`, because mapping
    //     // to `MediaItem` discards the section attribution the predicate needs.
    //     // Fails open on an unloaded library list / unattributed item — see
    //     // `PlexLibraryVisibilityFilter`.
    //     let homeLibraryKeys = librariesForHomeScreen.map { $0.key }
    //     if let cw = continueWatchingHub,
    //        let items = cw.Metadata, !items.isEmpty,
    //        case let visible = PlexLibraryVisibilityFilter.filter(items, toLibraryKeys: homeLibraryKeys),
    //        !visible.isEmpty {
    //         rail.append(makeCachedHub(
    //             id: "hub:\(cw.id)",
    //             title: cw.title ?? "Continue Watching",
    //             isContinueWatching: true,
    //             hubKey: cw.key ?? cw.hubKey,
    //             hubIdentifier: cw.hubIdentifier,
    //             metas: visible
    //         ))
    //     } else if !hasFetchedContinueWatching,
    //               let existingCW = homeItems.first(where: { $0.isContinueWatching }) {
    //         // Stage-3 ordering guard: `continueWatchingHub` is fetched on a
    //         // separate path and is nil for a beat after a warm launch. A
    //         // projection triggered before it lands (e.g. the deferred
    //         // library-hubs cache projection) must NOT drop the Continue
    //         // Watching row the launch cache-paint already showed — carry the
    //         // existing projected CW row over until the network refresh
    //         // replaces it with fresh metadata.
    //         //
    //         // Gated on `hasFetchedContinueWatching`: once a fresh fetch HAS
    //         // completed for the current user, nil/empty means this user has no
    //         // Continue Watching — carrying the row past that point made a
    //         // stale CW row (from a previous account/profile) self-perpetuating,
    //         // because setHomeItems() re-persists whatever the rail contains.
    //         rail.append(existingCW)
    //     }
    //
    //     // Recently Added per home library (same order as librariesForHomeScreen)
    //     for library in librariesForHomeScreen {
    //         let rowID = Self.recentlyAddedRowID(forLibraryKey: library.key)
    //         if let hubs = libraryHubs[library.key],
    //            let recent = hubs.first(where: { isRecentlyAddedHub($0) }),
    //            let items = recent.Metadata, !items.isEmpty {
    //             rail.append(makeCachedHub(
    //                 id: rowID,
    //                 // The SERVER's title, not one composed here. PMS localizes
    //                 // hub titles from the request's `Accept-Language`, which
    //                 // URLSession already sends from the device locale, so this
    //                 // row arrives correctly worded and in the viewer's language
    //                 // for free. Composing `"Recently Added " + library.title`
    //                 // threw that away and pasted an English prefix onto the
    //                 // user's own library name, so a French viewer read
    //                 // "Recently Added Films" while Continue Watching beside it
    //                 // read "Continuer à regarder" (issue #276). Verified
    //                 // against a live PMS 1.43.3: `Accept-Language: fr-FR` on
    //                 // `/hubs/sections/{key}` returns "Récemment ajouté dans
    //                 // Movies", and the library name stays untranslated because
    //                 // it is the user's own.
    //                 title: recent.title ?? "Recently Added \(library.title)",
    //                 isContinueWatching: false,
    //                 hubKey: recent.key ?? recent.hubKey,
    //                 hubIdentifier: recent.hubIdentifier,
    //                 metas: items
    //             ))
    //         } else if Self.shouldCarryOverRecentlyAddedRow(
    //             hubs: libraryHubs[library.key],
    //             fetchFailed: libraryHubFetchFailures.contains(library.key)
    //         ), let existing = homeItems.first(where: { $0.id == rowID }) {
    //             // Same guard as Continue Watching above, per library: a
    //             // library whose hub fetch threw or has not landed yet must NOT
    //             // lose the Recently Added row the cache-paint already showed.
    //             // Dropping it here is permanent, not transient — setHomeItems()
    //             // re-persists the rail, so one timed-out fetch would bake the
    //             // missing shelf into every subsequent warm launch (GitHub #236).
    //             //
    //             // Only a library that ANSWERED — hubs present, no recentlyAdded
    //             // hub or an empty one — correctly projects no row.
    //             rail.append(existing)
    //         }
    //     }
    //
    //     setHomeItems(rail)
    // }

    /// `projectHomeItems` for a single library page — mirrors
    /// `PlexHomeViewController.computeLibrarySections()` (one row per library
    /// hub in Plex's order, de-duped by hub identity; hero / sort-header /
    /// grid are not hub rows and are excluded). Stored in `libraryItemsByKey`.
    func projectLibraryItems(forKey key: String) {
        var rail: CachedHomeRail = []
        var seenIDs = Set<String>()
        for hub in libraryHubs[key] ?? [] {
            guard let items = hub.Metadata, !items.isEmpty else { continue }
            // Identical hub-identity chain + de-dupe to computeLibrarySections.
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

    /// Assigns `homeItems`, bumps `homeItemsVersion`, persists, and emits the
    /// Stage-1 parity log. Centralized so every projection path is identical.
    private func setHomeItems(_ rail: CachedHomeRail) {
        homeItems = rail
        homeItemsVersion = UUID()
        let totalItems = rail.reduce(0) { $0 + $1.items.count }
        // Stage-1 parity probe (cheap; left in deliberately so a device run can
        // sanity-check the projected row/item counts against computeSections).
        print("📦 [MediaItemProjection] homeItems rows=\(rail.count) items=\(totalItems)")
        Task { await cacheManager.cacheHomeItems(rail) }
    }

    /// Stage-3 launch fast-paint: assigns `homeItems` + bumps the version from
    /// the on-disk MediaItem cache WITHOUT re-writing it (the rail came from
    /// the cache, so re-caching would be redundant disk I/O on the launch path).
    private func setHomeItemsFromCache(_ rail: CachedHomeRail) {
        homeItems = rail
        homeItemsVersion = UUID()
    }

    /// Stage-3 library launch fast-paint: assigns one library's projection
    /// from the on-disk cache without re-writing it.
    private func setLibraryItemsFromCache(_ rail: CachedHomeRail, forKey key: String) {
        libraryItemsByKey[key] = rail
        libraryHubsVersion = UUID()
    }

    /// Stage-3: paint a single library page's rows from the flat MediaItem
    /// cache (`getCachedLibraryItems`). Returns true if a non-empty cache was
    /// painted. Used by the library-mode launch path to avoid the heavyweight
    /// [PlexHub] decode before first paint.
    func paintLibraryItemsFromCacheIfNeeded(forKey key: String) async -> Bool {
        if let existing = libraryItemsByKey[key], !existing.isEmpty { return true }
        guard let cached = await cacheManager.getCachedLibraryItems(forLibrary: key),
              !cached.isEmpty else { return false }
        setLibraryItemsFromCache(cached, forKey: key)
        return true
    }

    /// Maps a hub's `[PlexMetadata]` → `[MediaItem]` and de-dupes by
    /// `ref.itemID` (the Plex ratingKey), mirroring computeSections' item
    /// identity de-dupe. providerID/serverURL/authToken are obtained exactly
    /// as the home VC's cell/preview path does
    /// (PlexHomeViewController.swift:2048-2050): primary provider id with a
    /// `plex:<serverURL>` fallback, and the selected server URL + token.
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
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
        var seen = Set<String>()
        let items: [MediaItem] = metas.compactMap { meta in
            let item = PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
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

    /// Keep the disk-backed launch hero projection in lockstep with
    /// `PlexHomeViewController.computeHubBackedHero(from:)` so warm launches
    /// can start the hero image load without decoding the full `[PlexHub]`
    /// cache first.
    /// Replica of `PlexHomeViewController.isRecentlyAdded(_:)` — the home
    /// projection must select the SAME "Recently Added" hub per library.
    private func isRecentlyAddedHub(_ hub: PlexHub) -> Bool {
        let id = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return id.contains("recentlyadded") || title.contains("recently added")
    }

    /// Stable projection row id for a library's "Recently Added" shelf. Shared
    /// by the fresh-projection and carry-over paths so they can never disagree
    /// about which cached row belongs to which library.
    nonisolated static func recentlyAddedRowID(forLibraryKey key: String) -> String {
        "hub:\(key):recent"
    }

    /// Whether a library that produced no usable Recently Added hub this pass
    /// should keep its previously-projected row (GitHub #236).
    ///
    /// The distinction that matters is whether the library ANSWERED:
    /// - `hubs == nil` — never loaded, or loaded and threw. Either way we know
    ///   nothing about this library's content, so dropping its shelf would be
    ///   an assertion we can't back. Carry over.
    /// - `fetchFailed` — the last fetch threw. `hubs` may still hold a stale
    ///   non-nil payload from an earlier pass, so nil-ness alone misses this.
    ///   Carry over.
    /// - otherwise — the server answered with this library's hubs and they
    ///   contain no non-empty recentlyAdded hub. The library is genuinely
    ///   empty (or has the row disabled server-side); omit it.
    nonisolated static func shouldCarryOverRecentlyAddedRow(hubs: [PlexHub]?, fetchFailed: Bool) -> Bool {
        hubs == nil || fetchFailed
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
            librariesError = "Not authenticated"
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
            // Sync library order settings with current libraries
            self.librarySettings.syncOrderWithLibraries(fetched)
            await cacheManager.cacheLibraries(fetched)
        } catch {
            let nsError = error as NSError
            print("📦 PlexDataStore: ❌ Libraries fetch error: \(error)")
            print("📦 PlexDataStore: Error domain: \(nsError.domain), code: \(nsError.code)")

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
        // Delegate to the shared per-item comparison so this path can't drift
        // from `hubsAreEqual`. Comparing ratingKeys alone (the old behaviour)
        // ignored `viewOffset`, which froze Continue Watching progress bars
        // after a refresh — the item set was unchanged so the refreshed hub was
        // judged "equal" and never re-published.
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

    // MARK: - Optimistic Updates

    /// Update an item's watch status locally (optimistic update)
    /// This immediately reflects the change in UI before the server refresh completes.
    ///
    /// The same `ratingKey` can appear in multiple hub collections at once:
    /// - `hubs` — the global `/hubs` response, home of Continue Watching.
    /// - `libraryHubs[libraryKey]` — per-library hubs, home of "Recently Added <Library>".
    ///
    /// Both must be walked so a Mark as Watched from Continue Watching also
    /// flips the checkmark on the same title in a Recently Added row below.
    func updateItemWatchStatus(ratingKey: String, watched: Bool) {
        func applyWatchState(to item: inout PlexMetadata) {
            if watched {
                item.viewCount = (item.viewCount ?? 0) + 1
                item.viewOffset = nil
            } else {
                item.viewCount = 0
                item.viewOffset = nil
            }
        }

        var didUpdateHubs = false
        // Update in global hubs (Continue Watching lives here)
        for hubIndex in hubs.indices {
            guard var metadata = hubs[hubIndex].Metadata else { continue }
            var hubChanged = false
            for itemIndex in metadata.indices where metadata[itemIndex].ratingKey == ratingKey {
                applyWatchState(to: &metadata[itemIndex])
                hubChanged = true
            }
            if hubChanged {
                hubs[hubIndex].Metadata = metadata
                didUpdateHubs = true
            }
        }

        var didUpdateLibraryHubs = false
        // Update in per-library hubs (Recently Added <Library> rows live here)
        for (libraryKey, hubList) in libraryHubs {
            var updatedHubList = hubList
            var libraryChanged = false
            for hubIndex in updatedHubList.indices {
                guard var metadata = updatedHubList[hubIndex].Metadata else { continue }
                var hubChanged = false
                for itemIndex in metadata.indices where metadata[itemIndex].ratingKey == ratingKey {
                    applyWatchState(to: &metadata[itemIndex])
                    hubChanged = true
                }
                if hubChanged {
                    updatedHubList[hubIndex].Metadata = metadata
                    libraryChanged = true
                }
            }
            if libraryChanged {
                libraryHubs[libraryKey] = updatedHubList
                didUpdateLibraryHubs = true
            }
        }

        // Bump versions so views recompute their derived state
        if didUpdateHubs {
            hubsVersion = UUID()
        }
        if didUpdateLibraryHubs {
            libraryHubsVersion = UUID()
        }

        // Stage 1: keep the additive MediaItem projection consistent with the
        // optimistic watch-state edit (off the launch-critical path — this is
        // a user-action update, not launch). Only re-project the surfaces that
        // actually changed.
        if didUpdateHubs {
            projectHomeItems()
        }
        if didUpdateLibraryHubs {
            projectAllLoadedItems()
        }
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

        let videoLibraries = libraries

        // Run heavy prefetch work off the main actor; only hop back when touching UI state.
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Prefetch content for each visible/pinned video library only
            for library in videoLibraries {
                guard !Task.isCancelled else { break }

                let libraryKey = library.key

                // Check if already cached
                let hasMoviesCache = await self.cacheManager.getCachedMovies(forLibrary: libraryKey) != nil
                let hasShowsCache = await self.cacheManager.getCachedShows(forLibrary: libraryKey) != nil
                let hasHubsCache = await self.cacheManager.getCachedLibraryHubs(forLibrary: libraryKey) != nil

                if hasMoviesCache || hasShowsCache {
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

    // MARK: - Top Shelf Cache

    /// Update the Top Shelf cache with Continue Watching items
    /// Called after hubs are fetched to keep Top Shelf in sync
    private func updateTopShelfCache() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            print("TopShelf: No server URL or token available")
            return
        }

        // Source from the dedicated /hubs/continueWatching hub — the same source
        // the in-app Continue Watching row trusts. The old global-/hubs scrape
        // dropped movies (GitHub #194); the dedicated hub returns movies + episodes.
        let metadata = continueWatchingHub?.Metadata ?? []
        let baseItems = TopShelfMapper.items(from: metadata, serverURL: serverURL, token: token, limit: 5)

        // Composite backdrop + clearLogo in-app (Apple TV+ look); the extension
        // only reads the finished files. Never throws; falls back to the plain
        // backdrop per item when no logo or on any failure.
        let items = await TopShelfComposer.composite(items: baseItems, serverURL: serverURL, token: token)

        TopShelfCache.shared.writeItems(items)
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
        libraryHubFetchFailures.removeAll()
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
        fullMetadataCache.removeAll()
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
