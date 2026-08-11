// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexHomeViewController.swift
//  Rivulet
//
//  UIKit/TVUIKit implementation of the Plex Home screen. Mirrors the
//  SwiftUI `PlexHomeView` feature set so it can replace it 1:1.
//
//  Composition:
//    - `HeroBackdropView` (fixed): full-bleed sibling of the collection
//      view, translated upward on scroll for the receding parallax effect
//      (matches the SwiftUI `.offset(y: -heroScrollOffset * 1.3 ...)`).
//    - `UICollectionView` (scrolling):
//        * Section 0: hero overlay (SwiftUI `HeroOverlayContent` via
//          `HeroOverlayCell` / UIHostingController) — when hero is enabled
//        * Section 1: Continue Watching (`ContinueWatchingCell`)
//        * Sections 2..N: Recently Added per Home library (`PosterCell`)
//        * Section N+1: Watchlist (`WatchlistPosterCell`)
//        * Section N+2: Personalized Recommendations (`PosterCell`)
//
//  Navigation:
//    - Detail navigation is UIKit-native: standalone expanded detail /
//      episode detail page presented from this controller. Only music
//      selections hand back to SwiftUI (`onSelectMusic`).
//    - Preview carousel is presented as `PreviewContainerViewController`
//      (a UIKit overFullScreen modal hosting SwiftUI `PreviewOverlayHost`)
//      from this controller — mirrors the SwiftUI flow.
//    - Resume-or-restart prompt is a `UIAlertController(.actionSheet)`.
//
//  Focus restoration:
//    - `UICollectionView.remembersLastFocusedIndexPath = true` keeps the
//      last focused tile in each row.
//    - When the preview is dismissed with a `PreviewSourceTarget`, we
//      translate that into the matching `IndexPath` and force a focus
//      update there.
//

import UIKit
import TVUIKit
import Combine
import os.log

private let homeUIKitLog = Logger(subsystem: "com.rivulet.app", category: "PlexHomeUIKit")

// MARK: - Section model

nonisolated struct HomeSectionID: Hashable, Sendable {
    let raw: String
    static let hero = HomeSectionID(raw: "hero")
    static let watchlist = HomeSectionID(raw: "watchlist")
    static let recommendations = HomeSectionID(raw: "recommendations")
    /// Library-mode-only sections: the sort header (title + count + sort
    /// button) and the paginated poster grid below the hub rows.
    static let sortHeader = HomeSectionID(raw: "sortHeader")
    static let grid = HomeSectionID(raw: "grid")
    /// Search-mode-only sections: the empty-query prompt, the inline
    /// searching/error/no-results state, and the grouped result grids.
    static let searchPrompt = HomeSectionID(raw: "search.prompt")
    static let searchState = HomeSectionID(raw: "search.state")
    static func searchGroup(_ key: String) -> HomeSectionID { .init(raw: "search.group:\(key)") }
    static func hub(_ hubID: String) -> HomeSectionID { .init(raw: "hub:\(hubID)") }
}

/// Which surface this controller renders. The library page IS the home page —
/// same hero, rows, focus, scroll, backdrop — just fed a single library's hubs
/// (plus, later, a sortable grid section). One implementation, two surfaces:
/// parity by construction instead of a separate VC that drifts.
enum HomeMode {
    case home
    /// A single Plex library (`key` = section id, `title` for headers).
    case library(key: String, title: String)
    /// The Discover surface: identical hero + shelf layout, but every row is
    /// a TMDB curated list (plus "For You") mapped to MediaItem via
    /// TMDBMediaMapper. No Plex hubs, grid, or recommendations.
    case discover
    /// The Search surface: no hero — a prompt/recents state when the query is
    /// empty, inline searching/error/no-results states, and grouped poster
    /// GRIDS of results (Movies & TV / Episodes & Seasons / Music). The query
    /// arrives from `SearchContainerViewController` via `updateSearchQuery`.
    case search
}

nonisolated struct HomeItemID: Hashable, Sendable {
    let sectionID: HomeSectionID
    /// Item identifier — ratingKey for hubs and recommendations,
    /// watchlist-entry id for watchlist, "hero-overlay" for hero,
    /// `skeletonSentinel` for the loading-skeleton card at row end.
    let itemID: String

    /// Reserved string used as the itemID for a section's loading-skeleton
    /// card. No real Plex/watchlist item will ever produce this value.
    static let skeletonSentinel = "__skeleton__"
}

enum HomeSectionKind: Equatable {
    case hero
    case continueWatching
    case recentlyAdded
    case watchlist
    /// Populated recommendations row — renders PosterCells.
    case recommendations
    /// Inline loading state — single full-width spinner + message cell.
    case recommendationsLoading
    /// Inline error state — single full-width warning + retry cell. The
    /// message itself lives on the controller as `recommendationsError`;
    /// the kind is just a tag so the layout/render code can pick it.
    case recommendationsError
    /// Library mode only — full-width sort header (library title + item
    /// count + focusable sort button, `MediaLibrarySortControl`).
    case sortHeader
    /// Library mode only — 6-across paginated poster grid of the whole
    /// library, sorted by `gridSort`.
    case grid
    /// Discover mode only — a TMDB curated list (or "For You") shelf.
    /// Renders identically to a poster hub row; differs in tap routing
    /// (always the preview carousel) and context menu (watchlist toggle +
    /// library-matched Details instead of Plex actions). No pagination.
    case discoverList
    /// Search mode only — the empty-query prompt + recent-searches pills.
    case searchPrompt
    /// Search mode only — inline searching / error / no-results state.
    case searchState
    /// Search mode only — one grouped result grid (Movies & TV, Episodes &
    /// Seasons, Music) with a row-style header. Same 6-across poster grid
    /// as the library, no pagination (search caps at 80 results).
    case searchGrid
}

struct HomeSectionData {
    let id: HomeSectionID
    let kind: HomeSectionKind
    let title: String?
    /// Which header style applies — SwiftUI uses two distinct ones:
    /// InfiniteContentRow style (30pt semibold white-0.6, optional inline
    /// count) vs WatchlistHubRow style (28pt bold white, no count).
    let headerStyle: HubHeaderView.Style
    /// Total item count from Plex for the "X of Y" indicator. nil when
    /// pagination hasn't loaded a total yet, which is the case for first
    /// render of every section.
    let totalSize: Int?
    /// MediaItems for hub/recommendations/CW/grid sections. The home renders
    /// shelves from these flat items (Stage 2 of MEDIAITEM_HOME_PLAN) instead
    /// of materializing the heavyweight PlexMetadata at launch.
    let items: [MediaItem]
    /// Watchlist entries for the watchlist section.
    let watchlistItems: [PlexWatchlistItem]
    /// Hero carousel items (used by the hero overlay cell). Hero stays
    /// PlexMetadata-backed until Stage 4.
    let heroItems: [PlexMetadata]
    /// MediaItem-backed hero carousel items (Discover mode — TMDB-mapped).
    /// When non-empty, the hero cell uses the MediaItem configuration path
    /// instead of `heroItems`.
    var heroMediaItems: [MediaItem] = []
    let hubKey: String?
    let hubIdentifier: String?

    /// True when this section holds music (artist/album/track). Sections are
    /// content-uniform (a whole row / library is music or not), so the first
    /// item is representative. Drives 1:1 square tiles instead of 2:3 posters.
    var isMusic: Bool { items.first?.isMusic == true }

    static func hub(id: HomeSectionID, title: String, items: [MediaItem], isContinueWatching: Bool, hubKey: String?, hubIdentifier: String?, totalSize: Int? = nil) -> HomeSectionData {
        HomeSectionData(
            id: id,
            kind: isContinueWatching ? .continueWatching : .recentlyAdded,
            title: title,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: totalSize,
            items: items,
            watchlistItems: [],
            heroItems: [],
            hubKey: hubKey,
            hubIdentifier: hubIdentifier
        )
    }

    static func hero(items: [PlexMetadata]) -> HomeSectionData {
        HomeSectionData(
            id: .hero,
            kind: .hero,
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: [],
            watchlistItems: [],
            heroItems: items,
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    static func watchlist(items: [PlexWatchlistItem]) -> HomeSectionData {
        HomeSectionData(
            id: .watchlist,
            kind: .watchlist,
            title: "Watchlist",
            headerStyle: .swiftUIWatchlist,
            totalSize: nil,
            items: [],
            watchlistItems: items,
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    static func recommendations(items: [MediaItem]) -> HomeSectionData {
        HomeSectionData(
            id: .recommendations,
            kind: .recommendations,
            title: "Personalized Recommendations",
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: items,
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    /// Discover mode: one TMDB curated list (or "For You") shelf.
    static func discoverList(id: HomeSectionID, title: String, items: [MediaItem]) -> HomeSectionData {
        HomeSectionData(
            id: id,
            kind: .discoverList,
            title: title,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: items,
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    /// Search mode: empty-query prompt with recent searches.
    static func searchPrompt() -> HomeSectionData {
        HomeSectionData(
            id: HomeSectionID.searchPrompt,
            kind: .searchPrompt,
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: [],
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    /// Search mode: inline searching / error / no-results state.
    static func searchState() -> HomeSectionData {
        HomeSectionData(
            id: HomeSectionID.searchState,
            kind: .searchState,
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: [],
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    /// Search mode: one grouped result grid with a header.
    static func searchGrid(id: HomeSectionID, title: String, items: [MediaItem]) -> HomeSectionData {
        HomeSectionData(
            id: id,
            kind: .searchGrid,
            title: title,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: items,
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    /// Discover mode: hero carousel backed by TMDB-mapped MediaItems.
    static func discoverHero(items: [MediaItem]) -> HomeSectionData {
        HomeSectionData(
            id: .hero,
            kind: .hero,
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: [],
            watchlistItems: [],
            heroItems: [],
            heroMediaItems: items,
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    static func recommendationsLoading() -> HomeSectionData {
        HomeSectionData(
            id: .recommendations,
            kind: .recommendationsLoading,
            // The loading state is an inline status row that replaces the
            // row entirely — no row title. nil here suppresses the
            // section-header.
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: [],
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    /// Library mode: the sort-header section. `title` carries the library
    /// title for `MediaLibrarySortControl.configure(title:count:sortName:)`;
    /// count + sort name live on the controller (totalGridCount / gridSort).
    static func sortHeader(title: String) -> HomeSectionData {
        HomeSectionData(
            id: .sortHeader,
            kind: .sortHeader,
            title: title,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: [],
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    /// Library mode: the paginated poster grid. `items` carries the
    /// loaded grid items.
    static func grid(items: [MediaItem]) -> HomeSectionData {
        HomeSectionData(
            id: .grid,
            kind: .grid,
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: items,
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }

    static func recommendationsError() -> HomeSectionData {
        HomeSectionData(
            id: .recommendations,
            kind: .recommendationsError,
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
            totalSize: nil,
            items: [],
            watchlistItems: [],
            heroItems: [],
            hubKey: nil,
            hubIdentifier: nil
        )
    }
}

// MARK: - Controller

@MainActor
final class PlexHomeViewController: UIViewController {

    // Callbacks back into the SwiftUI shell.
    var onSelectMusic: ((PlexMetadata) -> Void)?


    /// Search mode: the controller changed the query itself (a recents pill
    /// was tapped) — the container mirrors it into the search bar.
    var onSearchQueryChangedByController: ((String) -> Void)?

    /// Surface selector — .home (default) or .library(key:title:). All
    /// library-specific behavior branches off this; home-mode code paths are
    /// byte-identical to before the mode was introduced.
    let mode: HomeMode

    init(mode: HomeMode = .home) {
        self.mode = mode
        // Library mode restores the user's persisted per-library sort (the
        // same LibrarySettingsManager slot the SwiftUI PlexLibraryView used).
        // Home mode never reads gridSort; the default is inert.
        if case .library(let key, _) = mode {
            self.gridSort = LibrarySettingsManager.shared.getSortOption(for: key)
        } else {
            self.gridSort = .addedAtDesc
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        // Diagnostic for the launch double-build: confirms whether the
        // discarded first instance actually deallocates. Cancellables release
        // with the instance, and the scroll display link holds only a weak
        // proxy (see DisplayLinkProxy), so nothing here can pin the VC.
        StartupTimer.mark("PlexHomeVC deinit")
    }

    /// Library-mode loading/error state for this library's hub fetch
    /// (home mode uses dataStore.isLoadingHubs / hubsError instead).
    private var isLoadingLibraryHubs = false
    private var libraryHubsError: String?

    private let dataStore = PlexDataStore.shared
    private let authManager = PlexAuthManager.shared
    private let watchlistService = PlexWatchlistService.shared
    private let recommendationService = PersonalizedRecommendationService.shared

    /// Standard tvOS frosted background (adapts to light/dark). The backmost
    /// layer of the screen; the hero art and the collection sit in front. As
    /// the hero art translates up on scroll it reveals this surface instead of
    /// flat black, matching the Apple TV+ home. Stays visible when the hero is
    /// off too.
    /// Backmost ambient wash (artwork diffused by the frost above it);
    /// latched once per screen — see updateAmbientIfNeeded().
    private var ambientView: AmbientBackdropView!
    private var backgroundBlurView: UIVisualEffectView!
    private var backdropView: HeroBackdropView!
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HomeSectionID, HomeItemID>!

    /// Sits at the leading edge of the collection view and absorbs
    /// fast Left-swipe focus moves that would otherwise escape to the
    /// sidebar mid-row. Updated in `didUpdateFocus`: when the focused
    /// cell is at item 0 of its row (or in a non-orthogonal section),
    /// `preferredFocusEnvironments = []` and the guide is transparent
    /// to the engine — focus passes through to the sidebar normally.
    /// When the focused cell is item ≥1 of a horizontal row, the guide
    /// redirects to the cell at `indexPath.item - 1` (and we scroll
    /// the orthogonal section so that cell is on screen).
    private var leftEdgeFocusGuide: UIFocusGuide!

    /// Full-screen state placeholder (notConnected / loading / error / empty).
    /// `isHidden` toggles based on auth + data-store state precedence
    /// matching `PlexHomeView.body`.
    private var stateView: HomeStateView!
    /// True while `stateView` is showing a state that carries a focusable
    /// action button (.error / .empty). Drives preferredFocusEnvironments so a
    /// contentless Home always has a reachable focus target.
    private var stateViewHasFocusableAction = false
    /// Transient toast for watchlist-write errors. Bottom-anchored, fades
    /// in when `watchlistService.transientWriteError` becomes non-nil.
    private var watchlistToast: WatchlistToastView!
    /// Yellow warning banner at the top of the content scroll when we're
    /// rendering cached content but the Plex connection check is failing.
    private var connectionBanner: ConnectionErrorBannerView!
    /// Top inset reserved for the connection banner when it's visible.
    /// Stored so we can toggle it cleanly without recomputing.
    private var connectionBannerTopInset: CGFloat = 0

    private var sectionsSnapshot: [HomeSectionData] = []

    /// Hero carousel index (drives backdrop image + overlay current item).
    private var heroCurrentIndex: Int = 0
    private var heroItems: [PlexMetadata] = []

    /// Coalescing state for the TMDB trending-hero upgrade. The upgrade is
    /// triggered from many sites (hub loads, library refreshes, the GUID-index
    /// notification); without coalescing it re-runs 20+ times per launch. An
    /// in-flight run absorbs concurrent triggers, and a run is skipped entirely
    /// when the GUID index generation hasn't changed since the last completed run.
    private var heroUpgradeTask: Task<Void, Never>?
    private var lastUpgradedIndexGeneration = -1

    private var dataStoreObservers: Set<AnyCancellable> = []

    private var hasMarkedFirstFrame = false
    private var hasLoadedRecommendations = false
    private var isInitialHomeLoadPending = false

    /// Pending focus restoration after preview dismiss.
    private var pendingPreviewRestore: PreviewSourceTarget?
    private var shouldRestoreCollectionFocusMemoryAfterPreview = false

    /// Per-section pagination state. Keyed by HomeSectionID. Mirrors the
    /// per-row state SwiftUI InfiniteContentRow keeps locally
    /// (items / isLoadingMore / hasReachedEnd / totalSize).
    private struct PaginationState {
        var loadedItems: [MediaItem]       // initial items + everything paginated in
        /// itemIDs that arrived via loadMoreIfNeeded — the ONLY items allowed
        /// to survive a head refresh as tail extras. Without this, any item
        /// that fell out of the refreshed hub head (finished, dismissed,
        /// rolled to the next episode) was indistinguishable from a
        /// paginated-in extra and got re-appended at the tail forever —
        /// the "old episodes at the far right of Continue Watching" bug.
        var paginatedKeys: Set<String> = []
        var totalSize: Int?
        var isLoadingMore: Bool
        var hasReachedEnd: Bool
    }
    private var paginationStates: [HomeSectionID: PaginationState] = [:]

    /// Continue Watching removals applied optimistically: these itemIDs are
    /// hidden from CW rows the moment the user picks Remove, while the
    /// server PUT + CW refetch run behind. Each ID is cleared on reconcile —
    /// after a confirmed refetch (data no longer contains it) or on failure
    /// (tile reappears; server truth wins) — so a later rewatch can re-enter
    /// the row. Render-only: never persisted, never fed back into the store.
    private var pendingCWRemovals: Set<String> = []
    /// One-shot view-side companion to `pendingCWRemovals`: the shelf slot
    /// (section, tile index) of the removal that triggered the next snapshot
    /// apply, so the visible row can animate a batch DELETE at that index
    /// instead of crossfade-reloading. Consumed by `updateVisibleShelfRows`.
    private var pendingShelfRemoval: (sectionID: HomeSectionID, index: Int)?
    private let paginationPageSize = 24

    // MARK: Library-mode grid state
    //
    // Pagination pattern ported from MediaLibraryViewController: an
    // `isLoadingGridPage` flag prevents concurrent page fetches, and a
    // monotonically-increasing `gridGeneration` token is bumped on every
    // grid reset (sort change) so an in-flight page Task discards its
    // results if the generation advanced before the await returned —
    // a stale page can never interleave into a fresh sort load.

    /// Loaded grid items (first page + everything paginated in), deduped
    /// by ratingKey.
    private var gridItems: [PlexMetadata] = []
    /// Authoritative library item count from Plex (drives the sort-header
    /// count and the pagination end condition).
    private var totalGridCount = 0
    /// Active sort for the grid. Initialized from LibrarySettingsManager in
    /// `init` for library mode; never read in home mode.
    private var gridSort: LibrarySortOption
    /// Guards `loadGridNextPage` against concurrent fires (willDisplay can
    /// trigger many times while a page is in flight).
    private var isLoadingGridPage = false
    /// Generation token — see the MARK comment above.
    private var gridGeneration = 0
    /// Page size matching the SwiftUI PlexLibraryView (`pageSize = 60`).
    private let gridPageSize = 60
    /// The single item id of the sort-header section.
    private static let sortHeaderItemID = HomeItemID(sectionID: .sortHeader, itemID: "sort-header")

    /// Recommendations state (latched local copy — service caches itself).
    private var recommendations: [PlexMetadata] = []
    private var isLoadingRecommendations = false
    private var recommendationsError: String?

    /// Hero gate for the current mode: `showHomeHero` AppStorage on the home,
    /// `showLibraryHero` on a library page (both mirror the SwiftUI toggles).
    /// Kept under the original name so every existing call site stays as-is.
    /// The library hero defaults ON when the key has never been set (matches
    /// SettingsView's `@AppStorage("showLibraryHero") = true` default); an
    /// explicit user OFF is respected.
    /// Empty-state copy for the current surface. Discover is fed by TMDB, so
    /// telling the user their Plex library looks empty is simply wrong there.
    private var emptyStateMessage: String {
        switch mode {
        case .discover:
            return "Recommendations aren't available right now."
        case .home, .library, .search:
            return "Your Plex library appears to be empty."
        }
    }

    private var showHomeHero: Bool {
        switch mode {
        case .home:
            return UserDefaults.standard.bool(forKey: "showHomeHero")
        case .library:
            return (UserDefaults.standard.object(forKey: "showLibraryHero") as? Bool) ?? true
        case .discover:
            return true  // Discover always leads with the hero carousel
        case .search:
            return false  // Search has no hero — keyboard + results only
        }
    }
    /// `enablePersonalizedRecommendations` AppStorage gate.
    private var enablePersonalizedRecommendations: Bool {
        UserDefaults.standard.bool(forKey: "enablePersonalizedRecommendations")
    }
    /// `promptResumeOrRestart` AppStorage gate.
    private var promptResumeOrRestart: Bool {
        UserDefaults.standard.bool(forKey: "promptResumeOrRestart")
    }

    // MARK: - Lifecycle

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Diagnostic only — the embedded orthogonal scrollers are NOT
        // configured or driven in any way (the layout owns them and reverts
        // external writes; the shelf margin lives in the section contentInsets
        // instead, see makeHubSectionLayout).
        for subview in collectionView.subviews {
            if let scroller = subview as? UIScrollView {
                observeScrollerSettleIfNeeded(scroller)
            }
        }
    }

    /// Diagnostic: log where each hub row's embedded scroller settles after a
    /// focus-driven scroll, so landing offsets can be checked against the
    /// shelf grid (multiples of tile+gap) without guessing from screenshots.
    private var scrollerSettleObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var scrollerSettleWork: [ObjectIdentifier: DispatchWorkItem] = [:]

    private func observeScrollerSettleIfNeeded(_ scroller: UIScrollView) {
        let id = ObjectIdentifier(scroller)
        guard scrollerSettleObservations[id] == nil else { return }
        scrollerSettleObservations[id] = scroller.observe(\.contentOffset, options: [.new]) { [weak self, weak scroller] _, _ in
            guard let self, let scroller else { return }
            let workID = ObjectIdentifier(scroller)
            self.scrollerSettleWork[workID]?.cancel()
            let work = DispatchWorkItem { [weak scroller] in
                guard let scroller else { return }
                let x = scroller.contentOffset.x
                let inset = scroller.adjustedContentInset
                NSLog("[ShelfSettle] x=%.1f insetL=%.1f insetR=%.1f y=%.0f", x, inset.left, inset.right, scroller.frame.minY)
            }
            self.scrollerSettleWork[workID] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if case .library = mode { StartupTimer.mark("PlexHomeVC.viewDidLoad (library)") }
        else { StartupTimer.mark("PlexHomeVC.viewDidLoad (home)") }
        // No opaque base behind `backgroundBlurView`: let the blur sample
        // whatever sits behind the home view (the SwiftUI shell / system)
        // rather than a flat colour. Search keeps the same clear root: with
        // its three background layers (ambient/blur/backdrop) kept out of the
        // hierarchy, a clear background lets the uniform system search
        // surround show through seamlessly — an opaque fill there instead reads
        // as a darker panel inset from the surround.
        view.backgroundColor = .clear

        Perf.event(.homeFirstRender, message: "viewDidLoad start")

        configureBackdrop()
        configureCollectionView()
        configureStateOverlays()
        configureDataSource()
        observeDataStore()
        observeWatchlist()
        observeUserDefaults()
        observeAuth()

        // Prime the launch-pending flag BEFORE hero selection: on a cold
        // launch it keeps the hero slot out of the loading state until the
        // disk cache has had its chance to seed it (selectHeroItemsIfNeeded
        // reads the flag).
        primeInitialHomeLoadingStateIfNeeded()
        // Seed hero from cache before the initial snapshot so the first
        // frame already contains it on warm launches. Data-store refresh
        // below + the TMDB upgrade task will update the carousel later.
        selectHeroItemsIfNeeded()

        applySnapshot(animated: false)
        updateHomeState()

        switch mode {
        case .home:
            // LAUNCH-CRITICAL: only the main hub cache paint. Everything else
            // (per-library hubs, watchlist, recommendations) is deferred so it
            // does not contend with the cache decode + first paint + cell
            // realization. On a core-limited Apple TV, that concurrent storm
            // was preempting the cache decode and inflating it ~10x.
            Task { @MainActor in
                await Perf.interval(.homeDataFetch) {
                    await dataStore.loadHubsIfNeeded()   // cache paint, fast
                }
                isInitialHomeLoadPending = false
                selectHeroItemsIfNeeded()
                updateHomeState()
            }
            // Deferred secondary content — fills in a beat after the home is up.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await dataStore.loadLibraryHubsIfNeeded(forceRefresh: true)
                selectHeroItemsIfNeeded()
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                await watchlistService.fetchWatchlist()
            }

            if enablePersonalizedRecommendations {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await refreshRecommendations(force: false)
                }
            }
        case .library(let key, _):
            // Library page: just this library's hubs. No watchlist row, no
            // personalized recommendations, no cross-library fetches.
            // LAUNCH-CRITICAL: paint rows from the flat MediaItem cache first
            // (Stage 3), then refresh hubs from the network. The grid's first
            // page loads in parallel with the hubs.
            Task { @MainActor in
                if await dataStore.paintLibraryItemsFromCacheIfNeeded(forKey: key) {
                    applySnapshot(animated: false)
                    selectHeroItemsIfNeeded()
                    updateHomeState()
                }
                await refreshThisLibraryHubs()
            }
            Task { @MainActor in
                await loadGridFirstPage()
            }
        case .discover:
            // Discover page: the 8 TMDB curated sections + For You + hero,
            // all fetched by the same view model the SwiftUI page used.
            Task { @MainActor in
                isLoadingDiscover = true
                updateHomeState()
                await discoverModel.load()
                isLoadingDiscover = false
                applySnapshot(animated: false)
                updateHomeState()
                refreshDiscoverHeroState()
                updateBackdropForCurrentHeroItem()
            }
            // The sidebar builds LibraryGUIDIndex in the background; on cold
            // launch our load() races it and the in-library set comes up
            // empty (every hero/tile shows Watchlist instead of Play).
            // Re-derive matches whenever the index repopulates.
            NotificationCenter.default.publisher(for: .libraryGUIDIndexDidUpdate)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.discoverModel.refreshLibraryMatches()
                        self.refreshDiscoverHeroState()
                    }
                }
                .store(in: &dataStoreObservers)
        case .search:
            // Search page: no upfront content — results arrive per query.
            // Libraries are needed for the visible-library result filter.
            Task { @MainActor in
                await dataStore.loadLibrariesIfNeeded()
            }
        }
    }

    private func primeInitialHomeLoadingStateIfNeeded() {
        guard case .home = mode,
              authManager.hasCredentials,
              dataStore.homeItems.isEmpty,
              dataStore.hubs.isEmpty,
              dataStore.hubsError == nil,
              !dataStore.isHomeContentReady else { return }
        isInitialHomeLoadPending = true
    }

    // MARK: - Discover mode

    /// Data source for `.discover` mode — the same view model the SwiftUI
    /// DiscoverView used (TMDB curated sections, For You, hero picks,
    /// in-library TMDB id set). Only touched in discover mode.
    private let discoverModel = DiscoverViewModel()
    private var isLoadingDiscover = false
    /// Original TMDB items per discover section, aligned index-for-index with
    /// the section's mapped MediaItems. Context menus and the hero need the
    /// TMDB originals (watchlist guid construction, library matching).
    private var discoverListItems: [HomeSectionID: [TMDBListItem]] = [:]

    private func computeDiscoverSections() -> [HomeSectionData] {
        var sections: [HomeSectionData] = []
        discoverListItems = [:]

        let heroTMDB = discoverModel.heroItems
        if !heroTMDB.isEmpty {
            sections.append(.discoverHero(items: heroTMDB.map { TMDBMediaMapper.item($0) }))
            discoverListItems[.hero] = heroTMDB
        }

        for tmdbSection in TMDBDiscoverSection.allCases {
            let tmdbItems = discoverModel.items(for: tmdbSection)
            guard !tmdbItems.isEmpty else { continue }
            let id = HomeSectionID(raw: "discover.\(tmdbSection.rawValue)")
            sections.append(.discoverList(
                id: id,
                title: tmdbSection.title,
                items: tmdbItems.map { TMDBMediaMapper.item($0) }
            ))
            discoverListItems[id] = tmdbItems
        }

        if !discoverModel.forYou.isEmpty {
            let id = HomeSectionID(raw: "discover.forYou")
            sections.append(.discoverList(
                id: id,
                title: "For You",
                items: discoverModel.forYou.map { TMDBMediaMapper.item($0) }
            ))
            discoverListItems[id] = discoverModel.forYou
        }

        return sections
    }

    // MARK: - Search mode

    // Straight port of PlexSearchView's search machinery: 350ms debounce,
    // token-based race protection, min 2-char query, visible-library result
    // filtering, and recent searches persisted in UserDefaults under the SAME
    // key the SwiftUI page used (recents carry over).
    private var searchQuery = ""
    private var searchResults: [PlexMetadata] = []
    private var isSearchLoading = false
    private var searchError: String?
    private var lastSubmittedQuery = ""
    private var searchTask: Task<Void, Never>?
    private var searchToken = 0
    /// Original PlexMetadata per search-grid section, aligned index-for-index
    /// with the section's mapped MediaItems — music routing needs the original
    /// (artist/album → music detail, track → play now).
    private var searchGroupMetas: [HomeSectionID: [PlexMetadata]] = [:]

    private static let searchMinQueryLength = 2
    private static let searchDebounceNs: UInt64 = 350_000_000
    private static let maxRecentSearches = 10
    private static let recentSearchesKey = "recentSearches"

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAwaitingSearchResults: Bool {
        guard trimmedSearchQuery.count >= Self.searchMinQueryLength else { return false }
        return isSearchLoading || lastSubmittedQuery != trimmedSearchQuery
    }

    private var recentSearches: [String] {
        let data = UserDefaults.standard.data(forKey: Self.recentSearchesKey) ?? Data()
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func saveRecentSearch(_ query: String) {
        var searches = recentSearches
        searches.removeAll { $0.lowercased() == query.lowercased() }
        searches.insert(query, at: 0)
        if searches.count > Self.maxRecentSearches {
            searches = Array(searches.prefix(Self.maxRecentSearches))
        }
        UserDefaults.standard.set((try? JSONEncoder().encode(searches)) ?? Data(), forKey: Self.recentSearchesKey)
    }

    private func clearRecentSearches() {
        UserDefaults.standard.set(Data(), forKey: Self.recentSearchesKey)
        applySnapshot(animated: false)
        reconfigureVisibleSearchCells()
    }

    /// Query updates from `SearchContainerViewController`. Debounced search,
    /// identical to PlexSearchView.scheduleSearch.
    func updateSearchQuery(_ rawQuery: String) {
        guard case .search = mode, rawQuery != searchQuery else { return }
        searchQuery = rawQuery
        let trimmed = trimmedSearchQuery
        // A new query shows its results from the top. Without this the page
        // keeps whatever offset the last visit left, so the first row is
        // scrolled out of sight above the viewport and a Down press off the
        // keyboard lands on the SECOND row — the engine picking the first row
        // that is actually visible.
        scrollToContentTop()

        guard trimmed.count >= Self.searchMinQueryLength else {
            searchTask?.cancel()
            searchToken += 1
            isSearchLoading = false
            searchError = nil
            searchResults = []
            lastSubmittedQuery = ""
            applySnapshot(animated: false)
            return
        }

        searchTask?.cancel()
        searchToken += 1
        let currentToken = searchToken
        // Re-render now so the inline "Searching" state appears while debouncing.
        applySnapshot(animated: false)
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNs)
            if Task.isCancelled { return }
            await self?.performSearch(query: trimmed, token: currentToken)
        }
    }

    /// Immediate search on keyboard submit (skips the debounce).
    func submitSearch() {
        guard case .search = mode else { return }
        let trimmed = trimmedSearchQuery
        guard trimmed.count >= Self.searchMinQueryLength else { return }
        if trimmed == lastSubmittedQuery && !searchResults.isEmpty { return }

        searchTask?.cancel()
        searchToken += 1
        let currentToken = searchToken
        Task { await performSearch(query: trimmed, token: currentToken) }
    }

    private func performSearch(query: String, token: Int) async {
        guard let serverURL = authManager.selectedServerURL,
              let authToken = authManager.selectedServerToken else { return }

        isSearchLoading = true
        searchError = nil

        do {
            let items = try await PlexNetworkManager.shared.search(
                serverURL: serverURL,
                authToken: authToken,
                query: query,
                start: 0,
                size: 80
            )
            guard token == searchToken else { return }
            searchResults = items
            isSearchLoading = false
            searchError = nil
            lastSubmittedQuery = query
            if !items.isEmpty { saveRecentSearch(query) }
        } catch {
            guard token == searchToken else { return }
            searchResults = []
            isSearchLoading = false
            searchError = error.localizedDescription
            lastSubmittedQuery = query
        }
        applySnapshot(animated: false)
        reconfigureVisibleSearchCells()
    }

    /// Dedupe + restrict to known types + pinned/visible libraries.
    /// Port of PlexSearchView.filteredResults.
    private var filteredSearchResults: [PlexMetadata] {
        // Same section-attribution predicate the Home hero and Continue
        // Watching use — search is cross-library for the same reason (the
        // server has no idea which libraries the client hides). Reusing it also
        // normalizes the two spellings of a section id: Plex writes
        // `librarySectionKey` as `/library/sections/3` while `PlexLibrary.key`
        // is the bare `3`, so the old raw-string compare could drop every
        // attributed result as soon as any library was hidden.
        let visibleKeys = PlexLibraryVisibilityFilter.normalizedKeySet(
            dataStore.visibleLibraries.map { $0.key }
        )
        let types = Set(["movie", "show", "season", "episode", "artist", "album", "track"])
        var seen = Set<String>()

        return searchResults.filter { item in
            guard let type = item.type, types.contains(type) else { return false }
            guard let key = item.ratingKey else { return false }
            guard !seen.contains(key) else { return false }
            seen.insert(key)

            return PlexLibraryVisibilityFilter.isVisible(item, in: visibleKeys)
        }
    }

    private func computeSearchSections() -> [HomeSectionData] {
        searchGroupMetas = [:]

        if trimmedSearchQuery.count < Self.searchMinQueryLength {
            return [.searchPrompt()]
        }
        if isAwaitingSearchResults || searchError != nil {
            return [.searchState()]
        }

        let filtered = filteredSearchResults
        guard !filtered.isEmpty else { return [.searchState()] }

        // Same grouping as PlexSearchView.groupedResults.
        let groups: [(key: String, title: String, metas: [PlexMetadata])] = [
            ("titles", "Movies & TV", filtered.filter { $0.type == "movie" || $0.type == "show" }),
            ("episodes", "Episodes & Seasons", filtered.filter { $0.type == "episode" || $0.type == "season" }),
            ("music", "Music", filtered.filter { $0.type == "artist" || $0.type == "album" || $0.type == "track" })
        ]

        var sections: [HomeSectionData] = []
        for group in groups where !group.metas.isEmpty {
            let id = HomeSectionID.searchGroup(group.key)
            sections.append(.searchGrid(id: id, title: group.title, items: mapToMediaItems(group.metas)))
            searchGroupMetas[id] = group.metas
        }
        return sections
    }

    /// The prompt/state cells render controller state that isn't part of the
    /// diffable identity (recents list, searching vs error vs no-results), so
    /// a snapshot apply alone won't refresh an already-visible one.
    private func reconfigureVisibleSearchCells() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard indexPath.section < sectionsSnapshot.count else { continue }
            let section = sectionsSnapshot[indexPath.section]
            switch section.kind {
            case .searchPrompt:
                (collectionView.cellForItem(at: indexPath) as? SearchPromptCell)?
                    .configure(recentSearches: recentSearches)
            case .searchState:
                (collectionView.cellForItem(at: indexPath) as? SearchStateCell)?
                    .configure(state: currentSearchState)
            default:
                continue
            }
        }
    }

    private var currentSearchState: SearchStateCell.State {
        if let searchError { return .error(message: searchError) }
        if isAwaitingSearchResults { return .searching }
        return .noResults
    }

    /// Tap routing for search results: music keeps the SwiftUI page's routing
    /// (artist/album → music detail push, track → play now); everything else
    /// opens the preview carousel over the tapped group — the same experience
    /// as tapping a library grid tile.
    private func handleSearchTap(section: HomeSectionData, indexPath: IndexPath) {
        let metas = searchGroupMetas[section.id] ?? []
        if indexPath.item < metas.count {
            let meta = metas[indexPath.item]
            switch meta.type {
            case "artist", "album":
                onSelectMusic?(meta)
                return
            case "track":
                playMusicTrack(meta)
                return
            default:
                break
            }
        }
        presentPreview(forSection: section, indexPath: indexPath)
    }

    /// Library-mode data load: fetch this library's hubs (its own Continue
    /// Watching, Recently Added, genre rows) into `dataStore.libraryHubs` —
    /// the same store slot + network call the SwiftUI PlexLibraryView used.
    private func refreshThisLibraryHubs() async {
        guard case .library(let key, _) = mode,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        isLoadingLibraryHubs = (dataStore.libraryHubs[key] == nil)
        updateHomeState()
        do {
            let hubs = try await PlexNetworkManager.shared.getLibraryHubs(
                serverURL: serverURL, authToken: token, sectionId: key
            )
            dataStore.libraryHubs[key] = hubs
            // Project to the MediaItem rail the library page now renders from
            // (Stage 2 reads dataStore.libraryItemsByKey[key]). This also bumps
            // libraryHubsVersion + writes the flat library cache for next launch.
            dataStore.projectLibraryItems(forKey: key)
            libraryHubsError = nil
        } catch {
            // Keep stale content if we have any; only surface the error when
            // there's nothing to show (mirrors the home's hubsError handling).
            if (dataStore.libraryHubs[key] ?? []).isEmpty {
                libraryHubsError = error.localizedDescription
            }
        }
        isLoadingLibraryHubs = false
        applySnapshot(animated: false)
        selectHeroItemsIfNeeded()
        updateHomeState()
    }

    // MARK: - Library grid data

    /// Fetches the first page of grid items for the library (library mode
    /// only). Uses the proven SwiftUI PlexLibraryView data path:
    /// `getLibraryItemsWithTotal` with the LibrarySortOption's Plex sort
    /// parameter. Captures the generation token before awaiting so a sort
    /// change mid-flight discards the result.
    @MainActor
    private func loadGridFirstPage() async {
        guard case .library(let key, _) = mode,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let gen = gridGeneration
        do {
            let result = try await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: key,
                start: 0,
                size: gridPageSize,
                sort: gridSort.apiParameter
            )
            guard gen == gridGeneration, !Task.isCancelled else { return }
            // Dedupe by ratingKey — Plex can repeat keys within a page.
            var seen = Set<String>()
            gridItems = result.items.filter { item in
                guard let rk = item.ratingKey else { return false }
                return seen.insert(rk).inserted
            }
            totalGridCount = result.totalSize ?? gridItems.count
        } catch {
            // Leave the grid empty; hub rows still render. updateHomeState
            // surfaces a library-level error only when there are no hubs
            // either.
            guard gen == gridGeneration, !Task.isCancelled else { return }
        }
        applySnapshot(animated: false)
        refreshSortHeaderCount()
        updateHomeState()
    }

    /// Loads the next grid page and appends (deduped by ratingKey). Guarded
    /// by `isLoadingGridPage` so concurrent willDisplay triggers are no-ops.
    /// Stale results (generation advanced mid-flight) are discarded; the
    /// stale task clears the flag itself on every exit path, so exactly one
    /// task can hold it at a time (same pattern as MediaLibraryViewController).
    private func loadGridNextPage() {
        guard case .library(let key, _) = mode,
              !isLoadingGridPage,
              gridItems.count < totalGridCount,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        isLoadingGridPage = true
        let gen = gridGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                    serverURL: serverURL,
                    authToken: token,
                    sectionId: key,
                    start: self.gridItems.count,
                    size: self.gridPageSize,
                    sort: self.gridSort.apiParameter
                )
                guard gen == self.gridGeneration else {
                    self.isLoadingGridPage = false
                    return
                }
                let existing = Set(self.gridItems.compactMap { $0.ratingKey })
                let newItems = result.items.filter { item in
                    guard let rk = item.ratingKey else { return false }
                    return !existing.contains(rk)
                }
                if let total = result.totalSize {
                    self.totalGridCount = total
                }
                if newItems.isEmpty {
                    // No forward progress (empty or all-duplicate page):
                    // clamp the total so willDisplay stops re-firing.
                    self.totalGridCount = self.gridItems.count
                } else {
                    self.gridItems.append(contentsOf: newItems)
                }
                self.isLoadingGridPage = false
                self.applySnapshot(animated: false)
                self.refreshSortHeaderCount()
            } catch {
                // Don't mark end-of-list on error — the user can retry by
                // continuing to scroll (matches hub pagination behavior).
                self.isLoadingGridPage = false
            }
        }
    }

    /// Reconfigures the sort-header cell so its count + sort name reflect
    /// the latest state. Its item identifier never changes across snapshots,
    /// so `applySnapshot` alone won't re-vend the cell. Guards on
    /// `sectionIdentifiers.contains` — NOT `itemIdentifiers(inSection:)`,
    /// which throws when the section is absent.
    private func refreshSortHeaderCount() {
        var snap = dataSource.snapshot()
        guard snap.sectionIdentifiers.contains(.sortHeader) else { return }
        snap.reconfigureItems([Self.sortHeaderItemID])
        dataSource.apply(snap, animatingDifferences: false)
    }

    // MARK: - Library grid sort

    /// The Plex library type ("movie", "show", ...) for the current library,
    /// used to pick the relevant sort options. Mirrors PlexLibraryView's
    /// `currentLibraryType`.
    private var currentLibraryType: String? {
        guard case .library(let key, _) = mode else { return nil }
        return dataStore.libraries.first(where: { $0.key == key })?.type
    }

    /// Action-sheet sort picker. One action per LibrarySortOption relevant
    /// to this library's type (PlexLibraryView used the same
    /// `options(for:)` source); a checkmark prefix marks the active sort
    /// (tvOS UIAlertAction has no native checkmark accessory).
    private func presentSortPicker() {
        guard case .library = mode else { return }
        let sheet = UIAlertController(title: "Sort By", message: nil, preferredStyle: .actionSheet)
        for option in LibrarySortOption.options(for: currentLibraryType) {
            let title = option == gridSort ? "\u{2713} \(option.displayName)" : option.displayName
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.applySort(option)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    /// Persists the new sort, resets the grid (bumping the generation token
    /// so any in-flight page discards itself), and reloads the first page.
    /// The snapshot + sort-header reconfigure run immediately so the sort
    /// name flips on selection rather than after the fetch resolves.
    private func applySort(_ option: LibrarySortOption) {
        guard case .library(let key, _) = mode, option != gridSort else { return }
        gridSort = option
        LibrarySettingsManager.shared.setSortOption(option, for: key)

        gridGeneration += 1
        gridItems = []
        totalGridCount = 0

        applySnapshot(animated: false)
        refreshSortHeaderCount()

        Task { @MainActor in
            await loadGridFirstPage()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasMarkedFirstFrame {
            hasMarkedFirstFrame = true
            Perf.event(.homeFirstFrameOnScreen, message: "viewDidAppear")

            if PerfAutoScroll.enabled {
                runAutoScroll()
            }
        }
        applyPendingPreviewRestoreIfNeeded()
        nudgeInitialHeroFocusIfNeeded()
        refreshOnReappearIfNeeded()
        if let window = view.window {
            MenuPressInterceptor.install(in: window)
            MenuPressInterceptor.register(self)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop taking Menu presses the moment the page leaves the screen, and
        // keep the handler list from growing by one per page visited. A fresh
        // appearance re-registers.
        MenuPressInterceptor.resign(self)
    }

    /// Nonblocking stale-while-revalidate whenever the home surface comes back
    /// on screen (tab switch back, player/preview dismissal): re-check the
    /// small Continue Watching hub in the background. The data store throttles
    /// this against its own timers and the post-playback burst, so repeated
    /// appearances are free. Skipped on the FIRST appearance — the launch path
    /// already fetches, and an extra request would contend the first paint.
    private var hasRunFirstAppearance = false
    private func refreshOnReappearIfNeeded() {
        guard case .home = mode else { return }
        guard hasRunFirstAppearance else {
            hasRunFirstAppearance = true
            return
        }
        Task { await dataStore.refreshContinueWatchingIfStale() }
    }

    // MARK: - Stale focus appearance (focus returning into the collection)

    /// When focus leaves the entire collection (into a presented carousel, the
    /// sidebar, etc.) the cell that held focus never receives a per-cell
    /// unfocus event, so its TVPosterView can strand in the enlarged focused
    /// appearance (PosterCell.resetStaleFocusAppearance handles the in-place
    /// unfocus case, but not this one). When focus returns INTO the collection,
    /// clear the stale appearance on every visible poster except the one focus
    /// just landed on. Appearance-only — does not touch focusability.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let prevInside = context.previouslyFocusedView?.isDescendant(of: collectionView) == true
        let nextInside = context.nextFocusedView?.isDescendant(of: collectionView) == true
        guard !prevInside, nextInside else { return }
        let landed = context.nextFocusedView
        for case let row as ShelfRowCell in collectionView.visibleCells {
            let landedIndex = row.rowCollectionView.visibleCells.first {
                landed === $0 || landed?.isDescendant(of: $0) == true
            }.flatMap { row.rowCollectionView.indexPath(for: $0)?.item }
            row.resetVisibleFocusAppearance(except: landedIndex)
        }
    }

    // MARK: - Initial focus (hero Play)

    /// Launch focus must land on the hero's Play button, not on whatever the
    /// engine's default pick finds first (on cold launch that was an
    /// off-screen Continue Watching tile — focus existed but nothing visibly
    /// focused, and Down skipped a row). Initial focus is asserted explicitly:
    /// while this flag is set, preferredFocusEnvironments routes to the hero
    /// cell (whose overlay chain + the secondary-button gate land on Play).
    /// Cleared the moment the hero receives focus or the user makes any
    /// directional move, so focus is never yanked mid-navigation.
    private var needsInitialHeroFocus = true

    private var heroSectionIndex: Int? {
        sectionsSnapshot.firstIndex(where: { $0.kind == .hero })
    }

    /// The section a staged Menu back returns to. Every hero-bearing mode
    /// (home, library, discover) tops out at the hero; Search has no hero, so
    /// its first section is the top.
    private var topSectionIndex: Int {
        heroSectionIndex ?? 0
    }

    /// Set while a staged Menu back is pulling focus to the top section. Only
    /// used by modes with no hero — hero modes reuse `needsInitialHeroFocus`
    /// so focus lands on Play exactly as it does at launch.
    private var wantsTopFocus = false

    /// Set by `focusRowAbove()` for exactly one focus update: the section whose
    /// first cell should take focus. Cleared as soon as it is read.
    private var pendingRowFocusSection: Int?

    /// Last value posted on `.contentFocusBelowTopChanged`, so the SwiftUI
    /// shell only hears about crossings of the top-row boundary, not every
    /// focus move.
    private var focusBelowTop = false

    private func postFocusBelowTop(_ below: Bool) {
        guard below != focusBelowTop else { return }
        focusBelowTop = below
        homeUIKitLog.log("pill experiment: posting belowTop=\(below)")
        NotificationCenter.default.post(name: .contentFocusBelowTopChanged, object: below)
    }

    /// Ask the engine to re-resolve focus while initial-hero routing is
    /// active. Called from viewDidAppear AND after snapshot applies — on cold
    /// launch the hero cell doesn't exist yet when the view first appears.
    private func nudgeInitialHeroFocusIfNeeded() {
        guard needsInitialHeroFocus,
              let heroIndex = heroSectionIndex,
              collectionView.cellForItem(at: IndexPath(item: 0, section: heroIndex)) != nil
        else { return }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func runAutoScroll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let id = Perf.begin(.homeScroll, message: "auto-scroll vertical")
            self.collectionView.setContentOffset(
                CGPoint(x: 0, y: max(0, self.collectionView.contentSize.height - self.collectionView.bounds.height)),
                animated: true
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Perf.end(.homeScroll, id: id)
                Perf.event(.homeScroll, message: "auto-scroll done")
            }
        }
    }

    // MARK: - Backdrop

    private func configureBackdrop() {
        // The three background layers, back to front: the ambient artwork wash,
        // the frosted material that diffuses it, and the hero art. All are
        // allocated up front so references elsewhere stay valid even when the
        // surface doesn't use them.
        ambientView = AmbientBackdropView()
        ambientView.translatesAutoresizingMaskIntoConstraints = false
        backgroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        backgroundBlurView.translatesAutoresizingMaskIntoConstraints = false
        backgroundBlurView.isUserInteractionEnabled = false
        backdropView = HeroBackdropView()
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        // Gate the startup splash on the hero image: it reports when the first
        // backdrop is on screen so the splash holds until then (no late pop-in).
        backdropView.onFirstImageLoaded = { [weak self] in
            self?.markHeroReady()
        }

        // Search has NO ambient wash, frosted base, or hero — it renders on a
        // flat opaque surface inside the system search container. Keep
        // all three background layers OUT of the hierarchy entirely (they stay
        // allocated so the rest of the code's references are valid, just never
        // parented), so none can paint an image into the search surface.
        if case .search = mode { return }

        // Backmost: the ambient wash — a single artwork image the frosted
        // material (next layer) diffuses into an Apple TV -style color field.
        // Latched once per screen by updateAmbientIfNeeded().
        view.addSubview(ambientView)
        NSLayoutConstraint.activate([
            ambientView.topAnchor.constraint(equalTo: view.topAnchor),
            ambientView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ambientView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ambientView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Frost in front of the ambient: a standard tvOS material that adapts
        // to light/dark and diffuses the wash. The hero art (added next, in
        // front) bleeds full-screen at the top and translates up on scroll;
        // past it this surface shows instead of black. Static and
        // non-interactive. Visible even when the hero is off.
        view.addSubview(backgroundBlurView)
        NSLayoutConstraint.activate([
            backgroundBlurView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundBlurView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backgroundBlurView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundBlurView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        view.addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        backdropView.isHidden = !showHomeHero
    }

    /// SwiftUI: `.padding(.top, heroActive ? 0 : 48)`. When hero is off we
    /// give the first row some breathing room from the top edge. Also
    /// reserves space below the connection banner when it's visible
    /// (mirrors SwiftUI's banner positioning above the content).
    private func updateContentTopInset() {
        // Search needs no extra top inset: `UISearchContainerViewController`
        // already sizes the results view to the area BELOW the keyboard, so
        // nothing scrolls under the chrome and content starts where the view
        // starts. (Measured: results view is [0,207 1920x873] on 1080p.)
        let baseTop: CGFloat = showHomeHero ? 0 : 48
        let topInset = baseTop + connectionBannerTopInset
        if collectionView.contentInset.top != topInset {
            collectionView.contentInset.top = topInset
        }
    }

    /// Single chokepoint for driving the hero backdrop. Forwards to the view,
    /// and when the URL is nil — no image will ever load — marks the hero ready
    /// immediately so the startup splash doesn't wait for an image that isn't
    /// coming. The non-nil case is reported by `onFirstImageLoaded` once the
    /// image is on screen.
    private func setHeroBackdrop(url: URL?) {
        backdropView.setBackdrop(url: url)
        // The ambient wash tracks the hero: same artwork, diffused by the
        // frosted material in front of it. Every hero page change lands here,
        // so this is the only place the wash needs driving.
        ambientView.setAmbient(url: url)
        if url == nil {
            markHeroReady()
        }
    }

    /// Mark the hero ready for the startup-splash gate. Idempotent (the splash
    /// only acts on the false→true edge) and deferred for the same reason as
    /// `isHomeContentReady`: this can run inside a SwiftUI view update.
    private func markHeroReady() {
        guard !dataStore.isHomeHeroReady else { return }
        Task { @MainActor in
            dataStore.isHomeHeroReady = true
        }
    }

    private func updateBackdropForCurrentHeroItem() {
        // Discover: hero items are MediaItem-backed (TMDB), not the Plex
        // heroItems array — without this branch the guard below NILs the
        // backdrop (the first slide rendered with no image until paged).
        if case .discover = mode {
            guard showHomeHero,
                  let section = sectionsSnapshot.first(where: { $0.kind == .hero }),
                  !section.heroMediaItems.isEmpty else {
                setHeroBackdrop(url: nil)
                return
            }
            let clamped = max(0, min(heroCurrentIndex, section.heroMediaItems.count - 1))
            updateBackdrop(forMediaItem: section.heroMediaItems[clamped])
            return
        }
        guard showHomeHero, !heroItems.isEmpty else {
            setHeroBackdrop(url: nil)
            return
        }
        let clamped = max(0, min(heroCurrentIndex, heroItems.count - 1))
        updateBackdrop(for: heroItems[clamped])
    }

    /// Set the hero backdrop from a specific item. Used by the overlay's
    /// `onIndexChanged` so the backdrop matches exactly the slide the overlay is
    /// showing. The index-based path above can disagree once `heroItems` is
    /// reordered by the TMDB upgrade after the overlay was configured.
    private func updateBackdrop(for item: PlexMetadata) {
        guard showHomeHero,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            setHeroBackdrop(url: nil)
            return
        }
        let request = item.heroBackdropRequest(serverURL: serverURL, authToken: token)
        let url = request.backdropURL ?? request.thumbnailURL
        setHeroBackdrop(url: url)
    }

    /// MediaItem-backed backdrop (Discover hero — TMDB CDN URLs are absolute,
    /// no server/token needed).
    private func updateBackdrop(forMediaItem item: MediaItem) {
        guard showHomeHero else {
            setHeroBackdrop(url: nil)
            return
        }
        setHeroBackdrop(url: item.artwork.backdrop ?? item.artwork.thumbnail ?? item.artwork.poster)
    }

    /// Discover hero Play (pill in `.play` mode — library-matched items only):
    /// opens the matched item's detail page, the same destination SwiftUI's
    /// `onPresentPlex` pushed. Unmatched items never reach here (their pill is
    /// the Watchlist toggle), but fall back to the carousel defensively.
    private func discoverHeroPlay(_ item: MediaItem) {
        guard let heroTMDB = discoverListItems[.hero],
              let index = heroIndex(of: item, in: heroTMDB)
        else { return }
        let tmdbItem = heroTMDB[index]
        Task { @MainActor in
            // Matched in the library → PLAY the file directly (same path as the
            // home hero's Play button), not the SwiftUI detail stack. Only the
            // library-matched hero shows a Play button at all; unmatched items
            // show Watchlist and never reach here.
            if let metadata = await discoverModel.libraryMatch(for: tmdbItem) {
                playItemDirectly(metadata)
            } else {
                discoverHeroInfo(item)
            }
        }
    }

    /// Sync the hero pill to the displayed item: Play when library-matched,
    /// Watchlist (with current on/off state) otherwise.
    private func applyDiscoverHeroState(for item: MediaItem, on cell: HeroOverlayCell?) {
        guard case .discover = mode, let cell else { return }
        let matched = item.tmdbID.map { discoverModel.inLibraryTMDBIds.contains($0) } ?? false
        let onWatchlist = item.tmdbID.map { watchlistService.contains(tmdbId: $0) } ?? false
        cell.overlay.setMediaItemPrimaryAction(matchedInLibrary: matched, isOnWatchlist: onWatchlist)
    }

    /// Toggle the Plex Discover watchlist for a TMDB-mapped MediaItem.
    /// Shared by the hero pill and tile context menus.
    private func toggleDiscoverWatchlist(for item: MediaItem, completion: (() -> Void)? = nil) {
        guard let tmdbID = item.tmdbID else { return }
        // Resolve the original TMDB item for full add-payload fields.
        let tmdbItem = discoverListItems.values.lazy
            .compactMap { $0.first(where: { $0.id == tmdbID }) }
            .first
        let guid = "tmdb://\(tmdbID)"
        Task { @MainActor in
            if watchlistService.contains(guid: guid) {
                await watchlistService.remove(guid: guid)
            } else if let tmdbItem {
                let watchType: PlexWatchlistItem.WatchlistType = tmdbItem.mediaType == .movie ? .movie : .show
                let yearInt: Int? = {
                    guard let raw = tmdbItem.releaseDate?.prefix(4), !raw.isEmpty else { return nil }
                    return Int(raw)
                }()
                let posterURL: URL? = tmdbItem.posterPath.flatMap {
                    URL(string: "https://image.tmdb.org/t/p/w500\($0)")
                }
                let entry = PlexWatchlistItem(
                    id: guid,
                    title: tmdbItem.title,
                    year: yearInt,
                    type: watchType,
                    posterURL: posterURL,
                    guids: [guid]
                )
                await watchlistService.add(guid: guid, item: entry)
            }
            completion?()
        }
    }

    /// Discover hero Info: the FULL expanded detail presented standalone —
    /// the same surface the carousel's Related drill-ins open (one item,
    /// already expanded, Menu dismisses, no collapse back to a carousel).
    /// Library-matched items are upgraded first so the chrome offers Play;
    /// metadata-only items get the Watchlist-primary chrome.
    private func discoverHeroInfo(_ item: MediaItem) {
        Task { @MainActor in
            let upgraded = await upgradeDiscoverItems([item]).first ?? item
            presentStandaloneExpandedDetail(upgraded)
        }
    }

    private func heroIndex(of item: MediaItem, in tmdbItems: [TMDBListItem]) -> Int? {
        guard let section = sectionsSnapshot.first(where: { $0.kind == .hero }) else { return nil }
        let index = section.heroMediaItems.firstIndex(where: { $0.ref.itemID == item.ref.itemID })
        guard let index, index < tmdbItems.count else { return nil }
        return index
    }

    /// Re-apply the hero pill state for the currently-displayed hero item
    /// (after library matches or watchlist state change).
    private func refreshDiscoverHeroState() {
        guard case .discover = mode,
              let heroIndex = heroSectionIndex,
              let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: heroIndex)) as? HeroOverlayCell,
              let section = sectionsSnapshot.first(where: { $0.kind == .hero }),
              heroCurrentIndex < section.heroMediaItems.count
        else { return }
        applyDiscoverHeroState(for: section.heroMediaItems[heroCurrentIndex], on: cell)
    }

    /// Swap library-matched TMDB items for their provider-backed MediaItems
    /// so the carousel / detail chrome offers Play + Watched for content the
    /// user owns; metadata-only items keep the Watchlist primary. Lookups are
    /// in-memory (LibraryGUIDIndex).
    private func upgradeDiscoverItems(_ items: [MediaItem]) async -> [MediaItem] {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return items }
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
        var out = items
        for (i, item) in items.enumerated() {
            guard let decoded = TMDBMediaMapper.decodeItemID(item.ref.itemID),
                  item.isMetadataOnly,
                  discoverModel.inLibraryTMDBIds.contains(decoded.tmdbId),
                  let match = await LibraryGUIDIndex.shared.lookup(tmdbId: decoded.tmdbId, type: decoded.type)
            else { continue }
            out[i] = PlexMediaMapper.item(match, providerID: providerID, serverURL: serverURL, authToken: token)
        }
        return out
    }

    // MARK: - State overlays (loading / empty / error / not-connected,
    //          connection banner, watchlist toast)

    private func configureStateOverlays() {
        // Connection-error banner. Sits at the top of the screen above
        // the collection view. Hidden by default.
        connectionBanner = ConnectionErrorBannerView()
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        connectionBanner.isHidden = true
        connectionBanner.onRetry = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.authManager.verifyAndFixConnection()
                if self.authManager.isConnected {
                    await self.dataStore.refreshHubs()
                }
            }
        }
        view.addSubview(connectionBanner)

        // Full-screen state placeholder.
        stateView = HomeStateView()
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        stateView.onAction = { [weak self] in
            guard let self else { return }
            Task { await self.dataStore.refreshHubs() }
        }
        view.addSubview(stateView)

        // Bottom-anchored toast for watchlist write reverts.
        watchlistToast = WatchlistToastView()
        view.addSubview(watchlistToast)

        NSLayoutConstraint.activate([
            connectionBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 100),
            connectionBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            connectionBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            watchlistToast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            watchlistToast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80)
        ])
    }

    /// Evaluate auth + data-store state and show the right overlay (or
    /// the home content). Precedence: credentials → data → loading →
    /// error → content.
    private func updateHomeState() {
        let hasCredentials = authManager.hasCredentials
        // Data presence/loading/error per mode: the home reads the global hub
        // store; a library page reads its own hub fetch state.
        let isLoadingHubs: Bool
        let hubsError: String?
        let hubsEmpty: Bool
        switch mode {
        case .home:
            isLoadingHubs = dataStore.isLoadingHubs || isInitialHomeLoadPending
            hubsError = dataStore.hubsError
            // The home renders from the MediaItem projection (Stage 3), so
            // "empty" must key STRICTLY off `homeItems`. Do NOT fall back to
            // `hubs`: on a cold sign-in the `/hubs` fetch populates `hubs`
            // before `homeItems` is projected (the projection also needs
            // Continue Watching + per-library hubs). A `hubs`-based fallback
            // would report not-empty while zero rows render, sending us down
            // the content path with an empty collection — a blank, unfocusable
            // Home that traps the focus engine. See
            // Docs/bugs/fresh-signin-blank-home.md.
            hubsEmpty = dataStore.homeItems.isEmpty
        case .library(let key, _):
            isLoadingHubs = isLoadingLibraryHubs
            hubsError = libraryHubsError
            // A hub-less library with grid content still shows content —
            // "empty" means no projected rows AND no hubs AND no grid items.
            hubsEmpty = (dataStore.libraryItemsByKey[key] ?? []).isEmpty
                && (dataStore.libraryHubs[key] ?? []).isEmpty
                && gridItems.isEmpty
        case .discover:
            isLoadingHubs = isLoadingDiscover
            // TMDBDiscoverService returns [] on failure rather than throwing, so
            // there is no error to surface here and a total failure presents as
            // empty. Giving Discover a real error state means teaching the
            // service to report one.
            hubsError = nil
            // Empty means NOTHING to show, not "no hero". The hero picks and the
            // curated lists come from INDEPENDENT TMDB fetches, so a hero-only
            // failure used to hide fully-populated rows behind the empty state.
            // That branch sets `collectionView.isHidden = true`, which left the
            // Refresh button as the only focusable thing on the page — nothing
            // below it, so Down did nothing.
            hubsEmpty = discoverModel.heroItems.isEmpty
                && discoverModel.forYou.isEmpty
                && TMDBDiscoverSection.allCases.allSatisfy { discoverModel.items(for: $0).isEmpty }
                && TMDBDiscoverSection.allCases.allSatisfy { discoverModel.items(for: $0).isEmpty }
        case .search:
            // Search renders its own inline prompt/searching/error states as
            // sections — the only full-screen state is notConnected.
            isLoadingHubs = false
            hubsError = nil
            hubsEmpty = false
        }

        // Precedence: notConnected → loading → error → empty → content.
        // Only the error/empty states carry a focusable button; track that so
        // preferredFocusEnvironments can steer the engine onto it (otherwise a
        // contentless Home can trap focus — see Docs/bugs/fresh-signin-blank-home.md).
        let isWaitingForHero = shouldWaitForHeroBeforeContent(hubsEmpty: hubsEmpty)
        stateViewHasFocusableAction = false
        if !hasCredentials {
            stateView.configure(kind: .notConnected)
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            connectionBanner.isHidden = true
        } else if (isLoadingHubs && hubsEmpty) || isWaitingForHero {
            stateView.configure(kind: .loading)
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            connectionBanner.isHidden = true
        } else if let error = hubsError, hubsEmpty {
            stateView.configure(kind: .error(message: error))
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            connectionBanner.isHidden = true
            stateViewHasFocusableAction = true
            setNeedsFocusUpdate()
        } else if hubsEmpty {
            stateView.configure(kind: .empty(message: emptyStateMessage))
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            connectionBanner.isHidden = true
            stateViewHasFocusableAction = true
            setNeedsFocusUpdate()
        } else {
            // Content path. Reveal the collection view + backdrop, then
            // decide whether to show the inline connection banner.
            let wasUnfocusable = collectionView.isHidden
            stateView.isHidden = true
            collectionView.isHidden = false
            // A hidden collection view is invisible to the focus engine, so
            // while this page was loading there was nothing on it to focus and
            // focus parked outside it. Un-hiding does not make the engine look
            // again — tell the shell to re-drive. The error and empty branches
            // above have their own `setNeedsFocusUpdate()`; only the content
            // path was silent, which is why Discover (the one surface that sits
            // in `.loading` long enough to matter) came up dead.
            if wasUnfocusable {
                NotificationCenter.default.post(name: .contentBecameFocusable, object: nil)
            }
            backdropView.isHidden = !showHomeHero
            let shouldShowBanner = !authManager.isConnected
            updateConnectionBanner(shouldShowBanner)
        }

        // Splash handoff: the launch splash (ContentView) dismisses on
        // dataStore.isHomeContentReady. The retired SwiftUI PlexHomeView was
        // the only thing that ever set it true — without this, every cold
        // launch since the UIKit cutover rode the splash's full 15s safety
        // timeout. Ready = any SETTLED state (content, empty, error): the
        // splash exists to cover the initial load, not to mask outcomes.
        if hasCredentials, !(isLoadingHubs && hubsEmpty), !isWaitingForHero, !dataStore.isHomeContentReady {
            // Deferred: updateHomeState can run inside viewDidLoad during a
            // SwiftUI view update (the bridge's makeUIViewController), and
            // publishing @Published state there logs "Publishing changes from
            // within view updates" / undefined behavior.
            Task { @MainActor in
                dataStore.isHomeContentReady = true
            }
        }

        // Hero half of the splash gate: only the content path with the hero
        // enabled has a backdrop image to wait for. In every other settled
        // state (notConnected / error / empty, or hero disabled) the backdrop
        // is hidden and no image will load — mark the hero ready now so the
        // splash dismisses on content alone instead of riding the cap/timeout.
        if hasCredentials, !(isLoadingHubs && hubsEmpty), !isWaitingForHero, backdropView.isHidden {
            markHeroReady()
        }
    }

    private func shouldWaitForHeroBeforeContent(hubsEmpty: Bool) -> Bool {
        guard case .home = mode,
              showHomeHero,
              !hubsEmpty,
              !dataStore.isHomeHeroReady else { return false }
        return true
    }

    private func updateConnectionBanner(_ shouldShow: Bool) {
        if shouldShow {
            connectionBanner.setMessage(authManager.connectionError)
        }
        if connectionBanner.isHidden != !shouldShow {
            connectionBanner.isHidden = !shouldShow
        }
        let bannerHeight: CGFloat = shouldShow ? 120 : 0
        if connectionBannerTopInset != bannerHeight {
            connectionBannerTopInset = bannerHeight
            updateContentTopInset()
        }
    }

    // MARK: - Layout

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            return self.layoutSection(at: sectionIndex, environment: environment)
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .never
        // SwiftUI: `.padding(.top, heroActive ? 0 : 48)` on the content
        // VStack. When the hero is off, the first row (Continue Watching)
        // gets 48pt of breathing room at the top of the scroll.
        updateContentTopInset()
        // NOT in search mode. The search page swaps its content wholesale
        // between the prompt/recents cell and grouped result grids, so the
        // remembered path routinely names a cell that no longer exists. When
        // the engine tries to enter the collection with an invalid remembered
        // path it resolves to nothing and produces NO focus update at all,
        // which is exactly why Down off the keyboard reached the results after
        // a search and did nothing on the empty page. Preview-dismiss focus
        // restore is a separate mechanism (`pendingPreviewRestore`).
        if case .search = mode {
            collectionView.remembersLastFocusedIndexPath = false
        } else {
            collectionView.remembersLastFocusedIndexPath = true
        }
        collectionView.clipsToBounds = false
        // Take over the vertical focus-scroll. Left enabled, the focus engine
        // runs its OWN scroll animator whenever focus moves between rows, and
        // that animator races the per-frame CADisplayLink driver in
        // `animateContentOffset`. Two clocks writing `contentOffset` on
        // different curves is what reads as the "moves, then slows, then moves
        // again" stutter. Disabling it stops the engine's focus-scroll; we
        // drive every vertical move ourselves from `didUpdateFocusIn`. The
        // orthogonal rows keep their own inner horizontal scroller, so Left/
        // Right within a row is unaffected. (Same pattern the detail view uses
        // in FocusScrollControlledCollectionView.)
        collectionView.isScrollEnabled = false

        // Select long-press on a grid tile → tile action menu. Our own
        // recognizer: the system context-menu path never engages on tvOS 26
        // (see TileMenuPopupViewController's header).
        collectionView.addGestureRecognizer(
            TileLongPress.makeRecognizer(target: self, action: #selector(handleGridLongPress(_:))))

        collectionView.register(HubHeaderView.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: HubHeaderView.reuseID)
        collectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        collectionView.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
        collectionView.register(ContinueWatchingCell.self, forCellWithReuseIdentifier: ContinueWatchingCell.reuseID)
        collectionView.register(HeroOverlayCell.self, forCellWithReuseIdentifier: HeroOverlayCell.reuseID)
        collectionView.register(HeroLoadingCell.self, forCellWithReuseIdentifier: HeroLoadingCell.reuseID)
        collectionView.register(WatchlistPosterCell.self, forCellWithReuseIdentifier: WatchlistPosterCell.reuseID)
        collectionView.register(PosterSkeletonCell.self, forCellWithReuseIdentifier: PosterSkeletonCell.reuseID)
        collectionView.register(RecommendationsStateCell.self, forCellWithReuseIdentifier: RecommendationsStateCell.reuseID)
        // Library-mode sort header (inert registration in home mode — the
        // .sortHeader section only ever exists in library snapshots).
        collectionView.register(MediaLibrarySortControl.self, forCellWithReuseIdentifier: MediaLibrarySortControl.reuseID)
        // Search-mode cells (inert registrations in other modes).
        collectionView.register(SearchPromptCell.self, forCellWithReuseIdentifier: SearchPromptCell.reuseID)
        collectionView.register(SearchStateCell.self, forCellWithReuseIdentifier: SearchStateCell.reuseID)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Leading-edge focus guide. See property doc for the why.
        leftEdgeFocusGuide = UIFocusGuide()
        view.addLayoutGuide(leftEdgeFocusGuide)
        NSLayoutConstraint.activate([
            leftEdgeFocusGuide.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            leftEdgeFocusGuide.widthAnchor.constraint(equalToConstant: 1),
            leftEdgeFocusGuide.topAnchor.constraint(equalTo: collectionView.topAnchor),
            leftEdgeFocusGuide.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor)
        ])
    }

    private func layoutSection(at sectionIndex: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        guard sectionIndex < sectionsSnapshot.count else { return nil }
        let section = sectionsSnapshot[sectionIndex]
        switch section.kind {
        case .hero:
            return makeHeroSectionLayout()
        case .continueWatching, .recentlyAdded, .recommendations, .discoverList, .searchGrid:
            return makeHubSectionLayout(section: section, isContinueWatching: section.kind == .continueWatching)
        case .watchlist:
            return makeHubSectionLayout(section: section, isContinueWatching: false)
        case .recommendationsLoading, .recommendationsError:
            return makeRecommendationsStateLayout()
        case .sortHeader:
            return makeSortHeaderSectionLayout()
        case .grid:
            return makeGridSectionLayout(section: section)
        case .searchPrompt, .searchState:
            return makeSearchFullWidthLayout()
        }
    }

    /// Full-width section for `MediaLibrarySortControl` (library mode only).
    /// Height is estimated at 96pt (34pt title + 4pt gap + ~21pt count +
    /// 20+20pt vertical padding) — ported from
    /// MediaLibraryViewController.makeSortHeaderSectionLayout().
    private func makeSortHeaderSectionLayout() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(96)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 24, trailing: 0)
        return section
    }

    /// Multi-column poster grid (library + search modes). Derived ENTIRELY
    /// from MediaRowMetrics so grid columns land exactly where the shelf
    /// rows' at-rest tiles sit: rowLeading margins, posterGap between
    /// columns, posterFullCount across. With the shelf equation satisfied
    /// (2*52 + 6*296 + 5*8 = 1920) the computed column width IS posterWidth.
    /// Search-mode group grids add a row-style header when titled.
    private func makeGridSectionLayout(section data: HomeSectionData) -> NSCollectionLayoutSection {
        // Music libraries render 1:1 square tiles; everything else 2:3.
        let tileHeight = data.isMusic ? MediaRowMetrics.musicHeight : MediaRowMetrics.posterHeight
        let groupHeight = tileHeight + MediaRowMetrics.focusGrowthPadding

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(MediaRowMetrics.posterFullCount)),
            heightDimension: .absolute(groupHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .absolute(groupHeight)
        )
        // Horizontal group with explicit count fixes each row at N items
        // regardless of fractional rounding.
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize,
                                                       repeatingSubitem: item,
                                                       count: MediaRowMetrics.posterFullCount)
        group.interItemSpacing = .fixed(MediaRowMetrics.posterGap)

        let section = NSCollectionLayoutSection(group: group)
        // Margins from the PANEL edge to match the shelves (not the safe area).
        section.contentInsetsReference = .none
        section.interGroupSpacing = 24
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 24,
            leading: MediaRowMetrics.rowLeading,
            bottom: 48,
            trailing: MediaRowMetrics.rowTrailing
        )

        if data.title != nil {
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(40)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            // The section's own insets (rowLeading) already position the
            // header via supplementariesFollowContentInsets (default true),
            // so it aligns with the first grid column like shelf headers do.
            section.boundarySupplementaryItems = [header]
        }
        return section
    }

    /// Full-width section for the search prompt / state cells. Self-sizing —
    /// the cells pin their content with generous top padding so the block
    /// sits below the system search keyboard.
    private func makeSearchFullWidthLayout() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(420)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        return section
    }

    /// Single full-width cell for the recommendations-loading / error
    /// inline states. SwiftUI rendering uses `padding(.horizontal,
    /// rowHorizontalPadding=48)` + `.padding(.vertical, 24)` for loading
    /// and `.padding(.vertical, 12)` for error -- we use 24 as the
    /// average; the cell handles its own internal padding via its
    /// rowStack constraints.
    private func makeRecommendationsStateLayout() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(80)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 24, leading: 32, bottom: 48, trailing: 48)
        return section
    }

    private func makeHeroSectionLayout() -> NSCollectionLayoutSection {
        // Height matches the SwiftUI hero section height: screen - 200pt.
        let height = max(400, UIScreen.main.bounds.height - 200)
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(height))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        // Edge-referenced like the hub rows (the overlay's internal rowLeading
        // is measured from the panel edge). Insets stay zero — the overlay
        // cell already owns its own vertical composition.
        section.contentInsetsReference = .none
        // Small bottom gap so the first row (Continue Watching) sits a bit
        // lower, separated from the hero.
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 40, trailing: 0)
        return section
    }

    /// One full-width ShelfRowCell per hub section. The row hosts its own
    /// horizontal collection view and drives its own scroll — NOT an
    /// orthogonal section. Measured behavior of the embedded orthogonal
    /// scroller on tvOS (settle-log verified, 2026-06-10): focus landings
    /// always pin a tile's leading edge to the raw screen edge, ignoring
    /// section contentInsets / scroller contentInset / isScrollEnabled, so a
    /// left-side peeking sliver is impossible and the at-rest margin is lost
    /// on the first scroll. See ShelfRowCell for the self-driven landing math.
    private func makeHubSectionLayout(section: HomeSectionData, isContinueWatching: Bool) -> NSCollectionLayoutSection {
        let tileHeight: CGFloat = isContinueWatching
            ? MediaRowMetrics.cwHeight
            : (section.isMusic ? MediaRowMetrics.musicHeight : MediaRowMetrics.posterHeight)
        let rowHeight = tileHeight + MediaRowMetrics.focusGrowthPadding  // room for focus growth

        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(rowHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])

        let layoutSection = NSCollectionLayoutSection(group: group)
        // Full-bleed row from the PANEL edge (not the safe area): the
        // ShelfRowCell carries the rowLeading margin and the peeking slivers
        // internally.
        layoutSection.contentInsetsReference = .none
        // top: header-to-first-card gap (row title sits close to its cards).
        // bottom: gap to the next section.
        layoutSection.contentInsets = NSDirectionalEdgeInsets(
            top: MediaRowMetrics.rowTopInset,
            leading: 0,
            bottom: MediaRowMetrics.rowBottomInset,
            trailing: 0
        )

        if section.title != nil {
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(40)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            // The section has no horizontal insets (full-bleed row), so the
            // header carries its own margin to align with the first tile.
            header.contentInsets = NSDirectionalEdgeInsets(
                top: 0,
                leading: MediaRowMetrics.rowLeading,
                bottom: 0,
                trailing: MediaRowMetrics.rowTrailing
            )
            layoutSection.boundarySupplementaryItems = [header]
        }

        return layoutSection
    }

    // MARK: - Data source

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<HomeSectionID, HomeItemID>(collectionView: collectionView) { [weak self] collectionView, indexPath, itemID in
            guard let self else { return nil }
            return self.cell(for: itemID, at: indexPath, in: collectionView)
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard let self,
                  kind == UICollectionView.elementKindSectionHeader,
                  indexPath.section < self.sectionsSnapshot.count
            else { return nil }
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: HubHeaderView.reuseID,
                for: indexPath
            ) as! HubHeaderView
            let section = self.sectionsSnapshot[indexPath.section]
            let loadedCount: Int
            switch section.kind {
            case .hero, .recommendationsLoading, .recommendationsError, .sortHeader,
                 .searchPrompt, .searchState:
                loadedCount = 0
            case .continueWatching, .recentlyAdded, .recommendations, .grid, .discoverList,
                 .searchGrid:
                loadedCount = section.items.count
            case .watchlist: loadedCount = section.watchlistItems.count
            }
            header.configure(
                title: section.title ?? "",
                style: section.headerStyle,
                loadedCount: loadedCount,
                totalCount: section.totalSize
            )
            return header
        }
    }

    private func cell(for itemID: HomeItemID, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        guard indexPath.section < sectionsSnapshot.count else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
        }
        let section = sectionsSnapshot[indexPath.section]
        let perfKey = "\(itemID.sectionID.raw):\(itemID.itemID)"

        // Skeleton item: SwiftUI shows a placeholder card at the row's end
        // while pagination is in flight. We add a synthetic itemID with a
        // fixed sentinel; recognise it here and dequeue a skeleton cell.
        if itemID.itemID == HomeItemID.skeletonSentinel {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PosterSkeletonCell.reuseID, for: indexPath) as! PosterSkeletonCell
            cell.configure(layout: section.kind == .continueWatching ? .continueWatching : .poster)
            return cell
        }

        switch section.kind {
        case .hero:
            if itemID.itemID == Self.heroLoadingItemToken {
                return collectionView.dequeueReusableCell(withReuseIdentifier: HeroLoadingCell.reuseID, for: indexPath)
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: HeroOverlayCell.reuseID, for: indexPath) as! HeroOverlayCell
            if !section.heroMediaItems.isEmpty {
                // Discover mode: TMDB-mapped MediaItem hero (same overlay,
                // MediaItem configuration path).
                cell.configure(withMediaItems: HeroOverlayCell.MediaItemConfiguration(
                    items: section.heroMediaItems,
                    initialIndex: heroCurrentIndex,
                    onIndexChanged: { [weak self, weak cell] newIndex, item in
                        guard let self else { return }
                        self.heroCurrentIndex = newIndex
                        self.updateBackdrop(forMediaItem: item)
                        self.applyDiscoverHeroState(for: item, on: cell)
                    },
                    onPlay: { [weak self] item in self?.discoverHeroPlay(item) },
                    onInfo: { [weak self] item in self?.discoverHeroInfo(item) },
                    onToggleWatchlist: { [weak self, weak cell] item in
                        self?.toggleDiscoverWatchlist(for: item) { [weak self, weak cell] in
                            self?.applyDiscoverHeroState(for: item, on: cell)
                        }
                    }
                ))
                cell.overlay.onFocusEntered = { [weak self] in
                    self?.scrollHeroIntoView()
                }
                if heroCurrentIndex < section.heroMediaItems.count {
                    applyDiscoverHeroState(for: section.heroMediaItems[heroCurrentIndex], on: cell)
                }
                return cell
            }
            cell.configure(with: HeroOverlayCell.Configuration(
                items: section.heroItems,
                serverURL: authManager.selectedServerURL ?? "",
                authToken: authManager.selectedServerToken ?? "",
                initialIndex: heroCurrentIndex,
                onIndexChanged: { [weak self] newIndex, item in
                    guard let self else { return }
                    self.heroCurrentIndex = newIndex
                    // Drive the backdrop off the exact item the overlay is
                    // showing, not heroItems[newIndex] (the two arrays diverge
                    // once the TMDB upgrade reorders heroItems).
                    self.updateBackdrop(for: item)
                },
                onInfo: { [weak self] item in self?.presentDetailPage(for: item) },
                onPlay: { [weak self] item in self?.playItemDirectly(item) },
                onFocusEntered: { [weak self] in
                    self?.scrollHeroIntoView()
                }
            ))
            return cell

        case .continueWatching, .recentlyAdded, .recommendations, .watchlist, .discoverList, .searchGrid:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            Perf.interval(.cellPrepare, key: perfKey) {
                configureShelfRow(cell, sectionID: section.id)
            }
            return cell

        case .grid:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
            if indexPath.item < section.items.count {
                Perf.interval(.cellPrepare, key: perfKey) {
                    cell.configure(item: section.items[indexPath.item])
                }
            }
            return cell

        case .sortHeader:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MediaLibrarySortControl.reuseID, for: indexPath) as! MediaLibrarySortControl
            cell.configure(title: section.title ?? "", count: totalGridCount, sortName: gridSort.displayName)
            cell.onSortTapped = { [weak self] in self?.presentSortPicker() }
            return cell

        case .recommendationsLoading:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: RecommendationsStateCell.reuseID, for: indexPath) as! RecommendationsStateCell
            cell.configure(state: .loading)
            return cell

        case .recommendationsError:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: RecommendationsStateCell.reuseID, for: indexPath) as! RecommendationsStateCell
            cell.configure(state: .error(message: recommendationsError ?? "Unknown error"))
            cell.onRetry = { [weak self] in
                Task { await self?.refreshRecommendations(force: true) }
            }
            return cell

        case .searchPrompt:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SearchPromptCell.reuseID, for: indexPath) as! SearchPromptCell
            cell.configure(recentSearches: recentSearches)
            cell.onRecentSelected = { [weak self] query in
                guard let self else { return }
                // Run the recalled query directly; the shell mirrors it into
                // the keyboard field via onSearchQueryChangedByController.
                self.searchQuery = query
                self.onSearchQueryChangedByController?(query)
                self.submitSearch()
            }
            cell.onClearRecents = { [weak self] in self?.clearRecentSearches() }
            return cell

        case .searchState:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SearchStateCell.reuseID, for: indexPath) as! SearchStateCell
            cell.configure(state: currentSearchState)
            cell.onRetry = { [weak self] in self?.submitSearch() }
            return cell
        }
    }

    // MARK: - Data store observation

    private func observeDataStore() {
        // Row content comes from the MediaItem projection now (Stage 2/3):
        // `homeItemsVersion` drives home-mode rows, `libraryHubsVersion` drives
        // library-mode rows (it's also bumped by projectLibraryItems). Both
        // route through the coalescing `setNeedsSnapshotApply` so a burst of
        // signals collapses to one apply per runloop turn (no double-paint).
        dataStore.$homeItemsVersion
            .merge(with: dataStore.$libraryHubsVersion)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsSnapshotApply()
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        // `hubsVersion` no longer rebuilds rows (those come from the projection
        // above). It still drives hero selection + state precedence: hero stays
        // PlexMetadata-backed until Stage 4 and reads `dataStore.hubs`.
        dataStore.$hubsVersion
            .merge(with: dataStore.$libraryHubsVersion)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.selectHeroItemsIfNeeded()
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        dataStore.$continueWatchingHub
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsSnapshotApply()
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        dataStore.$isLoadingHubs
            .merge(with: dataStore.$hubsError.map { _ in false })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        dataStore.$isHomeHeroReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        // Refresh hubs after playback dismissals etc.
        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    switch self.mode {
                    case .discover:
                        break  // TMDB lists don't change with playback state
                    case .search:
                        break  // results re-fetch per query, nothing standing to refresh
                    case .home:
                        await self.dataStore.refreshHubs()
                        await self.dataStore.refreshLibraryHubs()
                        if self.enablePersonalizedRecommendations {
                            await self.refreshRecommendations(force: true)
                        }
                    case .library:
                        await self.refreshThisLibraryHubs()
                    }
                }
            }
            .store(in: &dataStoreObservers)

        // The TMDB trending-hero upgrade runs on home and on typed (movie/show)
        // libraries; `requestHeroUpgrade` -> `upgradeHeroFromTMDB` self-gates
        // non-video libraries via `trendingHeroType() == nil`, so it's safe to
        // subscribe unconditionally for any `.library` surface here.
        switch mode {
        case .home, .library:
            NotificationCenter.default.publisher(for: .libraryGUIDIndexDidUpdate)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.requestHeroUpgrade()
                }
                .store(in: &dataStoreObservers)
        case .discover, .search:
            break
        }
    }

    private func observeWatchlist() {
        watchlistService.$watchlistItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.setNeedsSnapshotApply()
                self?.prewarmWatchlistArtwork(Array(items.prefix(20)))
            }
            .store(in: &dataStoreObservers)

        // Transient write-error toast. Mirrors SwiftUI
        // `.watchlistToast(message: watchlistService.transientWriteError)`.
        watchlistService.$transientWriteError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.watchlistToast.show(message: message)
            }
            .store(in: &dataStoreObservers)
    }

    private func observeAuth() {
        // Connection state controls the inline banner + the
        // notConnectedView precedence (via hasCredentials → authToken).
        authManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        authManager.$connectionError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.authManager.isConnected {
                    self.connectionBanner.setMessage(self.authManager.connectionError)
                }
            }
            .store(in: &dataStoreObservers)

        authManager.$authToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)
    }

    /// React to AppStorage-backed settings (`showHomeHero`,
    /// `enablePersonalizedRecommendations`) flipping while the home is on
    /// screen. `UserDefaults.didChangeNotification` fires once per change.
    /// We just re-evaluate the relevant subsystem; no need to filter by key.
    private func observeUserDefaults() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.backdropView.isHidden = !self.showHomeHero
                if !self.showHomeHero {
                    self.setHeroBackdrop(url: nil)
                }
                self.updateContentTopInset()
                self.reprojectIfHomeLibrariesChanged()
                self.selectHeroItemsIfNeeded()
                if case .home = self.mode {
                    if self.enablePersonalizedRecommendations {
                        if self.recommendations.isEmpty {
                            Task { await self.refreshRecommendations(force: false) }
                        }
                    } else if !self.recommendations.isEmpty {
                        self.recommendations = []
                        self.applySnapshot(animated: false)
                    }
                }
                // A library page's row set is computed from the Recent/Discovery
                // Rows gates at snapshot time, so flipping either only shows up
                // on a re-apply. Cheap: the diffable snapshot is a no-op when
                // the row set is unchanged.
                if case .library = self.mode {
                    self.applySnapshot(animated: false)
                }
            }
            .store(in: &dataStoreObservers)
    }

    /// Last-seen shown-on-Home library set, so the UserDefaults observer can
    /// tell a library-visibility change from any other defaults write.
    private var lastHomeLibraryKeys: Set<String>?

    /// Re-derive the account-level (cross-library) Home content when the user
    /// changes which libraries appear on Home.
    ///
    /// `LibrarySettingsManager` persists straight to UserDefaults with no
    /// change notification of its own, and the Continue Watching row and the
    /// hero are both filtered client-side from caches that were written under
    /// the OLD visibility. Without this they stay wrong until the next 3-minute
    /// poll. Recently Added needs nothing here — it is rebuilt per library from
    /// `librariesForHomeScreen`, so a hidden library is structurally absent.
    private func reprojectIfHomeLibrariesChanged() {
        guard case .home = mode else { return }
        let keys = Set(dataStore.librariesForHomeScreen.map { $0.key })
        guard lastHomeLibraryKeys != nil else {
            // First observation is the baseline, not a change.
            lastHomeLibraryKeys = keys
            return
        }
        guard lastHomeLibraryKeys != keys else { return }
        lastHomeLibraryKeys = keys

        // Re-run the projection so Continue Watching is re-filtered from the
        // metadata still held in the data store (no refetch needed).
        dataStore.projectHomeItems()

        // Drop the hero and re-resolve. The persisted hero is PlexMetadata from
        // the old visibility, so `selectHeroItemsIfNeeded` would just replay it;
        // clearing forces the filtered cache read / hub fallback to run again.
        heroItems = []
        heroState = .idle
        lastUpgradedIndexGeneration = -1
        selectHeroItemsIfNeeded()
        applySnapshot(animated: false)
    }

    // MARK: - Snapshot

    /// Coalesce snapshot rebuilds. At launch 4-6 data signals fire in a burst
    /// (cache paint -> hubsVersion, network refresh -> hubsVersion again,
    /// continueWatchingHub, watchlistItems, hero selection...) and EACH was
    /// triggering a full synchronous applySnapshot at 1.9-3.5s on device —
    /// the SwiftUI home coalesced these for free, the UIKit port must do it
    /// explicitly. One apply per main-runloop turn services the whole burst.
    private var snapshotApplyScheduled = false
    private func setNeedsSnapshotApply() {
        guard !snapshotApplyScheduled else { return }
        snapshotApplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshotApplyScheduled = false
            self.applySnapshot(animated: false)
        }
    }

    private func applySnapshot(animated: Bool) {
        // Main-thread timing: applySnapshot runs on every hubsVersion/state
        // change and builds the whole diffable snapshot. If this is the 10s
        // launch hitch, it surfaces here.
        let snapStart = ProcessInfo.processInfo.systemUptime
        defer {
            let ms = Int((ProcessInfo.processInfo.systemUptime - snapStart) * 1000)
            if ms > 200 { StartupTimer.mark("applySnapshot took \(ms)ms (main)") }
        }
        let computeStart = ProcessInfo.processInfo.systemUptime
        let sections = computeSections()
        let computeMs = Int((ProcessInfo.processInfo.systemUptime - computeStart) * 1000)
        if computeMs > 200 { StartupTimer.mark("  computeSections \(computeMs)ms") }
        sectionsSnapshot = sections

        let applyStart = ProcessInfo.processInfo.systemUptime
        defer {
            let applyMs = Int((ProcessInfo.processInfo.systemUptime - applyStart) * 1000)
            if applyMs > 200 { StartupTimer.mark("  dataSource.apply \(applyMs)ms") }
        }

        var snapshot = NSDiffableDataSourceSnapshot<HomeSectionID, HomeItemID>()
        for section in sections {
            snapshot.appendSections([section.id])
            var ids: [HomeItemID]
            switch section.kind {
            case .hero:
                // Discover's hero is MediaItem-backed; only a section with
                // neither item array is the loading placeholder.
                let isPlaceholder = section.heroItems.isEmpty && section.heroMediaItems.isEmpty
                ids = [HomeItemID(sectionID: section.id,
                                  itemID: isPlaceholder ? Self.heroLoadingItemToken : "hero-overlay")]
            case .sortHeader:
                ids = [Self.sortHeaderItemID]
            case .continueWatching, .recentlyAdded, .recommendations, .watchlist, .discoverList, .searchGrid:
                // Shelf rows are ONE diffable item — the ShelfRowCell hosts
                // the tiles in its own horizontal collection view (and shows
                // the pagination skeleton itself). Content changes don't
                // change this identity; applySnapshot pushes new counts to
                // visible rows afterward (updateVisibleShelfRows).
                ids = [HomeItemID(sectionID: section.id, itemID: Self.shelfRowItemToken)]
            case .grid:
                ids = section.items.enumerated().compactMap { idx, item -> HomeItemID? in
                    let raw = item.ref.itemID
                    let id = raw.isEmpty ? "\(section.id.raw)-\(idx)" : raw
                    return HomeItemID(sectionID: section.id, itemID: id)
                }
            case .recommendationsLoading:
                ids = [HomeItemID(sectionID: section.id, itemID: "recs-loading")]
            case .recommendationsError:
                ids = [HomeItemID(sectionID: section.id, itemID: "recs-error")]
            case .searchPrompt:
                ids = [HomeItemID(sectionID: section.id, itemID: "search-prompt")]
            case .searchState:
                ids = [HomeItemID(sectionID: section.id, itemID: "search-state")]
            }

            // Diffable data source crashes on duplicate identifiers.
            // Plex hubs occasionally return the same ratingKey twice
            // (cross-library cameos, hub merges, etc.) — keep the first
            // occurrence and drop the rest.
            var seen = Set<HomeItemID>()
            let deduped = ids.filter { seen.insert($0).inserted }
            snapshot.appendItems(deduped, toSection: section.id)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
        // Shelf rows keep a single diffable identity, so content growth /
        // refresh inside a row must be pushed to the visible cells by hand.
        updateVisibleShelfRows()
        updateAmbientIfNeeded()
        // Cold launch: the hero cell materializes only after this apply's
        // layout pass — re-assert the launch focus once it exists.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nudgeInitialHeroFocusIfNeeded()
        }
    }

    // MARK: - Shelf rows (Continue Watching / Recently Added / Recommendations / Watchlist)

    /// Single diffable itemID for every shelf row (one item per hub section).
    static let shelfRowItemToken = "__shelf-row__"

    /// Diffable itemID for the hero slot's loading placeholder. Distinct from
    /// "hero-overlay" so the snapshot swap re-vends the cell when content lands.
    static let heroLoadingItemToken = "hero-loading"

    /// Resting scroll offset per shelf section, restored across cell reuse.
    private var shelfOffsets: [HomeSectionID: CGFloat] = [:]

    private func isShelfKind(_ kind: HomeSectionKind) -> Bool {
        switch kind {
        case .continueWatching, .recentlyAdded, .recommendations, .watchlist, .discoverList, .searchGrid: return true
        case .hero, .grid, .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState: return false
        }
    }

    private func shelfSection(id: HomeSectionID) -> HomeSectionData? {
        sectionsSnapshot.first(where: { $0.id == id })
    }

    private func shelfRealCount(_ section: HomeSectionData) -> Int {
        section.kind == .watchlist ? section.watchlistItems.count : section.items.count
    }

    /// Content identity for a shelf row — reload only when this changes.
    private func shelfContentToken(_ section: HomeSectionData) -> Int {
        var hasher = Hasher()
        if section.kind == .watchlist {
            for item in section.watchlistItems { hasher.combine(item.id) }
        } else {
            for item in section.items {
                hasher.combine(item.ref.itemID)
                // Include playback progress so the shelf row re-vends its tiles
                // when a viewOffset changes (e.g. after watching something) even
                // though the item set is identical. Without this the token is
                // unchanged, ShelfRowCell skips reloadData, and Continue Watching
                // never updates its progress bars.
                hasher.combine(item.userState.viewOffset)
                hasher.combine(item.userState.lastViewedAt)
            }
        }
        return hasher.finalize()
    }

    private func configureShelfRow(_ cell: ShelfRowCell, sectionID: HomeSectionID) {
        guard let section = shelfSection(id: sectionID) else { return }
        bindShelfCellProvider(cell, section: section)
        cell.onSelect = { [weak self] itemIndex in
            self?.handleShelfTap(sectionID: sectionID, itemIndex: itemIndex)
        }
        cell.onWillDisplayItem = { [weak self] itemIndex in
            self?.shelfWillDisplay(sectionID: sectionID, itemIndex: itemIndex)
        }
        cell.onLongPressItem = { [weak self] itemIndex in
            self?.presentShelfTileMenu(sectionID: sectionID, itemIndex: itemIndex)
        }
        cell.onOffsetChanged = { [weak self] offset in
            self?.shelfOffsets[sectionID] = offset
        }
        cell.configure(
            kind: section.kind == .continueWatching ? .continueWatching : (section.isMusic ? .music : .poster),
            realCount: shelfRealCount(section),
            hasSkeleton: paginationStates[section.id]?.isLoadingMore == true,
            contentToken: shelfContentToken(section),
            initialOffset: shelfOffsets[sectionID] ?? 0
        )
    }

    /// Bind a row's tile provider to a CAPTURED section value, so the count the
    /// row is configured with and the array its tiles are read from are the same
    /// snapshot. Looking the section up live in `sectionsSnapshot` on every
    /// dequeue was a second source of truth: the inner collection's item count
    /// comes from the row's own cached `realCount`, so once a section's items
    /// shrank between a row's last configure and a tile being realized (a hub
    /// refresh dropping a paginated-in extra), every index past the NEW count
    /// vended the pagination skeleton — a stray empty placeholder mid-row, next
    /// to tiles realized while the two counts still agreed.
    private func bindShelfCellProvider(_ cell: ShelfRowCell, section: HomeSectionData) {
        cell.cellProvider = { [weak self] innerCV, indexPath in
            self?.shelfItemCell(in: innerCV, at: indexPath, section: section)
                ?? innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
        }
    }

    /// Push fresh counts / content into already-visible shelf rows after a
    /// snapshot apply (their diffable identity never changes, so diffing
    /// won't reconfigure them).
    private func updateVisibleShelfRows() {
        for case let cell as ShelfRowCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  indexPath.section < sectionsSnapshot.count
            else { continue }
            let section = sectionsSnapshot[indexPath.section]
            guard isShelfKind(section.kind) else { continue }
            if let pending = pendingShelfRemoval, pending.sectionID == section.id {
                // Animate the captured single-tile removal: delete that index
                // so the survivors slide left to fill. The row keeps its other
                // callbacks (they capture the stable sectionID), but the tile
                // provider holds a section VALUE and must be re-bound to the
                // post-removal one or the indices it serves are off by one
                // past the deleted slot.
                bindShelfCellProvider(cell, section: section)
                cell.animateRemoval(at: pending.index,
                                    newRealCount: shelfRealCount(section),
                                    newSkeleton: paginationStates[section.id]?.isLoadingMore == true,
                                    contentToken: shelfContentToken(section))
            } else {
                configureShelfRow(cell, sectionID: section.id)
            }
        }
        // A captured removal is valid only for the apply it triggered; clear
        // it so a later apply can't replay a stale delete (and an off-screen
        // CW row just reloads fresh when scrolled back into view).
        pendingShelfRemoval = nil
    }

    /// Tile cell inside a shelf row. Mirrors the per-item cases the outer
    /// collection used before the rows became self-scrolling; the skeleton
    /// placeholder is the index just past the real items.
    private func shelfItemCell(in innerCV: UICollectionView, at indexPath: IndexPath, section: HomeSectionData) -> UICollectionViewCell? {
        let perfKey = "\(section.id.raw):\(indexPath.item)"

        // Real tiles only — ShelfRowCell places the pagination skeleton itself
        // (it owns the count that decides where the trailing slot is). An index
        // past this section's items means the row is running ahead of the
        // snapshot we were bound to; hand back nil for a blank poster rather
        // than trapping on the subscript.
        guard indexPath.item < shelfRealCount(section) else { return nil }

        switch section.kind {
        case .continueWatching:
            let cell = innerCV.dequeueReusableCell(withReuseIdentifier: ContinueWatchingCell.reuseID, for: indexPath) as! ContinueWatchingCell
            Perf.interval(.cellPrepare, key: perfKey) {
                cell.configure(item: section.items[indexPath.item])
            }
            return cell
        case .recentlyAdded, .recommendations, .discoverList, .searchGrid:
            let cell = innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
            Perf.interval(.cellPrepare, key: perfKey) {
                cell.configure(item: section.items[indexPath.item])
            }
            return cell
        case .watchlist:
            let cell = innerCV.dequeueReusableCell(withReuseIdentifier: WatchlistPosterCell.reuseID, for: indexPath) as! WatchlistPosterCell
            Perf.interval(.cellPrepare, key: perfKey) {
                cell.configure(item: section.watchlistItems[indexPath.item])
            }
            return cell
        case .hero, .grid, .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState:
            return nil
        }
    }

    private func handleShelfTap(sectionID: HomeSectionID, itemIndex: Int) {
        guard let sectionIndex = sectionsSnapshot.firstIndex(where: { $0.id == sectionID }) else { return }
        let section = sectionsSnapshot[sectionIndex]
        guard itemIndex < shelfRealCount(section) else { return }
        switch section.kind {
        case .continueWatching:
            // Instant Resume on: a CW tile resumes straight away. Off: it
            // behaves like every other shelf row and opens the preview carousel.
            if SettingsStore.bool("continueWatchingInstantResume", default: true) {
                playItem(section.items[itemIndex])
            } else {
                presentPreview(forSection: section, indexPath: IndexPath(item: itemIndex, section: sectionIndex))
            }
        case .recentlyAdded, .recommendations:
            presentPreview(forSection: section, indexPath: IndexPath(item: itemIndex, section: sectionIndex))
        case .discoverList:
            // Upgrade matched items to their library MediaItems first so the
            // carousel offers Play. sourceItemID stays the ORIGINAL tmdb id —
            // focus restore matches against section.items.
            let original = section.items[itemIndex]
            let sourceItemID = original.ref.itemID.isEmpty
                ? "\(section.id.raw)-\(itemIndex)"
                : original.ref.itemID
            let indexPath = IndexPath(item: itemIndex, section: sectionIndex)
            Task { @MainActor in
                let upgraded = await upgradeDiscoverItems(section.items)
                presentPreviewOverlay(
                    items: upgraded,
                    selectedIndex: itemIndex,
                    sourceRowID: section.id.raw,
                    sourceItemID: sourceItemID,
                    sourceIndexPath: indexPath,
                    sourceItemIDs: sourceItemIDs(for: section)
                )
            }
        case .watchlist:
            Task { await openWatchlistPreview(section: section, tappedIndex: itemIndex, indexPath: IndexPath(item: itemIndex, section: sectionIndex)) }
        case .searchGrid:
            handleSearchTap(section: section, indexPath: IndexPath(item: itemIndex, section: sectionIndex))
        case .hero, .grid, .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState:
            return
        }
    }

    /// Pagination trigger, mirroring the outer willDisplay it replaces: when
    /// a tile within 5 of the loaded tail displays, fetch the next page.
    private func shelfWillDisplay(sectionID: HomeSectionID, itemIndex: Int) {
        guard let section = shelfSection(id: sectionID) else { return }
        switch section.kind {
        case .continueWatching, .recentlyAdded:
            break
        case .hero, .watchlist, .recommendations, .grid, .discoverList,
             .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState, .searchGrid:
            return  // No pagination for these (matches SwiftUI hubKey == nil)
        }
        guard itemIndex >= section.items.count - 5 else { return }
        Task { @MainActor in
            await self.loadMoreIfNeeded(sectionID: section.id, hubKey: section.hubKey, hubIdentifier: section.hubIdentifier)
        }
    }

    /// Select long-press on a shelf tile → the tile action menu popup.
    /// Same per-section routing the context-menu delegate used before the
    /// system path died on tvOS 26 (see TileMenuPopupViewController).
    private func presentShelfTileMenu(sectionID: HomeSectionID, itemIndex: Int) {
        guard let section = shelfSection(id: sectionID) else { return }
        switch section.kind {
        case .continueWatching, .recentlyAdded, .recommendations:
            guard itemIndex < section.items.count else { return }
            let item = section.items[itemIndex]
            presentTileMenu(sections: tileMenuSections(for: item,
                                                       isContinueWatching: section.kind == .continueWatching,
                                                       shelfLocation: (sectionID: sectionID, itemIndex: itemIndex)))
        case .discoverList:
            presentDiscoverTileMenu(sectionID: sectionID, itemIndex: itemIndex)
        case .searchGrid:
            guard itemIndex < section.items.count else { return }
            // Music results (artist/album/track) route to the music surfaces;
            // the Plex watched/watchlist menu doesn't apply to them.
            if let meta = searchGroupMetas[sectionID]?[safe: itemIndex],
               ["artist", "album", "track"].contains(meta.type ?? "") {
                return
            }
            let item = section.items[itemIndex]
            presentTileMenu(sections: tileMenuSections(for: item, isContinueWatching: false))
        case .watchlist:
            presentWatchlistTileMenu(sectionID: sectionID, itemIndex: itemIndex)
        case .hero, .grid, .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState:
            return  // hero / state cells don't get menus
        }
    }

    /// The focused tile's VISUAL frame in window coordinates — the menu
    /// anchor. The cell frame doesn't include the lockup's focus float
    /// (TVPosterView scales its content internally, not the view), so the
    /// frame is grown by the focus scale to match what's on screen.
    private func focusedTileFrame() -> CGRect? {
        var view = UIScreen.main.focusedView
        while let current = view, !(current is UICollectionViewCell) { view = current.superview }
        guard let cell = view as? UICollectionViewCell else { return nil }
        let frame = cell.convert(cell.bounds, to: nil)
        let focusScale: CGFloat = 1.1
        return frame.insetBy(dx: -frame.width * (focusScale - 1) / 2,
                             dy: -frame.height * (focusScale - 1) / 2)
    }

    // MARK: - Play/Pause button (physical remote)

    /// True while we are consuming a Play/Pause press we began handling, so the
    /// matching `pressesEnded` can be swallowed too. An Ended phase that bubbles
    /// up without its Began having been handled here makes the system apply its
    /// own default handling and peel an extra layer off the presentation stack,
    /// which is the same reason the player chrome tracks this flag.
    private var isHandlingPlayPausePress = false

    /// The physical Play/Pause button starts or resumes the focused tile,
    /// matching what Infuse and the Plex client do. Select is untouched: it
    /// arrives through `didSelectItemAt` on the collection view, an entirely
    /// separate delivery path from presses, so adding this cannot change what
    /// Select does on any row.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .playPause {
            isHandlingPlayPausePress = true
            playFocusedTile()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .playPause && isHandlingPlayPausePress {
            isHandlingPlayPausePress = false
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .playPause && isHandlingPlayPausePress {
            isHandlingPlayPausePress = false
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    /// Resolve whatever currently holds focus to a playable MediaItem and play
    /// it. Everything here is deliberately best-effort: a Play press on a tile
    /// with nothing playable behind it (a Discover or watchlist entry the server
    /// does not have, a state or skeleton cell, a music result) does nothing at
    /// all rather than presenting a player that cannot start.
    private func playFocusedTile() {
        // A presented popup or player owns its own input; never play underneath
        // one. The player itself consumes Play/Pause before it could ever reach
        // this surface, but the tile menu popup is focusless enough that being
        // explicit costs nothing.
        guard presentedViewController == nil, let item = focusedPlayableItem() else { return }

        // A show or a season has no playable media of its own, so Play has to
        // resolve to a concrete episode first. Same composition as the preview
        // carousel's Play pill (`playHeroItem`), so the two surfaces can never
        // disagree about which episode a Play press starts.
        guard item.kind == .show || item.kind == .season else {
            playItem(item)
            return
        }
        Task { [weak self] in
            guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
                await MainActor.run { self?.playItem(item) }
                return
            }
            let target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider)
            await MainActor.run { self?.playItem(target ?? item) }
        }
    }

    /// The MediaItem behind the focused tile, or nil when focus is on something
    /// that cannot be played. Mirrors the guards `handleTap` and
    /// `handleShelfTap` already apply so a Play press can never reach a target
    /// a Select press would have refused.
    private func focusedPlayableItem() -> MediaItem? {
        // Shelf rows first: their tiles live inside the row cell's own nested
        // collection view, so the outer collection's focused index path is the
        // ROW, not the tile. Ask the row which of its tiles has focus.
        for case let row as ShelfRowCell in collectionView.visibleCells {
            guard let itemIndex = row.focusedItemIndex(),
                  let rowIndexPath = collectionView.indexPath(for: row),
                  rowIndexPath.section < sectionsSnapshot.count
            else { continue }
            return playableShelfItem(section: sectionsSnapshot[rowIndexPath.section], itemIndex: itemIndex)
        }

        // Library grid: its tiles are cells of the outer collection view, so the
        // same lookup the grid long-press uses applies directly.
        guard let indexPath = TileLongPress.focusedCell(in: collectionView),
              indexPath.section < sectionsSnapshot.count
        else { return nil }
        // The trailing loading-skeleton card is not an item.
        if let itemID = dataSource.itemIdentifier(for: indexPath),
           itemID.itemID == HomeItemID.skeletonSentinel {
            return nil
        }
        let section = sectionsSnapshot[indexPath.section]
        guard case .grid = section.kind, indexPath.item < section.items.count else { return nil }
        return playableItem(section.items[indexPath.item])
    }

    /// Per-shelf-kind resolution of a focused tile index to a playable item.
    /// The state, prompt and hero kinds have no items at all; the watchlist is
    /// backed by PlexWatchlistItem rather than MediaItem and its entries are
    /// Discover metadata that need not exist on the server, so neither can
    /// produce a play target here.
    private func playableShelfItem(section: HomeSectionData, itemIndex: Int) -> MediaItem? {
        switch section.kind {
        case .continueWatching, .recentlyAdded, .recommendations, .discoverList:
            guard itemIndex < section.items.count else { return nil }
            return playableItem(section.items[itemIndex])
        case .searchGrid:
            guard itemIndex < section.items.count else { return nil }
            // Music results route to the music surfaces and are not video the
            // player can start, so Play ignores them.
            if let meta = searchGroupMetas[section.id]?[safe: itemIndex],
               ["artist", "album", "track"].contains(meta.type ?? "") {
                return nil
            }
            return playableItem(section.items[itemIndex])
        case .watchlist, .hero, .grid, .recommendationsLoading, .recommendationsError,
             .sortHeader, .searchPrompt, .searchState:
            return nil
        }
    }

    /// Gate on whether an item can actually be handed to the player. A
    /// metadata-only item comes from TMDB rather than the server and has no
    /// ratingKey to play, and a collection or person is not playable at all.
    private func playableItem(_ item: MediaItem) -> MediaItem? {
        guard !item.isMetadataOnly, !item.ref.itemID.isEmpty else { return nil }
        switch item.kind {
        case .movie, .show, .season, .episode:
            return item
        case .collection, .person, .unknown:
            return nil
        }
    }

    private func presentTileMenu(sections: [[TileMenuAction]]) {
        guard sections.contains(where: { !$0.isEmpty }), presentedViewController == nil else { return }
        // animated: false — the popup runs its own grow-from-the-tile
        // entrance/exit (see TileMenuPopupViewController).
        present(TileMenuPopupViewController(sections: sections,
                                            sourceFrame: focusedTileFrame()), animated: false)
    }

    /// Discover tile menu — mirror of SwiftUI `TMDBContextMenu`: Details when
    /// the item is library-matched, watchlist add/remove for everything.
    private func presentDiscoverTileMenu(sectionID: HomeSectionID, itemIndex: Int) {
        guard let tmdbItems = discoverListItems[sectionID],
              itemIndex < tmdbItems.count else { return }
        let item = tmdbItems[itemIndex]
        var actions: [TileMenuAction] = []

        if discoverModel.inLibraryTMDBIds.contains(item.id) {
            actions.append(TileMenuAction(title: "Details", systemImage: "info.circle") { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard let metadata = await self.discoverModel.libraryMatch(for: item),
                          let serverURL = self.authManager.selectedServerURL,
                          let token = self.authManager.selectedServerToken else { return }
                    let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
                    self.selectMediaItem(PlexMediaMapper.item(metadata, providerID: providerID, serverURL: serverURL, authToken: token))
                }
            })
        }

        let guid = "tmdb://\(item.id)"
        if watchlistService.contains(guid: guid) {
            actions.append(TileMenuAction(title: "Remove from Watchlist", systemImage: "bookmark.slash") { [weak self] in
                Task { await self?.watchlistService.remove(guid: guid) }
            })
        } else {
            actions.append(TileMenuAction(title: "Add to Watchlist", systemImage: "bookmark") { [weak self] in
                let watchType: PlexWatchlistItem.WatchlistType = item.mediaType == .movie ? .movie : .show
                let yearInt: Int? = {
                    guard let raw = item.releaseDate?.prefix(4), !raw.isEmpty else { return nil }
                    return Int(raw)
                }()
                let posterURL: URL? = item.posterPath.flatMap {
                    URL(string: "https://image.tmdb.org/t/p/w500\($0)")
                }
                let entry = PlexWatchlistItem(
                    id: guid,
                    title: item.title,
                    year: yearInt,
                    type: watchType,
                    posterURL: posterURL,
                    guids: [guid]
                )
                Task { await self?.watchlistService.add(guid: guid, item: entry) }
            })
        }

        presentTileMenu(sections: [actions])
    }

    /// Watchlist tile menu. Items are `PlexWatchlistItem`s (not `MediaItem`s),
    /// so this doesn't reuse the watched/unwatched menu: jump to details (same
    /// as tapping the tile) and remove from the watchlist.
    private func presentWatchlistTileMenu(sectionID: HomeSectionID, itemIndex: Int) {
        guard let sectionIndex = sectionsSnapshot.firstIndex(where: { $0.id == sectionID }) else { return }
        let section = sectionsSnapshot[sectionIndex]
        guard itemIndex < section.watchlistItems.count else { return }
        let item = section.watchlistItems[itemIndex]
        let guid = item.primaryGUID ?? item.id

        let info = TileMenuAction(title: "More Info", systemImage: "info.circle") { [weak self] in
            guard let self else { return }
            Task {
                await self.openWatchlistPreview(section: section,
                                                tappedIndex: itemIndex,
                                                indexPath: IndexPath(item: itemIndex, section: sectionIndex))
            }
        }
        let remove = TileMenuAction(title: "Remove from Watchlist",
                                    systemImage: "bookmark.slash",
                                    destructive: true) { [weak self] in
            Task { await self?.watchlistService.remove(guid: guid) }
        }
        presentTileMenu(sections: [[info, remove]])
    }

    /// Seed the ambient wash on surfaces that have no hero to drive it (hero
    /// switched off, or none loaded). Uses the first featured row's first item
    /// and runs once. When a hero IS present it owns the wash — every page
    /// change recolors it via `setHeroBackdrop(url:)` — so this backs off.
    private func updateAmbientIfNeeded() {
        guard !ambientView.hasAmbient else { return }
        // Discover's hero is MediaItem-backed (`heroMediaItems`); everywhere
        // else it's `heroItems`. Either one means a hero owns the wash.
        let heroSection = sectionsSnapshot.first(where: { $0.kind == .hero })
        let hasHero = !heroItems.isEmpty || !(heroSection?.heroMediaItems.isEmpty ?? true)
        if showHomeHero, hasHero { return }

        // MediaItem artwork URLs are already fully qualified, so no
        // server/auth args are needed.
        let firstItem = sectionsSnapshot.first(where: { !$0.items.isEmpty })?.items.first
            ?? dataStore.homeItems.first?.items.first
        guard let firstItem else { return }
        let request = firstItem.heroBackdropRequest()
        ambientView.setAmbient(url: request.backdropURL ?? request.thumbnailURL)
    }

    private func computeSections() -> [HomeSectionData] {
        if case .library(let key, let title) = mode {
            return computeLibrarySections(libraryKey: key, libraryTitle: title)
        }
        if case .discover = mode {
            return computeDiscoverSections()
        }
        if case .search = mode {
            return computeSearchSections()
        }

        var sections: [HomeSectionData] = []

        // Hero (when enabled): the real carousel once items resolve; while
        // the trending fetch is in flight the section stays in the snapshot
        // as a fixed-height placeholder so rows below never shift.
        if showHomeHero {
            if !heroItems.isEmpty {
                sections.append(.hero(items: heroItems))
            } else if heroState == .loading {
                sections.append(.hero(items: []))
            }
        }

        // Continue Watching + Recently-Added-per-library rows come from the
        // MediaItem projection (`dataStore.homeItems`). The projection mirrors
        // computeSections' old row set 1:1 (same HomeSectionID/title/
        // isContinueWatching/hubKey/hubIdentifier), so each CachedHomeHub maps
        // straight to a HomeSectionData — no PlexMetadata materialized here.
        for hub in dataStore.homeItems {
            let id = HomeSectionID(raw: hub.id)
            let merged = mergedItems(forSection: id, initial: hub.items)
            var items = merged.items
            if hub.isContinueWatching, !pendingCWRemovals.isEmpty {
                items.removeAll { pendingCWRemovals.contains($0.ref.itemID) }
            }
            sections.append(.hub(
                id: id,
                title: hub.title,
                items: items,
                isContinueWatching: hub.isContinueWatching,
                hubKey: hub.hubKey,
                hubIdentifier: hub.hubIdentifier,
                totalSize: merged.totalSize ?? hub.totalSize
            ))
        }

        // Watchlist
        let watchlistItems = Array(watchlistService.watchlistItems.prefix(20))
        if !watchlistItems.isEmpty {
            sections.append(.watchlist(items: watchlistItems))
        }

        // Personalized recommendations. Three-way branch:
        //   isLoadingRecommendations && empty   -> loading state cell
        //   recommendationsError != nil         -> error state cell
        //   !recommendations.isEmpty            -> populated row
        if enablePersonalizedRecommendations {
            if isLoadingRecommendations && recommendations.isEmpty {
                sections.append(.recommendationsLoading())
            } else if recommendationsError != nil {
                sections.append(.recommendationsError())
            } else if !recommendations.isEmpty {
                sections.append(.recommendations(items: mapToMediaItems(recommendations)))
            }
            // else: no section (matches SwiftUI's silent dropout when the
            // user has enabled recs but the service returned nothing).
        }

        return sections
    }

    /// Library-mode section assembly: hero (from the library's own hubs) +
    /// one row per library hub, in Plex's order — its Continue Watching,
    /// Recently Added/Released, genre rows, etc. No watchlist row, no
    /// recommendations. Rows reuse the home's hub pipeline verbatim, so they
    /// get `mergedItems` pagination (hubKey) for free.
    private func computeLibrarySections(libraryKey key: String, libraryTitle: String) -> [HomeSectionData] {
        var sections: [HomeSectionData] = []

        if showHomeHero {
            if !heroItems.isEmpty {
                sections.append(.hero(items: heroItems))
            } else if heroState == .loading {
                sections.append(.hero(items: []))
            }
        }

        // Library hub rows come from the per-library MediaItem projection
        // (`dataStore.libraryItemsByKey[key]`), mirroring computeLibrarySections'
        // old row set 1:1 (one row per library hub in Plex's order, de-duped by
        // hub identity, hero/sort-header/grid excluded). No PlexMetadata
        // materialized here.
        //
        // Row visibility gates ("Recent Rows" / "Discovery Rows"). Applied here,
        // at render time, and never in `projectLibraryItems` — that writes the
        // on-disk rail, so filtering there would persist a UI preference and a
        // later toggle-on would repaint from the pruned cache.
        let showRecentRows = (UserDefaults.standard.object(forKey: "showLibraryRecentRows") as? Bool) ?? true
        let showDiscoveryRows = (UserDefaults.standard.object(forKey: "showLibraryRecommendations") as? Bool) ?? true

        for hub in dataStore.libraryItemsByKey[key] ?? [] {
            if !showRecentRows, isRecentRow(hub) { continue }
            if !showDiscoveryRows, !isEssentialRow(hub) { continue }
            let id = HomeSectionID(raw: hub.id)
            let merged = mergedItems(forSection: id, initial: hub.items)
            var items = merged.items
            if hub.isContinueWatching, !pendingCWRemovals.isEmpty {
                items.removeAll { pendingCWRemovals.contains($0.ref.itemID) }
            }
            sections.append(.hub(
                id: id,
                title: hub.title,
                items: items,
                isContinueWatching: hub.isContinueWatching,
                hubKey: hub.hubKey,
                hubIdentifier: hub.hubIdentifier,
                totalSize: merged.totalSize ?? hub.totalSize
            ))
        }

        // Below the hub rows: the sort header (library title + count + sort
        // button) and the whole-library poster grid. Always present so the
        // header renders while the grid's first page is still in flight (an
        // empty grid section lays out at zero height). gridItems is the
        // network-loaded PlexMetadata store; map to MediaItem for the cell.
        sections.append(.sortHeader(title: libraryTitle))
        sections.append(.grid(items: mapToMediaItems(gridItems)))

        return sections
    }

    /// A "recent" library row: Recently Added, Recently Released, Newest
    /// Releases. Gated by the "Recent Rows" setting.
    private func isRecentRow(_ hub: CachedHomeHub) -> Bool {
        let id = (hub.hubIdentifier ?? "").lowercased()
        let title = hub.title.lowercased()
        return id.contains("recentlyadded") || title.contains("recently added")
            || id.contains("recentlyreleased") || title.contains("recently released")
            || id.contains("newestreleases") || title.contains("newest releases")
    }

    /// An "essential" library row: Continue Watching / On Deck, the recent rows,
    /// or Recently Played (music). Everything else is a discovery row (genre,
    /// studio, director, Rediscover, …) and is gated by "Discovery Rows".
    /// Continue Watching is not re-detected here — `CachedHomeHub` already
    /// carries the flag the CW cell and metrics run on.
    private func isEssentialRow(_ hub: CachedHomeHub) -> Bool {
        if hub.isContinueWatching || isRecentRow(hub) { return true }
        let id = (hub.hubIdentifier ?? "").lowercased()
        return id.contains("recentlyplayed") || hub.title.lowercased().contains("recently played")
    }

    /// A library's own "Continue Watching" hub, detected by identifier/title
    /// (Plex labels it `inProgress`/`continueWatching` depending on server).
    private func isContinueWatchingHub(_ hub: PlexHub) -> Bool {
        let identifier = (hub.hubIdentifier ?? "").lowercased()
        if identifier.contains("continue") || identifier.contains("inprogress") || identifier.contains("ondeck") {
            return true
        }
        return (hub.title ?? "").lowercased().contains("continue")
    }

    /// For a section with pagination state, return the merged item list
    /// (initial items + everything paginated in) and the current total
    /// size if known. If the state dict has no entry yet, seed it. Operates
    /// on `[MediaItem]`, deduping by `ref.itemID` (Stage 2).
    private func mergedItems(forSection id: HomeSectionID, initial: [MediaItem])
    -> (items: [MediaItem], totalSize: Int?) {
        if var state = paginationStates[id] {
            // The fresh projection is ALWAYS the authoritative head; only
            // paginated-in extras survive from the accumulated state. A hub
            // refresh can reorder items or advance their viewOffset without
            // changing the item SET — the old "rebuild only when initial has
            // unseen items" subset check treated that as no-change and kept
            // rendering the stale accumulated copy, which froze Continue
            // Watching's order and progress no matter how fresh the data
            // store was.
            let initialKeys = Set(initial.map { $0.ref.itemID })
            // An extra survives only if it was actually paginated in AND the
            // head doesn't cover it now. Items the head has since absorbed
            // are head-owned from here on — drop them from paginatedKeys so
            // they can't resurrect at the tail after later falling out.
            state.paginatedKeys.subtract(initialKeys)
            let paginatedExtras = state.loadedItems.filter { item in
                state.paginatedKeys.contains(item.ref.itemID)
            }
            state.loadedItems = initial + paginatedExtras
            paginationStates[id] = state
            return (state.loadedItems, state.totalSize)
        } else {
            paginationStates[id] = PaginationState(
                loadedItems: initial,
                totalSize: nil,
                isLoadingMore: false,
                hasReachedEnd: false
            )
            return (initial, nil)
        }
    }

    /// Maps a page of Plex metadata to `[MediaItem]`, obtaining
    /// providerID/serverURL/authToken exactly as the cell/preview path does.
    /// Used by pagination appends + the library grid, which fetch pages as
    /// `[PlexMetadata]` and must convert before rendering from MediaItem.
    private func mapToMediaItems(_ metas: [PlexMetadata]) -> [MediaItem] {
        let serverURL = authManager.selectedServerURL ?? ""
        let token = authManager.selectedServerToken ?? ""
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
        return metas.map {
            PlexMediaMapper.item($0, providerID: providerID, serverURL: serverURL, authToken: token)
        }
    }

    private func isRecentlyAdded(_ hub: PlexHub) -> Bool {
        let id = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return id.contains("recentlyadded") || title.contains("recently added")
    }

    // MARK: - Hero selection

    private static let heroItemCap = 9
    private static let heroTMDBMinMatches = 3

    /// Hero slot resolution. `.loading` keeps the hero section in the
    /// snapshot as a fixed-height placeholder (spinner) so rows below never
    /// shift when the trending hero lands. `.unavailable` means TMDB and the
    /// hub fallback both resolved empty on settled hubs — the slot is given
    /// up and selection won't re-show the placeholder (a later GUID-index
    /// update or hub refresh can still apply content directly via
    /// `resolveHeroWithHubFallback` / the upgrade path).
    private enum HeroState { case idle, loading, loaded, unavailable }
    private var heroState: HeroState = .idle

    /// TMDB media type to pull the trending hero for, or nil when the current
    /// surface should not get the trending upgrade (home uses the interleaved
    /// path instead; non-video libraries get none).
    private func trendingHeroType() -> TMDBMediaType? {
        guard case .library(let key, _) = mode else { return nil }
        switch dataStore.libraries.first(where: { $0.key == key })?.type {
        case "movie": return .movie
        case "show": return .tv
        default: return nil
        }
    }

    private func selectHeroItemsIfNeeded() {
        guard showHomeHero else { return }

        // Hero source + cache slot per mode: the home draws from the global
        // hubs under the "home" cache key; a library page draws from its own
        // hubs under its library key (same scheme the SwiftUI library used).
        let cacheKey: String
        let sourceHubs: [PlexHub]
        switch mode {
        case .discover, .search:
            return  // no Plex-hub hero on these surfaces
        case .home:
            cacheKey = "home"
            sourceHubs = dataStore.hubs
        case .library(let key, _):
            cacheKey = key
            sourceHubs = dataStore.libraryHubs[key] ?? []
        }

        // Warm path: the cache only ever holds a hero this controller
        // actually applied (trending or fallback) — safe to show instantly.
        // Re-filtered on replay: both the session cache and the on-disk hero
        // were persisted under whatever library visibility was in effect when
        // they were written, so a library hidden since then would otherwise
        // keep painting from cache until the next resolve.
        if heroItems.isEmpty,
           let cached = dataStore.getCachedHeroItems(forLibrary: cacheKey),
           case let visible = heroItemsVisibleOnHome(cached),
           !visible.isEmpty {
            heroItems = visible
            heroState = .loaded
            updateBackdropForCurrentHeroItem()
            applySnapshot(animated: false)
        }

        // TMDB-first: home always; a library only when it resolves to a
        // video type. Non-video libraries have no trending source — they
        // keep the immediate hub-backed hero.
        let isTMDBEligible: Bool
        switch mode {
        case .home: isTMDBEligible = true
        case .library: isTMDBEligible = trendingHeroType() != nil
        case .discover, .search: isTMDBEligible = false
        }

        if heroItems.isEmpty {
            if isTMDBEligible {
                // Hold the hero slot with the loading placeholder until the
                // trending fetch resolves; upgradeHeroFromTMDB applies the
                // hub fallback if trending can't produce enough matches. On
                // home, wait out the launch cache paint first — the disk
                // cache may still seed the slot without any placeholder.
                if heroState == .idle, !isInitialHomeLoadPending, authManager.hasCredentials {
                    heroState = .loading
                    // The splash must not wait for a backdrop that hasn't
                    // been chosen yet — reveal with the placeholder instead.
                    markHeroReady()
                    applySnapshot(animated: false)
                }
            } else {
                let candidates = computeHubBackedHero(from: sourceHubs)
                if !candidates.isEmpty {
                    heroItems = candidates
                    heroState = .loaded
                    dataStore.cacheHeroItems(candidates, forLibrary: cacheKey)
                    updateBackdropForCurrentHeroItem()
                    applySnapshot(animated: false)
                } else if !sourceHubs.isEmpty {
                    // Hubs are loaded but none can drive a hero. Release the
                    // launch/loading gate instead of waiting for an image that
                    // will never be requested.
                    setHeroBackdrop(url: nil)
                }
            }
        }

        if isTMDBEligible {
            requestHeroUpgrade()
        }
    }

    /// Coalescing entry point for the trending-hero upgrade. Concurrent triggers
    /// join the in-flight run instead of spawning parallel ones.
    private func requestHeroUpgrade() {
        if let existing = heroUpgradeTask {
            // A run is already in flight; it will observe the latest state.
            _ = existing
            return
        }
        heroUpgradeTask = Task { [weak self] in
            await self?.upgradeHeroFromTMDB()
            self?.heroUpgradeTask = nil
        }
    }

    /// Drops hero candidates belonging to a library the user removed from Home.
    ///
    /// The home hero is fed by the account-level `/hubs` (cross-library by
    /// construction) and by `LibraryGUIDIndex` trending matches (which index
    /// every library on the server). Rivulet's shown-on-Home set is client-side
    /// UserDefaults that Plex never sees, so neither source honours it and a
    /// hidden library keeps supplying hero slides — visibly duplicated for
    /// anyone running mirrored libraries. Only `PlexMetadata` carries the
    /// section attribution, so this is the last point at which it can be
    /// applied. Fails open on an unloaded library list; see
    /// `PlexLibraryVisibilityFilter`.
    ///
    /// A library-scoped hero is already single-library, so it is left alone.
    private func heroItemsVisibleOnHome(_ items: [PlexMetadata]) -> [PlexMetadata] {
        switch mode {
        case .home:
            return PlexLibraryVisibilityFilter.filter(
                items,
                toLibraryKeys: dataStore.librariesForHomeScreen.map { $0.key }
            )
        case .library, .discover, .search:
            return items
        }
    }

    private func computeHubBackedHero(from hubs: [PlexHub]) -> [PlexMetadata] {
        // Filter first, cap second: capping first would let hidden-library
        // items consume the hero's 20 slots and starve the visible ones.
        func eligible(_ items: [PlexMetadata]) -> [PlexMetadata] {
            Array(heroItemsVisibleOnHome(items)
                .filter { $0.ratingKey != nil }
                .prefix(Self.heroItemCap))
        }

        let curatedKeywords = ["recommended", "promoted", "featured", "spotlight"]
        let curated = hubs.first { hub in
            guard let id = hub.hubIdentifier?.lowercased(),
                  hub.Metadata?.isEmpty == false else { return false }
            return curatedKeywords.contains(where: id.contains)
        }
        if let items = curated?.Metadata, !items.isEmpty {
            let candidates = eligible(items)
            if !candidates.isEmpty { return candidates }
        }

        if let firstHub = hubs.first(where: { !isRecentlyAdded($0) && ($0.Metadata?.isEmpty == false) }),
           let items = firstHub.Metadata, !items.isEmpty {
            return eligible(items)
        }
        return []
    }

    /// Pure async helper. Returns up to `cap` library items chosen from TMDB
    /// trending, filtered to items the user already owns.
    ///
    /// `type == nil` (home): interleaves Trending Movies + Trending TV,
    /// preserving today's behavior byte-for-byte. `type == .movie` / `.tv`
    /// (a typed library): fetches only that single trending section, so the
    /// hero stays pure single-type for that library.
    static func computeTMDBHero(cap: Int, type: TMDBMediaType? = nil) async -> [PlexMetadata] {
        let indexEmpty = await LibraryGUIDIndex.shared.isEmpty

        let ordered: [TMDBListItem]
        switch type {
        case nil:
            async let movies = TMDBDiscoverService.shared.fetchSection(.movieTrending)
            async let shows = TMDBDiscoverService.shared.fetchSection(.tvTrending)
            let (m, s) = await (movies, shows)
            homeUIKitLog.debug("[Hero] computeTMDBHero(type: nil): trendingMovies=\(m.count, privacy: .public), trendingTV=\(s.count, privacy: .public), guidIndexEmpty=\(indexEmpty, privacy: .public)")

            // Interleave [m0, s0, m1, s1, ...] preserving TMDB's trending order.
            var interleaved: [TMDBListItem] = []
            let count = max(m.count, s.count)
            for i in 0..<count {
                if i < m.count { interleaved.append(m[i]) }
                if i < s.count { interleaved.append(s[i]) }
            }
            ordered = interleaved
        case .movie:
            let m = await TMDBDiscoverService.shared.fetchSection(.movieTrending)
            homeUIKitLog.debug("[Hero] computeTMDBHero(type: movie): trendingMovies=\(m.count, privacy: .public), guidIndexEmpty=\(indexEmpty, privacy: .public)")
            ordered = m
        case .tv:
            let s = await TMDBDiscoverService.shared.fetchSection(.tvTrending)
            homeUIKitLog.debug("[Hero] computeTMDBHero(type: tv): trendingTV=\(s.count, privacy: .public), guidIndexEmpty=\(indexEmpty, privacy: .public)")
            ordered = s
        }

        var matches: [PlexMetadata] = []
        for item in ordered {
            if let plex = await LibraryGUIDIndex.shared.lookup(tmdbId: item.id, type: item.mediaType) {
                matches.append(plex)
                if matches.count >= cap { break }
            }
        }
        let matchTitles = matches.map { "\($0.title ?? "?") [\($0.type ?? "?")]" }.joined(separator: ", ")
        homeUIKitLog.debug("[Hero] computeTMDBHero: \(ordered.count, privacy: .public) trending items -> \(matches.count, privacy: .public) matches (cap=\(cap, privacy: .public)): \(matchTitles, privacy: .public)")
        return matches
    }

    @MainActor
    private func upgradeHeroFromTMDB() async {
        guard showHomeHero else {
            homeUIKitLog.debug("[Hero] upgradeHeroFromTMDB skipped: showHomeHero=false")
            return
        }

        let cacheKey: String
        let heroType: TMDBMediaType?  // nil == home's interleaved movies+TV path
        switch mode {
        case .home:
            cacheKey = "home"
            heroType = nil
        case .library(let key, _):
            // A typed library must resolve to a concrete type; a non-video
            // library (nil) is not eligible and must bail here so the home
            // interleave path never runs on it.
            // Libraries may not have loaded yet (type resolves to nil); reset so a
            // later trigger, once libraries load, can re-attempt at this generation.
            guard let t = trendingHeroType() else { lastUpgradedIndexGeneration = -1; return }
            cacheKey = key
            heroType = t
        case .discover, .search:
            return
        }

        // Skip if the GUID index hasn't changed since the last completed run.
        // The upgrade is triggered from many sites; between the disk-hydrate and
        // the network refresh the index is identical, so recomputing (2 cached
        // fetches + 40 lookups) would be pure waste. A waiting placeholder (or a
        // slot given up before its hubs loaded) still gets its hub fallback
        // retried — hubs may have landed since the last run.
        let generation = await LibraryGUIDIndex.shared.generation
        guard generation != lastUpgradedIndexGeneration else {
            homeUIKitLog.debug("[Hero] upgradeHeroFromTMDB skipped: index generation \(generation, privacy: .public) unchanged")
            resolveHeroWithHubFallback(cacheKey: cacheKey)
            return
        }
        lastUpgradedIndexGeneration = generation

        homeUIKitLog.debug("[Hero] upgradeHeroFromTMDB: starting (gen=\(generation, privacy: .public), current heroItems=\(self.heroItems.count, privacy: .public))")
        // `LibraryGUIDIndex` indexes every library on the server, so a trending
        // match can resolve to a title in a library the user removed from Home.
        // (Which of two mirrored copies the index returns is a separate
        // problem; this only drops copies that are hidden outright.)
        let curated = heroItemsVisibleOnHome(
            await Self.computeTMDBHero(cap: Self.heroItemCap, type: heroType)
        )
        guard curated.count >= Self.heroTMDBMinMatches else {
            homeUIKitLog.debug("[Hero] upgradeHeroFromTMDB bailed: only \(curated.count, privacy: .public) matches (need \(Self.heroTMDBMinMatches, privacy: .public))")
            // A later index generation may yield enough matches; allow re-run.
            lastUpgradedIndexGeneration = -1
            resolveHeroWithHubFallback(cacheKey: cacheKey)
            return
        }

        // Persist the pure trending list, not the merge below: the merge can
        // carry over the currently-visible slide for in-session continuity,
        // and persisting that would make a stale slide immortal across
        // launches (each launch re-preserves index 0 of the cache). Runs
        // before the no-op guard so the cache heals even when the displayed
        // carousel doesn't change.
        persistHeroItems(curated, cacheKey: cacheKey)

        // Preserve currently-visible item if it's in the curated set.
        let mergedItems: [PlexMetadata]
        if !heroItems.isEmpty {
            let clamped = max(0, min(heroCurrentIndex, heroItems.count - 1))
            let current = heroItems[clamped]
            if let currentKey = current.ratingKey,
               curated.contains(where: { $0.ratingKey == currentKey }) {
                let withoutCurrent = curated.filter { $0.ratingKey != currentKey }
                let targetIndex = max(0, min(heroCurrentIndex, withoutCurrent.count))
                var rotated = withoutCurrent
                rotated.insert(current, at: targetIndex)
                mergedItems = rotated
            } else if let _ = current.ratingKey {
                var merged: [PlexMetadata] = [current]
                let currentKey = current.ratingKey
                for item in curated where item.ratingKey != currentKey {
                    merged.append(item)
                }
                mergedItems = Array(merged.prefix(Self.heroItemCap))
                if heroCurrentIndex != 0 { heroCurrentIndex = 0 }
            } else {
                mergedItems = curated
            }
        } else {
            mergedItems = curated
        }

        let newKeys = mergedItems.compactMap { $0.ratingKey }
        let currentKeys = heroItems.compactMap { $0.ratingKey }
        guard newKeys != currentKeys else {
            homeUIKitLog.debug("[Hero] upgradeHeroFromTMDB no-op: merged hero identical to current (\(newKeys.count, privacy: .public) items)")
            return
        }

        homeUIKitLog.info("[Hero] upgradeHeroFromTMDB APPLIED: replacing hero with \(mergedItems.count, privacy: .public) trending-matched items")
        heroItems = mergedItems
        heroState = .loaded
        updateBackdropForCurrentHeroItem()
        applySnapshot(animated: false)
        // The hero cell's diffable item id is a constant ("hero-overlay"), so
        // applySnapshot alone never re-vends it — the cell keeps rendering the
        // items it was first configured with. Force a reconfigure so it picks
        // up the swapped heroItems.
        reconfigureHeroCell()
    }

    /// TMDB couldn't produce enough owned matches (cold GUID index, TMDB
    /// unreachable, small library). If the placeholder is holding the hero
    /// slot — or the slot was given up before its hubs loaded — resolve it
    /// with the hub-backed fallback. When hubs are settled and can't drive a
    /// hero either, give the slot up so the placeholder doesn't spin forever.
    private func resolveHeroWithHubFallback(cacheKey: String) {
        guard heroState == .loading || heroState == .unavailable,
              heroItems.isEmpty else { return }
        let sourceHubs: [PlexHub]
        switch mode {
        case .home: sourceHubs = dataStore.hubs
        case .library(let key, _): sourceHubs = dataStore.libraryHubs[key] ?? []
        case .discover, .search: return
        }
        let fallback = computeHubBackedHero(from: sourceHubs)
        if !fallback.isEmpty {
            homeUIKitLog.info("[Hero] hub fallback APPLIED: \(fallback.count, privacy: .public) items")
            heroItems = fallback
            heroState = .loaded
            persistHeroItems(fallback, cacheKey: cacheKey)
            updateBackdropForCurrentHeroItem()
            applySnapshot(animated: false)
        } else if heroState == .loading, !sourceHubs.isEmpty || !dataStore.isLoadingHubs {
            // Hubs settled and no hero content anywhere. Collapse the slot
            // and release the splash's backdrop wait.
            homeUIKitLog.debug("[Hero] no trending matches and no hub fallback; hero unavailable")
            heroState = .unavailable
            setHeroBackdrop(url: nil)
            applySnapshot(animated: false)
        }
        // else: hubs still loading — stay on the placeholder; the hubsVersion
        // observer re-runs selection + the upgrade when they land.
    }

    /// Cache the hero that was actually applied. The session cache seeds
    /// same-session revisits; the home surface also persists to disk so the
    /// next launch paints the real hero instantly instead of re-resolving.
    private func persistHeroItems(_ items: [PlexMetadata], cacheKey: String) {
        dataStore.cacheHeroItems(items, forLibrary: cacheKey)
        if cacheKey == "home" {
            Task { await CacheManager.shared.cacheHomeHeroItems(items) }
        }
    }

    /// Re-vend the single hero cell after `heroItems` changes. Needed because the
    /// hero item identifier is constant across snapshots (see `applySnapshot`).
    private func reconfigureHeroCell() {
        var snap = dataSource.snapshot()
        guard snap.sectionIdentifiers.contains(.hero) else { return }
        snap.reconfigureItems([HomeItemID(sectionID: .hero, itemID: "hero-overlay")])
        dataSource.apply(snap, animatingDifferences: false)
    }

    // MARK: - Recommendations

    @MainActor
    private func refreshRecommendations(force: Bool) async {
        guard enablePersonalizedRecommendations else { return }
        if force || recommendations.isEmpty { isLoadingRecommendations = true }
        recommendationsError = nil

        do {
            let items = try await recommendationService.recommendations(
                forceRefresh: force,
                contentType: .moviesAndShows
            )
            recommendations = items
            isLoadingRecommendations = false
            applySnapshot(animated: false)
        } catch {
            recommendations = []
            recommendationsError = error.localizedDescription
            isLoadingRecommendations = false
            applySnapshot(animated: false)
        }
    }

    // MARK: - Direct play

    /// MediaItem entry point for Continue-Watching play (tile tap + the CW
    /// context menu's "Watch from Beginning"). The home now renders rows from
    /// MediaItem, but the player VM + resume flow genuinely need a PlexMetadata
    /// (Stage 4 keeps direct-play on PlexMetadata). We resolve the metadata
    /// lazily by ratingKey — the same escape hatch the preview carousel uses at
    /// play — then forward to the existing PlexMetadata flow. The resume-or-
    /// restart decision is driven off the MediaItem so the prompt appears
    /// instantly without waiting on the metadata fetch.
    private func playItem(_ item: MediaItem, fromBeginning: Bool = false) {
        let ratingKey = item.ref.itemID
        guard !ratingKey.isEmpty,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Resume prompt: gate on the MediaItem's own progress, then resolve
        // the metadata for the chosen branch.
        let offsetSec = item.userState.viewOffset
        if promptResumeOrRestart, !fromBeginning, item.isInProgress, offsetSec > 0 {
            presentResumeChoice(forMediaItem: item, offsetSec: offsetSec)
            return
        }

        Task { @MainActor in
            guard let meta = try? await PlexNetworkManager.shared.getFullMetadata(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            ) else { return }
            playItemDirectly(meta, fromBeginning: fromBeginning)
        }
    }

    /// Resume-or-restart prompt driven by a MediaItem (CW play path). Resolves
    /// PlexMetadata lazily inside the chosen action so the prompt itself never
    /// blocks on the network.
    private func presentResumeChoice(forMediaItem item: MediaItem, offsetSec: TimeInterval) {
        let offsetMs = Int(offsetSec * 1000)
        let alert = UIAlertController(
            title: "Resume Playback?",
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Resume from \(PlexMetadata.formatResumeTime(offsetMs))", style: .default) { [weak self] _ in
            self?.resolveAndPlay(item, fromBeginning: false)
        })
        alert.addAction(UIAlertAction(title: "Start from Beginning", style: .default) { [weak self] _ in
            self?.resolveAndPlay(item, fromBeginning: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Resolve a MediaItem to PlexMetadata by ratingKey and play it, bypassing
    /// the resume prompt (the caller already made the resume/restart choice).
    private func resolveAndPlay(_ item: MediaItem, fromBeginning: Bool) {
        let ratingKey = item.ref.itemID
        guard !ratingKey.isEmpty,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        Task { @MainActor in
            guard let meta = try? await PlexNetworkManager.shared.getFullMetadata(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            ) else { return }
            presentPlayer(for: meta, fromBeginning: fromBeginning)
        }
    }

    /// Mirrors the SwiftUI `playItemDirectly` flow including the
    /// resume-or-restart prompt (when `promptResumeOrRestart` is on).
    private func playItemDirectly(_ item: PlexMetadata, fromBeginning: Bool = false) {
        if promptResumeOrRestart,
           !fromBeginning,
           item.isInProgress,
           let offsetMs = item.viewOffset, offsetMs > 0 {
            presentResumeChoice(for: item, offsetMs: offsetMs)
        } else {
            presentPlayer(for: item, fromBeginning: fromBeginning)
        }
    }

    private func presentResumeChoice(for item: PlexMetadata, offsetMs: Int) {
        let alert = UIAlertController(
            title: "Resume Playback?",
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Resume from \(PlexMetadata.formatResumeTime(offsetMs))", style: .default) { [weak self] _ in
            self?.presentPlayer(for: item, fromBeginning: false)
        })
        alert.addAction(UIAlertAction(title: "Start from Beginning", style: .default) { [weak self] _ in
            self?.presentPlayer(for: item, fromBeginning: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func presentPlayer(for item: PlexMetadata, fromBeginning: Bool) {
        Task { @MainActor in
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }

            let request = item.heroBackdropRequest(serverURL: serverURL, authToken: token)
            let (artImage, thumbImage) = await HeroBackdropResolver.shared.playerLoadingImages(for: request)

            let resumeOffset: Double? = fromBeginning ? nil : item.viewOffset.map { Double($0) / 1000.0 }
            let viewModel = UniversalPlayerViewModel(
                metadata: item,
                serverURL: serverURL,
                authToken: token,
                startOffset: (resumeOffset ?? 0) > 0 ? resumeOffset : nil,
                loadingArtImage: artImage,
                loadingThumbImage: thumbImage
            )
            let playerVC = PlayerPresenter.makeViewController(viewModel: viewModel, onDismiss: { [weak self] in
                Task { await self?.dataStore.refreshHubs() }
            })

            // Walk up to the topmost presented controller so we don't try to
            // present from a stale parent (covers re-entry after dismiss).
            var topVC: UIViewController = self
            while let presented = topVC.presentedViewController { topVC = presented }
            topVC.present(playerVC, animated: true)
        }
    }

    // MARK: - Selection / navigation

    /// Tile-tap router. Continue Watching tiles play directly; other tiles
    /// open the preview carousel. Hero buttons route through their own
    /// callbacks (`onInfo` -> `selectPlexItem`, `onPlay` -> `playItemDirectly`).
    private func handleTap(at indexPath: IndexPath) {
        guard indexPath.section < sectionsSnapshot.count else { return }
        let section = sectionsSnapshot[indexPath.section]

        // Ignore taps on the skeleton placeholder.
        if let itemID = dataSource.itemIdentifier(for: indexPath),
           itemID.itemID == HomeItemID.skeletonSentinel {
            return
        }

        switch section.kind {
        case .hero, .recommendationsLoading, .recommendationsError:
            return  // hero overlay + state cells handle their own input
        case .sortHeader:
            return  // the embedded SortButton handles its own Select press
        case .searchPrompt, .searchState:
            return  // recents pills / Try Again are FocusableActionButtons
        case .continueWatching, .recentlyAdded, .recommendations, .watchlist, .discoverList, .searchGrid:
            return  // shelf rows route taps through their own delegate (handleShelfTap)
        case .grid:
            guard indexPath.item < section.items.count else { return }
            presentPreview(forSection: section, indexPath: indexPath)
        }
    }


    /// Navigate to detail for a MediaItem (tile-menu "More Info" /
    /// "Go to …") — always the UIKit surfaces: episodes get the episode
    /// detail page, everything else the standalone expanded detail (the
    /// same page a hero Info press opens). The SwiftUI detail stack is not
    /// used from the tile menu.
    private func selectMediaItem(_ item: MediaItem) {
        if item.kind == .episode {
            let page = MediaItemDetailPageViewController(
                item: item,
                seriesTitle: nil,
                onPlay: { [weak self] episode in self?.playItem(episode) })
            present(page, animated: true)
        } else {
            presentStandaloneExpandedDetail(item)
        }
    }

    /// Open the new UIKit detail page (`MediaItemDetailPageViewController`) for a
    /// hero item — the hero Info ("i") button. Mirrors how the carousel presents
    /// the same page. Play inside the page closes it first, then routes to the
    /// hero's normal play flow (so the player / resume prompt isn't presented
    /// underneath the detail page).
    /// Hero Info (all modes): the FULL expanded detail presented standalone —
    /// the same surface the carousel's Related drill-ins open (one item,
    /// already expanded, Menu dismisses, no collapse back to a carousel).
    private func presentDetailPage(for meta: PlexMetadata) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
        let item = PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
        presentStandaloneExpandedDetail(item)
    }

    /// Standalone expanded detail (mirror of PreviewCarouselViewController's
    /// presentStandaloneDetail, hoisted for the hero Info buttons).
    private func presentStandaloneExpandedDetail(_ item: MediaItem) {
        let detail = PreviewCarouselViewController(
            items: [item],
            selectedIndex: 0,
            sourceFrame: .zero,
            sourceTarget: nil,
            standaloneDetail: true,
            onDismiss: { _ in })
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(detail, animated: true)
    }

    private func playMusicTrack(_ plexMeta: PlexMetadata) {
        guard let provider = MusicProviderRegistry.shared.primaryProvider,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let track = PlexMusicMapper.track(plexMeta, providerID: provider.id, serverURL: serverURL, authToken: token)
        MusicQueue.shared.playNow(track: track)
    }

    // MARK: - Preview presentation

    private func presentPreview(forSection section: HomeSectionData, indexPath: IndexPath) {
        guard indexPath.item < section.items.count else { return }
        let mediaItems = section.items
        let tapped = mediaItems[indexPath.item]
        let sourceItemID = tapped.ref.itemID.isEmpty
            ? "\(section.id.raw)-\(indexPath.item)"
            : tapped.ref.itemID

        presentPreviewOverlay(
            items: mediaItems,
            selectedIndex: indexPath.item,
            sourceRowID: section.id.raw,
            sourceItemID: sourceItemID,
            sourceIndexPath: indexPath,
            sourceItemIDs: sourceItemIDs(for: section)
        )
    }

    private func openWatchlistPreview(section: HomeSectionData, tappedIndex: Int, indexPath: IndexPath) async {
        let entries = section.watchlistItems
        let pairs = await buildWatchlistMediaItems(from: entries)
        guard !pairs.isEmpty else { return }

        let tapped = entries[tappedIndex]
        // Match on the originating watchlist entry id — robust across both
        // library-matched (Plex ratingKey) and TMDB-only itemID encodings,
        // and tolerant of entries that get skipped during mapping. Mirrors
        // SwiftUI WatchlistHubRow's tap-resolution fix (commit `bb15fdb`).
        let validIndex = pairs.firstIndex(where: { $0.sourceID == tapped.id }) ?? 0
        let mediaItems = pairs.map(\.item)
        let sourceItemIDs = pairs.map(\.sourceID)
        var sourceIndexMap: [Int: Int] = [:]
        for (previewIndex, pair) in pairs.enumerated() {
            if let sourceIndex = entries.firstIndex(where: { $0.id == pair.sourceID }) {
                sourceIndexMap[sourceIndex] = previewIndex
            }
        }
        presentPreviewOverlay(
            items: mediaItems,
            selectedIndex: validIndex,
            sourceRowID: section.id.raw,
            sourceItemID: tapped.id,
            sourceIndexPath: indexPath,
            sourceIndexMap: sourceIndexMap,
            sourceItemIDs: sourceItemIDs
        )
    }

    /// Mirrors `WatchlistHubRow.buildMediaItems(from:)` — parallel library
    /// lookups against the GUID index, with TMDB fallback for unmatched
    /// entries. Returns `(sourceID, item)` pairs so callers can match on
    /// the originating watchlist entry id (see `openWatchlistPreview`).
    private func buildWatchlistMediaItems(from entries: [PlexWatchlistItem]) async -> [(sourceID: String, item: MediaItem)] {
        let serverURL = authManager.selectedServerURL ?? ""
        let token = authManager.selectedServerToken ?? ""
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"

        // Resolve each watchlist (Discover) item to the owned local library item so the detail shows
        // Play + server art instead of a non-playable TMDB stub (issue #188). Two layers:
        //
        //   1. Warm path — the in-memory LibraryGUIDIndex, matching on ANY external guid the index
        //      holds (type-safe tmdb first, then imdb/tvdb). No network when the bulk index is loaded.
        //   2. Cold path — the bulk index loads ~20s after launch (and not at all on the very first
        //      launch before that fetch finishes), so until then every index lookup misses. The
        //      server does NOT index external guids for /library/all?guid=, but it DOES match the
        //      primary plex:// guid, which Plex shares between Discover and the local server for
        //      agent-matched titles. Resolve that directly so ownership works on cold/first launch.
        let lookups = await withTaskGroup(of: (Int, PlexMetadata?).self) { group in
            for (index, entry) in entries.enumerated() {
                let guids = entry.guids
                let tmdbId = entry.tmdbId
                let tmdbType: TMDBMediaType = entry.type == .movie ? .movie : .tv
                let plexGUID = entry.plexGUID
                group.addTask {
                    // Warm path: in-memory index. Type-safe tmdb first (a movie and a show can share
                    // the same numeric tmdb id), then imdb/tvdb guids, which are globally unique.
                    if let tmdbId,
                       let match = await LibraryGUIDIndex.shared.lookup(tmdbId: tmdbId, type: tmdbType) {
                        return (index, match)
                    }
                    for guid in guids where !guid.hasPrefix("tmdb://") {
                        if let match = await LibraryGUIDIndex.shared.lookup(guid: guid) {
                            return (index, match)
                        }
                    }
                    // Cold path: resolve the primary plex:// guid against the server directly.
                    if let plexGUID, !serverURL.isEmpty,
                       let match = try? await PlexNetworkManager.shared.findByGuid(
                        serverURL: serverURL, authToken: token, guid: plexGUID) {
                        return (index, match)
                    }
                    return (index, nil)
                }
            }
            var out: [Int: PlexMetadata] = [:]
            for await (index, match) in group {
                if let match { out[index] = match }
            }
            return out
        }

        // Enrich every item with its TMDB title logo (the same source Discover uses), and for un-owned
        // items also fetch the TMDB landscape backdrop. The UIKit preview carousel renders artwork
        // as-is (it does not enrich items the way Discover's PreviewOverlayHost does), so the logo —
        // and, for un-owned items, the backdrop — must be present on the MediaItem before it is shown.
        // Owned items already carry server art; their list-level metadata lacks a clearLogo, so the
        // TMDB logo fills that gap (withLogoIfMissing never overwrites a real Plex logo). Network runs
        // off the main actor; MediaItems are built on it.
        let tmdbSource = MetadataSourceRegistry.shared.source(for: TMDBMediaMapper.providerID)
        let enriched: [Int: (item: MediaItem?, logo: URL?)] = await withTaskGroup(
            of: (Int, MediaItem?, URL?).self
        ) { group in
            for (index, entry) in entries.enumerated() {
                guard let tmdbId = entry.tmdbId else { continue }
                let mediaType: TMDBMediaType = entry.type == .movie ? .movie : .tv
                let isOwned = lookups[index] != nil && !serverURL.isEmpty
                // Build the ref on the main actor (TMDBMediaMapper is main-actor-isolated); the task
                // only does the off-actor network work.
                let ref = MediaItemRef(
                    providerID: TMDBMediaMapper.providerID,
                    itemID: TMDBMediaMapper.encodeItemID(tmdbId: tmdbId, type: mediaType))
                group.addTask {
                    async let logoTask = TMDBLogoCache.shared.logoURL(tmdbId: tmdbId, type: mediaType)
                    // Owned items already have a server backdrop; only un-owned need the TMDB detail.
                    let detail = isOwned ? nil : (try? await tmdbSource?.itemDetail(ref))
                    let logo = await logoTask
                    return (index, detail?.item, logo)
                }
            }
            var out: [Int: (item: MediaItem?, logo: URL?)] = [:]
            for await (index, item, logo) in group {
                out[index] = (item, logo)
            }
            return out
        }

        var result: [(sourceID: String, item: MediaItem)] = []
        result.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            // Owned: real Plex item, with the TMDB logo filled in if the server metadata had none.
            if let match = lookups[index], !serverURL.isEmpty {
                let plexItem = PlexMediaMapper.item(match,
                                                    providerID: providerID,
                                                    serverURL: serverURL,
                                                    authToken: token)
                result.append((sourceID: entry.id, item: plexItem.withLogoIfMissing(enriched[index]?.logo)))
                continue
            }

            // Un-owned: needs a tmdb id to address TMDB.
            guard let tmdbId = entry.tmdbId else { continue }
            let logo = enriched[index]?.logo

            // Prefer the TMDB-enriched item (real landscape backdrop + poster), matching Discover.
            if let pair = enriched[index], let enrichedItem = pair.item {
                result.append((sourceID: entry.id, item: enrichedItem.withLogoIfMissing(pair.logo)))
                continue
            }

            // Enrichment failed (e.g. offline): keep the Plex watchlist poster so the tile still has
            // art, and splice the logo if we got one.
            let mediaType: TMDBMediaType = entry.type == .movie ? .movie : .tv
            let base = TMDBMediaMapper.item(TMDBListItem(
                id: tmdbId,
                title: entry.title,
                overview: nil,
                posterPath: nil,
                backdropPath: nil,
                releaseDate: entry.year.map { "\($0)" },
                voteAverage: nil,
                mediaType: mediaType
            ))
            let stub: MediaItem
            if let poster = entry.posterURL {
                stub = MediaItem(
                    ref: base.ref,
                    kind: base.kind,
                    title: base.title,
                    sortTitle: base.sortTitle,
                    overview: base.overview,
                    year: base.year,
                    releaseDate: base.releaseDate,
                    contentRating: base.contentRating,
                    runtime: base.runtime,
                    parentRef: base.parentRef,
                    grandparentRef: base.grandparentRef,
                    episodeNumber: base.episodeNumber,
                    seasonNumber: base.seasonNumber,
                    childProgress: base.childProgress,
                    userState: base.userState,
                    artwork: MediaArtwork(
                        poster: poster,
                        backdrop: base.artwork.backdrop,
                        thumbnail: poster,
                        logo: base.artwork.logo
                    ),
                    parentArtwork: base.parentArtwork,
                    grandparentArtwork: base.grandparentArtwork
                )
            } else {
                stub = base
            }
            result.append((sourceID: entry.id, item: stub.withLogoIfMissing(logo)))
        }
        return result
    }

    /// Warms TMDB detail + logo caches for un-owned watchlist items so that
    /// the first tap produces instant backdrop/logo rather than a network round-trip.
    /// Fired whenever the watchlist items list changes (typically on fetch completion
    /// or user add/remove). Runs in the background; failures are silent (the tap
    /// handler will retry via its own enrichment fetch).
    private func prewarmWatchlistArtwork(_ entries: [PlexWatchlistItem]) {
        Task.detached(priority: .background) {
            await withTaskGroup(of: Void.self) { group in
                for entry in entries {
                    guard let tmdbId = entry.tmdbId else { continue }
                    let mediaType: TMDBMediaType = entry.type == .movie ? .movie : .tv
                    group.addTask {
                        async let detail: TMDBItemDetail? = TMDBDiscoverService.shared.fetchDetail(tmdbId: tmdbId, type: mediaType)
                        async let logo: URL? = TMDBLogoCache.shared.logoURL(tmdbId: tmdbId, type: mediaType)
                        _ = await (detail, logo)
                    }
                }
            }
        }
    }

    private func presentPreviewOverlay(
        items: [MediaItem],
        selectedIndex: Int,
        sourceRowID: String,
        sourceItemID: String,
        sourceIndexPath: IndexPath,
        sourceIndexMap: [Int: Int]? = nil,
        sourceItemIDs: [String]? = nil
    ) {
        // Capture the source cell's frame in window coordinates so the
        // entry-morph has something to interpolate from.
        var sourceFrames: [PreviewSourceTarget: CGRect] = [:]
        let sourceTarget = PreviewSourceTarget(rowID: sourceRowID, itemID: sourceItemID)
        if let inWindow = tileFrameInWindow(at: sourceIndexPath) {
            sourceFrames[sourceTarget] = inWindow
        }
        let entrySnapshots = previewEntrySnapshots(
            at: sourceIndexPath,
            itemIndexMap: sourceIndexMap
        )

        suppressPreviewPresentationFocusMemory()
        let carouselVC = PreviewCarouselViewController(
            items: items,
            selectedIndex: selectedIndex,
            sourceFrame: sourceFrames[sourceTarget] ?? .zero,
            sourceTarget: sourceTarget,
            entrySnapshots: entrySnapshots,
            sourceItemIDs: sourceItemIDs,
            onPrepareDismiss: { [weak self] sourceTarget in
                self?.preparePreviewRestoreForPendingDismiss(sourceTarget)
            },
            onDismiss: { [weak self] sourceTarget in
                if let sourceTarget {
                    self?.pendingPreviewRestore = sourceTarget
                }
                self?.applyPendingPreviewRestoreIfNeeded()
            }
        )
        var topVC: UIViewController = self
        while let presented = topVC.presentedViewController { topVC = presented }
        // animated: false — the carousel's spring morph IS the
        // transition. Modal transitions would compose on top.
        topVC.present(carouselVC, animated: false) { [weak self] in
            self?.resetVisibleFocusAppearance(except: nil)
        }
    }

    // MARK: - Focus restoration after preview dismiss

    private func suppressPreviewPresentationFocusMemory() {
        if collectionView.remembersLastFocusedIndexPath {
            shouldRestoreCollectionFocusMemoryAfterPreview = true
            collectionView.remembersLastFocusedIndexPath = false
        }
    }

    private func preparePreviewRestoreForPendingDismiss(_ target: PreviewSourceTarget?) {
        guard let target else { return }
        pendingPreviewRestore = target
        if collectionView.remembersLastFocusedIndexPath {
            shouldRestoreCollectionFocusMemoryAfterPreview = true
            collectionView.remembersLastFocusedIndexPath = false
        }
        _ = preparePreviewRestoreLayout(for: target, routeFocus: false)
        resetVisibleFocusAppearance(except: target)
    }

    private func applyPendingPreviewRestoreIfNeeded() {
        guard let target = pendingPreviewRestore else { return }
        guard preparePreviewRestoreLayout(for: target, routeFocus: true) else {
            finishPendingPreviewRestore()
            return
        }
        // Defer to next runloop so the preview-dismiss layout pass finishes
        // before we ask the focus engine to update.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.pendingPreviewRestore == target else { return }
            guard self.preparePreviewRestoreLayout(for: target, routeFocus: true) else {
                self.finishPendingPreviewRestore()
                return
            }
            self.resetVisibleFocusAppearance(except: target)
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            self.finishPendingPreviewRestore()
        }
    }

    @discardableResult
    private func preparePreviewRestoreLayout(for target: PreviewSourceTarget, routeFocus: Bool) -> Bool {
        guard let indexPath = indexPath(for: target) else { return false }
        UIView.performWithoutAnimation {
            if indexPath.section < sectionsSnapshot.count,
               isShelfKind(sectionsSnapshot[indexPath.section].kind) {
                // Shelf rows: the outer item is the full-width row; the tile
                // lives in the row's own collection view. Bring both layers on
                // screen before the modal disappears so focus does not flash
                // on the old source tile or visibly jump to the new one.
                let rowPath = IndexPath(item: 0, section: indexPath.section)
                collectionView.scrollToItem(at: rowPath, at: .centeredVertically, animated: false)
                collectionView.layoutIfNeeded()
                if let row = collectionView.cellForItem(at: rowPath) as? ShelfRowCell {
                    if routeFocus {
                        row.prepareFocusRestore(on: indexPath.item)
                    } else {
                        row.prepareFocusRestoreLayout(on: indexPath.item)
                    }
                }
            } else {
                collectionView.scrollToItem(at: indexPath, at: [.centeredVertically, .centeredHorizontally], animated: false)
                collectionView.layoutIfNeeded()
            }
        }
        return true
    }

    private func resetVisibleFocusAppearance(except target: PreviewSourceTarget?) {
        let targetIndexPath = target.flatMap(indexPath(for:))
        for cell in collectionView.visibleCells {
            if let row = cell as? ShelfRowCell {
                let rowIndexPath = collectionView.indexPath(for: row)
                let targetItem = rowIndexPath?.section == targetIndexPath?.section
                    ? targetIndexPath?.item
                    : nil
                row.resetVisibleFocusAppearance(except: targetItem)
            } else {
                let indexPath = collectionView.indexPath(for: cell)
                guard indexPath != targetIndexPath else { continue }
                ShelfRowCell.clearFocusAppearance(in: cell)
            }
        }
    }

    private func finishPendingPreviewRestore() {
        pendingPreviewRestore = nil
        if shouldRestoreCollectionFocusMemoryAfterPreview {
            shouldRestoreCollectionFocusMemoryAfterPreview = false
            collectionView.remembersLastFocusedIndexPath = true
        }
    }

    /// Window-space frame of a tile, resolving through shelf rows' inner
    /// collection views (the outer index path for shelves is logical:
    /// item = tile index within the row).
    private func tileFrameInWindow(at indexPath: IndexPath) -> CGRect? {
        guard indexPath.section < sectionsSnapshot.count else { return nil }
        if isShelfKind(sectionsSnapshot[indexPath.section].kind) {
            let rowPath = IndexPath(item: 0, section: indexPath.section)
            guard let row = collectionView.cellForItem(at: rowPath) as? ShelfRowCell else { return nil }
            return row.frameInWindow(forItem: indexPath.item)
        }
        guard let attrs = collectionView.layoutAttributesForItem(at: indexPath),
              let window = view.window else { return nil }
        return collectionView.convert(attrs.frame, to: window)
    }

    private func previewEntrySnapshots(
        at indexPath: IndexPath,
        itemIndexMap: [Int: Int]? = nil
    ) -> [PreviewEntrySnapshot] {
        guard indexPath.section < sectionsSnapshot.count else { return [] }
        if isShelfKind(sectionsSnapshot[indexPath.section].kind) {
            let rowPath = IndexPath(item: 0, section: indexPath.section)
            guard let row = collectionView.cellForItem(at: rowPath) as? ShelfRowCell else { return [] }
            return row.visibleEntrySnapshots(itemIndexMap: itemIndexMap)
        }
        guard let frame = tileFrameInWindow(at: indexPath),
              let cell = collectionView.cellForItem(at: indexPath),
              let snapshot = cell.snapshotView(afterScreenUpdates: false)
        else { return [] }
        let targetIndex: Int
        if let itemIndexMap {
            guard let mappedIndex = itemIndexMap[indexPath.item] else { return [] }
            targetIndex = mappedIndex
        } else {
            targetIndex = indexPath.item
        }
        return [
            PreviewEntrySnapshot(
                itemIndex: targetIndex,
                sourceFrame: frame,
                snapshotView: snapshot
            )
        ]
    }

    private func sourceItemIDs(for section: HomeSectionData) -> [String] {
        switch section.kind {
        case .watchlist:
            return section.watchlistItems.map(\.id)
        default:
            return section.items.enumerated().map { index, item in
                item.ref.itemID.isEmpty ? "\(section.id.raw)-\(index)" : item.ref.itemID
            }
        }
    }

    private func indexPath(for target: PreviewSourceTarget) -> IndexPath? {
        guard let sectionIndex = sectionsSnapshot.firstIndex(where: { $0.id.raw == target.rowID }) else { return nil }
        let section = sectionsSnapshot[sectionIndex]
        switch section.kind {
        case .hero, .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState:
            return nil
        case .continueWatching, .recentlyAdded, .recommendations, .grid, .discoverList,
             .searchGrid:
            if let itemIndex = section.items.enumerated().first(where: { index, item in
                let sourceID = item.ref.itemID.isEmpty ? "\(section.id.raw)-\(index)" : item.ref.itemID
                return sourceID == target.itemID
            })?.offset {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        case .watchlist:
            if let itemIndex = section.watchlistItems.firstIndex(where: { $0.id == target.itemID }) {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        }
        return nil
    }

    // MARK: - Scroll-on-focus

    /// Snap the collection view to the top so the hero overlay sits at the
    /// top of the screen and the Continue Watching peek shows below.
    private func scrollHeroIntoView() {
        let targetY = -collectionView.adjustedContentInset.top
        guard collectionView.contentOffset.y != targetY else { return }
        animateContentOffset(toY: targetY)
    }

    /// Centre a row vertically so the focused tile sits roughly mid-screen.
    /// Matches the SwiftUI version's `scrollTo(rowID, anchor: .center)`.
    private func scrollSectionIntoView(sectionIndex: Int) {
        guard sectionsSnapshot.indices.contains(sectionIndex) else { return }
        // Find any layout attribute belonging to this section to derive its
        // vertical centre. Falls back to the section's first item.
        let firstItemPath = IndexPath(item: 0, section: sectionIndex)
        guard let attrs = collectionView.layoutAttributesForItem(at: firstItemPath) else { return }
        scrollToCenter(frame: attrs.frame)
    }

    /// Collapse the hero to a fixed band when focus drops to the first row.
    ///
    /// The hero is self-contained: its resting position when you leave it is a
    /// function of the HERO geometry only, never the first row's height. We
    /// scroll so a fixed-height slice of the hero's bottom (logo / metadata /
    /// action row / paging dots) stays on screen; the first row then falls
    /// just beneath it. Because the hero section height is constant, this lands
    /// at the SAME offset whether row 1 is Continue Watching or a poster row —
    /// which is what `scrollToCenter(midY)` could not do (taller row → more
    /// scroll → hero shifted up ~84pt on Discover vs home).
    private func scrollFirstRowToHeroCollapsed(heroSectionIndex: Int) {
        let heroPath = IndexPath(item: 0, section: heroSectionIndex)
        guard let heroAttrs = collectionView.layoutAttributesForItem(at: heroPath) else { return }
        // Bottom slice of the hero kept on screen. The chrome (metadata + action
        // row + dots) lives in the hero's lower ~290pt; keeping that band visible
        // reproduces the established home/Continue-Watching resting height.
        let visibleHeroBand: CGFloat = 290
        let target = heroAttrs.frame.maxY - visibleHeroBand
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        let clamped = max(-collectionView.adjustedContentInset.top, min(target, maxOffset))
        guard abs(collectionView.contentOffset.y - clamped) > 1 else { return }
        animateContentOffset(toY: clamped)
    }

    /// Centre a specific grid cell's row (library mode). The grid spans many
    /// rows in one section, so the section path above would pin the viewport
    /// to the grid's top; centre the focused cell's own row instead. Same
    /// clamp + CADisplayLink driver as scrollSectionIntoView. Ported from
    /// MediaLibraryViewController.scrollGridCellIntoView(at:).
    private func scrollGridCellIntoView(at indexPath: IndexPath) {
        guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        scrollToCenter(frame: attrs.frame)
    }

    /// Scroll whatever is focused right now fully on screen.
    ///
    /// Driven from OUTSIDE the focus delegate on purpose. The outer collection
    /// view's `didUpdateFocusIn` does not reliably run for a tile inside a shelf
    /// row's nested collection view — the nested view's own delegate takes it,
    /// and that one only drives horizontal scroll — so the self-driven vertical
    /// scroll never happened for search results. Measured symptom: focus sat on
    /// row 1's first tile while the page was clamped at its bottom offset (223 ==
    /// contentSize.height - bounds.height), putting row 1 at window y=32 under a
    /// viewport starting at 207. Focus was correct and invisible, which reads as
    /// Down and Up both skipping the first row.
    /// Scroll a row fully into view and hand it focus. False if it cannot.
    ///
    /// Needed because the engine will not move to a row that is scrolled off the
    /// collection's top edge, and revealing a lower row necessarily pushes the
    /// one above off: two 492pt rows do not fit an 873pt viewport. On Search that
    /// made Up out of row 2 land on the keyboard, skipping row 1 — the engine did
    /// move, it just picked the only thing above that was still on screen.
    /// Section index of the currently focused item, or nil when focus is not in
    /// this page. Resolved from the focused VIEW, not an index path: tiles in
    /// shelf rows live in a nested collection view and never resolve to one.
    var focusedSectionForHandoff: Int? {
        guard let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
              focused.isDescendant(of: collectionView)
        else { return nil }
        return sectionIndex(forFocusedView: focused)
    }

    func focusRow(_ target: Int) -> Bool {
        guard target >= 0, target < sectionsSnapshot.count else { return false }
        // Scroll NOT animated, and before the request: the cell has to exist and
        // be on screen at the moment the engine resolves preferred focus.
        if let attrs = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: target)) {
            let insetTop = collectionView.adjustedContentInset.top
            let maxOffset = max(-insetTop, collectionView.contentSize.height - collectionView.bounds.height)
            let clamped = max(-insetTop, min(attrs.frame.minY - insetTop, maxOffset))
            if abs(collectionView.contentOffset.y - clamped) > 1 {
                offsetLink?.invalidate()
                offsetLink = nil
                collectionView.contentOffset.y = clamped
                collectionView.layoutIfNeeded()
            }
        }
        guard collectionView.cellForItem(at: IndexPath(item: 0, section: target)) != nil else { return false }
        pendingRowFocusSection = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        return true
    }

    func revealFocusedRowIfNeeded() {
        guard let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
              focused.isDescendant(of: collectionView)
        else { return }
        revealFocusedView(focused)
    }

    /// Minimal vertical scroll to bring a focused descendant fully on screen.
    ///
    /// Frame-based, not section-based: the caller is the path where the section
    /// index could not be resolved. Scrolls to the nearest edge rather than
    /// centring, so a row already mostly visible barely moves.
    private func revealFocusedView(_ view: UIView) {
        // `collectionView` bounds.origin IS the content offset, so converting
        // into it yields content coordinates directly.
        let frameInContent = view.convert(view.bounds, to: collectionView)
        let insetTop = collectionView.adjustedContentInset.top
        let offset = collectionView.contentOffset.y
        var target = offset
        if frameInContent.minY < offset + insetTop {
            target = frameInContent.minY - insetTop
        } else if frameInContent.maxY > offset + collectionView.bounds.height {
            target = frameInContent.maxY - collectionView.bounds.height
        }
        let top = -insetTop
        let maxOffset = max(top, collectionView.contentSize.height - collectionView.bounds.height)
        let clamped = max(top, min(target, maxOffset))
        guard abs(offset - clamped) > 1 else { return }
        animateContentOffset(toY: clamped)
    }

    private func scrollToCenter(frame: CGRect) {
        let target = frame.midY - collectionView.bounds.height / 2
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        let clamped = max(-collectionView.adjustedContentInset.top, min(target, maxOffset))
        guard abs(collectionView.contentOffset.y - clamped) > 1 else { return }
        animateContentOffset(toY: clamped)
    }

    // MARK: - Per-frame vertical scroll driver

    // `UIView.animate { setContentOffset }` only animates the PRESENTATION layer:
    // the model contentOffset jumps to the target immediately, so the collection
    // recycles cells based on the final offset and a row that lands off-screen has
    // its cells removed at once — it "pops" before finishing its slide-out (worse
    // here because the collection is clipsToBounds=false, so off-bounds cells are
    // visible). A CADisplayLink advancing the real offset per frame recycles cells
    // progressively, so rows scroll out smoothly.
    private var offsetLink: CADisplayLink?
    private var offsetStartY: CGFloat = 0
    private var offsetTargetY: CGFloat = 0
    private var offsetStartTime: CFTimeInterval = 0
    private let offsetDuration: CFTimeInterval = FocusScrollMotion.settleDuration

    private func animateContentOffset(toY targetY: CGFloat) {
        offsetLink?.invalidate()
        offsetStartY = collectionView.contentOffset.y   // continue from current position
        offsetTargetY = targetY
        offsetStartTime = CACurrentMediaTime()
        // WEAK proxy target: CADisplayLink retains its target strongly, and
        // this VC has no deinit hook SwiftUI is guaranteed to trigger — a
        // discarded instance (the launch double-build) with a live link would
        // leak FOREVER, keeping its Combine observers firing and doubling
        // every applySnapshot. The proxy self-invalidates once the VC dies.
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        offsetLink = link
    }

    /// Weak trampoline between CADisplayLink (strong target) and the VC.
    private final class DisplayLinkProxy: NSObject {
        private weak var owner: PlexHomeViewController?
        init(_ owner: PlexHomeViewController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.stepOffset(link)
        }
    }

    @objc fileprivate func stepOffset(_ link: CADisplayLink) {
        let t = offsetDuration > 0 ? min(1, (CACurrentMediaTime() - offsetStartTime) / offsetDuration) : 1
        let e = FocusScrollMotion.ease(t)   // shared focus-scroll curve (cubic ease-out)
        collectionView.contentOffset = CGPoint(x: 0, y: offsetStartY + (offsetTargetY - offsetStartY) * CGFloat(e))
        if t >= 1 {
            link.invalidate()
            offsetLink = nil
            collectionView.contentOffset = CGPoint(x: 0, y: offsetTargetY)
        }
    }

    // MARK: - UIFocusEnvironment override

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Explicit row hand-off (Up out of a lower row). First, because it is a
        // deliberate one-shot and must beat every heuristic below it.
        if let section = pendingRowFocusSection {
            pendingRowFocusSection = nil
            if let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: section)) {
                return [cell]
            }
        }
        // Contentless Home (error / empty): steer focus onto the state view's
        // action button so the user is never stranded with nothing focusable.
        // The collection is hidden in these states, so it has no competing cell.
        if stateViewHasFocusableAction, !stateView.isHidden {
            return [stateView]
        }
        // Route the focus update at restoration time toward the right cell.
        if let target = pendingPreviewRestore,
           let indexPath = indexPath(for: target) {
            if indexPath.section < sectionsSnapshot.count,
               isShelfKind(sectionsSnapshot[indexPath.section].kind) {
                // Shelf rows: prefer the row cell; its own
                // preferredFocusEnvironments routes to the pending tile.
                if let row = collectionView.cellForItem(at: IndexPath(item: 0, section: indexPath.section)) {
                    return [row]
                }
            } else if let cell = collectionView.cellForItem(at: indexPath) {
                return [cell]
            }
        }
        // Launch focus: hero Play (see needsInitialHeroFocus).
        if needsInitialHeroFocus,
           let heroIndex = heroSectionIndex,
           let heroCell = collectionView.cellForItem(at: IndexPath(item: 0, section: heroIndex)) {
            return [heroCell]
        }
        // Staged Menu back on a heroless page (Search) — see returnToTopRow().
        if wantsTopFocus,
           let topCell = collectionView.cellForItem(at: IndexPath(item: 0, section: topSectionIndex)) {
            return [topCell]
        }
        return super.preferredFocusEnvironments
    }
}

// MARK: - Delegate

extension PlexHomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        handleTap(at: indexPath)
    }

    /// Shelf rows are containers — focus dives through to their tiles.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        guard indexPath.section < sectionsSnapshot.count else { return true }
        let kind = sectionsSnapshot[indexPath.section].kind
        // Prompt/state cells host their own FocusableActionButtons (recents
        // pills, Try Again). Keeping the CELL out of the focus chain does NOT
        // let the engine reach those buttons: a collection view enumerates its
        // focus items as CELLS, so a non-focusable cell's descendants are never
        // offered and Down from the search keyboard found nothing to move to,
        // with four focusable pills on screen. The cell takes focus only when
        // it has a button, and redirects into it via
        // `preferredFocusEnvironments`.
        if kind == .searchPrompt { return !recentSearches.isEmpty }
        if kind == .searchState { return currentSearchState.hasFocusableAction }
        return !isShelfKind(kind)
    }

    /// Block Left-press focus escapes from a horizontally-scrolling row
    /// when there are still cells to the left in the same row that have
    /// scrolled offscreen.
    ///
    /// Bug: with `orthogonalScrollingBehavior = .continuous`, cells that
    /// scroll outside the orthogonal viewport are removed from the focus
    /// chain entirely. When the user presses Left on (say) item 8 of 20,
    /// the focus engine doesn't see items 0–6 (offscreen, dequeued), so
    /// it falls through to whatever is to the left of the collection
    /// view — the sidebar. The sidebar briefly reveals before some other
    /// focus mechanism snaps focus back. Annoying flicker.
    ///
    /// Fix: intercept the Left update. If the previously-focused cell is
    /// not at item 0 of its section, block the system update and instead
    /// scroll-to + focus the cell at `indexPath.item - 1`. The orthogonal
    /// scroll view brings that cell back into the viewport so it can
    /// regain focus.
    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        guard context.focusHeading == .left,
              let prevIndexPath = context.previouslyFocusedIndexPath,
              prevIndexPath.section < sectionsSnapshot.count,
              prevIndexPath.item > 0
        else { return true }

        // Only intercept for orthogonally-scrolling rows. The grid is NOT
        // orthogonal (its offscreen-left cells stay in the focus chain), so
        // Left moves resolve normally — no interception.
        let section = sectionsSnapshot[prevIndexPath.section]
        switch section.kind {
        case .continueWatching, .recentlyAdded, .watchlist, .recommendations, .discoverList, .searchGrid:
            break
        case .hero, .recommendationsLoading, .recommendationsError, .sortHeader, .grid,
             .searchPrompt, .searchState:
            return true
        }

        // Only intercept when focus is trying to leave the collection
        // view entirely (e.g. into the sidebar). If the next focus is
        // still inside our collection view, the engine has already
        // picked the right neighbour and we let it through.
        let nextIsInside = context.nextFocusedView?.isDescendant(of: collectionView) ?? false
        guard !nextIsInside else { return true }

        // Block the system update and bring the target cell into view.
        // The focus engine will re-poll on next runloop, find the
        // now-visible neighbour, and land focus there. We scroll the
        // orthogonal section non-animated so the cell is in the view
        // hierarchy by the time the engine runs again.
        let target = IndexPath(item: prevIndexPath.item - 1, section: prevIndexPath.section)
        collectionView.scrollToItem(at: target, at: .left, animated: false)
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
        return false
    }

    /// Pagination trigger: when a card within 5 items of the end
    /// displays, fire `loadMoreIfNeeded()` for its section.
    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard indexPath.section < sectionsSnapshot.count else { return }
        let section = sectionsSnapshot[indexPath.section]
        switch section.kind {
        case .hero, .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState, .searchGrid:
            return  // No pagination for these (search caps at 80 results)
        case .continueWatching, .recentlyAdded, .recommendations, .watchlist, .discoverList:
            return  // Shelf rows paginate from their own willDisplay (shelfWillDisplay)
        case .grid:
            // Grid pagination: trigger the next page when displaying a cell
            // within 12 items of the loaded tail (ported from
            // MediaLibraryViewController's willDisplay).
            let threshold = gridItems.count - 12
            guard indexPath.item >= threshold, gridItems.count < totalGridCount else { return }
            loadGridNextPage()
        }
    }

    /// Select long-press on a library-grid tile → the tile action menu.
    /// Shelf-row tiles have their own recognizer (ShelfRowCell); this one
    /// only serves `.grid` sections, whose tiles are outer-collection cells.
    @objc private func handleGridLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        guard let indexPath = TileLongPress.focusedCell(in: collectionView),
              indexPath.section < sectionsSnapshot.count else { return }
        // Skeleton placeholder doesn't get a menu.
        if let itemID = dataSource.itemIdentifier(for: indexPath),
           itemID.itemID == HomeItemID.skeletonSentinel {
            return
        }
        let section = sectionsSnapshot[indexPath.section]
        guard case .grid = section.kind, indexPath.item < section.items.count else { return }
        let item = section.items[indexPath.item]
        presentTileMenu(sections: tileMenuSections(for: item, isContinueWatching: false))
    }

    // MARK: - Tile menu builder

    /// Build the tile menu action groups for a cell — one sub-array per
    /// divider-separated group. This is the CANONICAL long-press menu for
    /// home rows + library grid — the only long-press menu in the app now
    /// that the SwiftUI detail is gone. CW rows swap the watched
    /// group for Remove-from-CW + Go-to-Show.
    private func tileMenuSections(for item: MediaItem,
                                  isContinueWatching: Bool,
                                  shelfLocation: (sectionID: HomeSectionID, itemIndex: Int)? = nil) -> [[TileMenuAction]] {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              !item.ref.itemID.isEmpty
        else { return [] }
        let ratingKey = item.ref.itemID

        let network = PlexNetworkManager.shared

        if isContinueWatching {
            // Same segmentation as the generic menu below: [Watch from
            // Beginning, More Info, Go to Show] | [watched state] |
            // [Refresh Metadata]. CW adds Remove from Continue Watching to
            // the middle group.
            var cwFirst = [
                TileMenuAction(title: "Watch from Beginning",
                               systemImage: "arrow.counterclockwise") { [weak self] in
                    self?.playItem(item, fromBeginning: true)
                },
                TileMenuAction(title: "More Info",
                               systemImage: "info.circle") { [weak self] in
                    self?.selectMediaItem(item)
                },
            ]
            if item.kind == .episode, item.grandparentRef?.itemID.isEmpty == false {
                cwFirst.append(TileMenuAction(title: "Go to Show",
                                              systemImage: "tv") { [weak self] in
                    // Pass the EPISODE, not the show: the expanded detail
                    // keys everything off it — episode chrome up top, the
                    // episode's season pill selected, rail positioned at
                    // this episode, About describing the show.
                    self?.presentStandaloneExpandedDetail(item)
                })
            }

            let cwMiddle = [
                TileMenuAction(title: "Mark as Watched",
                               systemImage: "eye.fill") { [weak self] in
                    self?.performMenuAction {
                        try await network.markWatched(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                    }
                },
                TileMenuAction(title: "Remove from Continue Watching",
                               systemImage: "trash",
                               destructive: true) { [weak self] in
                    self?.removeFromContinueWatchingOptimistically(item, shelfLocation: shelfLocation)
                },
            ]

            let cwLast = [
                TileMenuAction(title: "Refresh Metadata",
                               systemImage: "arrow.clockwise") {
                    Task {
                        try? await network.refreshMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                    }
                },
            ]

            return [cwFirst, cwMiddle, cwLast]
        }

        // Generic media-item menu (Recently Added, Recommendations):
        // [Watch from Beginning, More Info, Go to Show] | [watched state] |
        // [Refresh Metadata].

        // Watch from Beginning: actually starts playback at 0:00. (The old
        // SwiftUI menu only fired markUnwatched here without playing —
        // misleading; the CW menu's play-from-start behavior is correct.)
        var first = [
            TileMenuAction(title: "Watch from Beginning",
                           systemImage: "arrow.counterclockwise") { [weak self] in
                self?.playItem(item, fromBeginning: true)
            },
            TileMenuAction(title: "More Info",
                           systemImage: "info.circle") { [weak self] in
                self?.selectMediaItem(item)
            },
        ]

        // Episode-only: jump to the show's detail (season pills + episode
        // rail live there — a separate "Go to Season" entry would open the
        // same page, so the old SwiftUI menu's two entries fold into one).
        // Pass the EPISODE, not the show: the expanded detail keys off it
        // (season pill selected, rail positioned at this episode).
        if item.kind == .episode, item.grandparentRef?.itemID.isEmpty == false {
            first.append(TileMenuAction(title: "Go to Show",
                                        systemImage: "tv") { [weak self] in
                self?.presentStandaloneExpandedDetail(item)
            })
        }

        // Mark as Watched / Unwatched — conditional on view state.
        // isWatched mirrors the old `viewCount > 0`; watchProgress != nil
        // mirrors the in-progress branch.
        var middle: [TileMenuAction] = []
        let isWatched = item.isWatched
        if !isWatched || item.watchProgress != nil {
            middle.append(TileMenuAction(title: "Mark as Watched",
                                         systemImage: "eye.fill") { [weak self] in
                self?.performMenuAction {
                    try await network.markWatched(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            })
        }
        if isWatched {
            middle.append(TileMenuAction(title: "Mark as Unwatched",
                                         systemImage: "eye.slash.fill") { [weak self] in
                self?.performMenuAction {
                    try await network.markUnwatched(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            })
        }

        let last = [
            TileMenuAction(title: "Refresh Metadata",
                           systemImage: "arrow.clockwise") {
                Task {
                    try? await network.refreshMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            },
        ]

        return [first, middle, last]
    }

    /// Performs a context-menu action, then refreshes hubs from the server.
    private func performMenuAction(_ action: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await action()
            } catch {}
            await dataStore.refreshHubs()
            await dataStore.refreshLibraryHubs()
        }
    }

    /// Optimistic Continue Watching removal: the tile disappears the moment
    /// the menu closes; the server PUT + refetch run behind it. Suppression
    /// (`pendingCWRemovals`) holds until the refreshed data itself no longer
    /// contains the item, so racing hub refreshes can't flash it back. On
    /// failure the suppression lifts and the tile returns — server truth wins.
    private func removeFromContinueWatchingOptimistically(
        _ item: MediaItem,
        shelfLocation: (sectionID: HomeSectionID, itemIndex: Int)? = nil
    ) {
        let ratingKey = item.ref.itemID
        guard !ratingKey.isEmpty,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        pendingCWRemovals.insert(ratingKey)
        // Capture the tile's on-screen slot BEFORE the data mutates: the
        // visible row then deletes exactly that index in a batch update
        // (survivors slide over, focus stays coherent through the delete)
        // instead of crossfade-reloading and re-arming focus afterwards.
        pendingShelfRemoval = shelfLocation.map { ($0.sectionID, $0.itemIndex) }
        applySnapshot(animated: true)

        Task { @MainActor in
            do {
                try await PlexNetworkManager.shared.removeFromContinueWatching(
                    serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                // Refetch CW (and library hubs, which carry their own CW rows)
                // BEFORE lifting the suppression, so the data is already clean
                // and the reconcile snapshot is a visual no-op.
                await dataStore.refreshContinueWatchingIfStale(olderThan: 0)
                await dataStore.refreshLibraryHubs()
            } catch {}
            pendingCWRemovals.remove(ratingKey)
            applySnapshot(animated: true)
        }
    }

    // MARK: - Pagination

    /// Load the next page of items for a paginating hub section.
    @MainActor
    private func loadMoreIfNeeded(sectionID: HomeSectionID, hubKey: String?, hubIdentifier: String?) async {
        guard var state = paginationStates[sectionID],
              !state.isLoadingMore,
              !state.hasReachedEnd,
              let hubKey, !hubKey.isEmpty
        else { return }

        if let total = state.totalSize, state.loadedItems.count >= total {
            state.hasReachedEnd = true
            paginationStates[sectionID] = state
            return
        }

        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        state.isLoadingMore = true
        paginationStates[sectionID] = state
        applySnapshot(animated: false)  // show skeleton

        do {
            let result = try await PlexNetworkManager.shared.getHubItems(
                serverURL: serverURL,
                authToken: token,
                hubKey: hubKey,
                hubIdentifier: hubIdentifier,
                start: state.loadedItems.count,
                count: paginationPageSize
            )

            // Refetch state in case anything else (refresh, etc.) mutated
            // it while we awaited the network call.
            var freshState = paginationStates[sectionID] ?? state
            freshState.isLoadingMore = false
            if let size = result.totalSize {
                freshState.totalSize = size
            }
            if result.items.isEmpty {
                freshState.hasReachedEnd = true
            } else {
                // Map the page to MediaItem, then dedupe by ref.itemID
                // (Stage 2). The SwiftUI/PlexMetadata path deduped by ratingKey;
                // ref.itemID == ratingKey via PlexMediaMapper.item.
                let mapped = mapToMediaItems(result.items)
                let existingKeys = Set(freshState.loadedItems.map { $0.ref.itemID })
                let newItems = mapped.filter { item in
                    !item.ref.itemID.isEmpty && !existingKeys.contains(item.ref.itemID)
                }
                if newItems.isEmpty {
                    freshState.hasReachedEnd = true
                } else {
                    freshState.loadedItems.append(contentsOf: newItems)
                    // Register as genuine paginated extras — only these may
                    // outlive a head refresh in mergedItems.
                    freshState.paginatedKeys.formUnion(newItems.map { $0.ref.itemID })
                    if let total = freshState.totalSize,
                       freshState.loadedItems.count >= total {
                        freshState.hasReachedEnd = true
                    }
                }
            }
            paginationStates[sectionID] = freshState
            applySnapshot(animated: false)
        } catch {
            // SwiftUI doesn't mark hasReachedEnd on error -- user can
            // retry by continuing to scroll.
            var freshState = paginationStates[sectionID] ?? state
            freshState.isLoadingMore = false
            paginationStates[sectionID] = freshState
            applySnapshot(animated: false)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        backdropView.applyScrollOffset(offset)
        // Parallax the hero paging dots up so they don't sink too low when the
        // page scrolls below the hero: they ride the content at 1x while the
        // backdrop recedes at 1.4x, so without this they fall behind the image.
        for case let heroCell as HeroOverlayCell in collectionView.visibleCells {
            heroCell.overlay.applyScrollOffset(offset)
        }
    }

    /// Auto-scroll to keep the focused row visible — mirrors the SwiftUI
    /// version's `onRowFocused` (`scrollProxy.scrollTo(rowID, anchor: .center)`).
    /// We watch UIKit focus updates and centre the focused row in the
    /// vertical viewport. The orthogonal (horizontal) scroll inside a row
    /// is handled by `UICollectionView` automatically.
    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        // Resolve the section that owns the newly-focused view.
        guard let nextSectionIndex = focusedSectionIndex(in: context) else {
            updateLeftEdgeGuide(for: nil)
            // Focus left the page (sidebar, modal). Chrome must be back
            // before the sidebar can be interacted with.
            postFocusBelowTop(false)
            // ...unless focus is still INSIDE the page and only the section
            // lookup failed, which it does for a tile inside a shelf row's
            // nested collection view. `isScrollEnabled = false` means the engine
            // will not scroll for us, so bailing here left a focused row sitting
            // off-screen: measured on Search with row 1 at window y=32 while the
            // viewport starts at 207, focused and completely hidden behind the
            // keyboard. That reads as "Down skipped the first row" when focus
            // was on it the whole time. Reveal it from its own frame, which
            // needs no section index.
            if let next = context.nextFocusedView, next.isDescendant(of: collectionView) {
                revealFocusedView(next)
            }
            return
        }
        postFocusBelowTop(nextSectionIndex > topSectionIndex)
        let kind: HomeSectionKind? = sectionsSnapshot.indices.contains(nextSectionIndex)
            ? sectionsSnapshot[nextSectionIndex].kind
            : nil
        // The staged Menu back has landed; stop routing focus to the top. A
        // directional move clears it too — if the top cell never took focus the
        // flag would otherwise latch and yank focus back on some later,
        // unrelated update. `needsInitialHeroFocus` additionally requires the
        // move to start INSIDE the collection, because it is armed at launch
        // when focus can arrive from the sidebar. This flag is only ever armed
        // by handleMenuBack(), which already requires focus inside the
        // collection, so that conjunct would be dead weight here.
        if wantsTopFocus, nextSectionIndex == topSectionIndex || !context.focusHeading.isEmpty {
            wantsTopFocus = false
        }
        // Initial-hero routing ends once the hero has focus, or as soon as
        // the user makes a directional move WITHIN the page (never yank focus
        // mid-navigation). Directional entries from OUTSIDE (the sidebar)
        // don't count — on a navigated-to surface like Discover that entry
        // happens before the hero exists, and clearing on it would leave the
        // launch focus stranded on a shelf tile.
        if needsInitialHeroFocus {
            let prevInside = context.previouslyFocusedView?.isDescendant(of: collectionView) == true
            // The loading placeholder parks focus but must not consume the
            // initial-hero routing — the real hero still needs it to land on
            // Play when content arrives.
            let heroHasContent = kind == .hero && heroState != .loading
            if heroHasContent || (prevInside && !context.focusHeading.isEmpty) {
                needsInitialHeroFocus = false
            }
        }
        switch kind {
        case .hero:
            scrollHeroIntoView()
        case .grid:
            // Multi-row grid: centring the SECTION (its first item) would
            // pin the viewport to the grid's top — centre the focused
            // cell's own row instead. Grid cells are NOT orthogonal, so
            // `nextFocusedIndexPath` resolves at the collection level.
            if let indexPath = context.nextFocusedIndexPath {
                scrollGridCellIntoView(at: indexPath)
            }
        default:
            // The first row under the hero collapses the hero to a FIXED,
            // hero-derived band (not a centre of the row), so the hero's
            // resting position is self-contained — identical on every page
            // regardless of whether row 1 is Continue Watching (277pt) or a
            // poster row (444pt). Centring couples the hero's height to the
            // row's height (~84pt drift). Deeper rows centre as usual.
            if let heroIndex = heroSectionIndex, nextSectionIndex == heroIndex + 1 {
                scrollFirstRowToHeroCollapsed(heroSectionIndex: heroIndex)
            } else {
                scrollSectionIntoView(sectionIndex: nextSectionIndex)
            }
        }
        updateLeftEdgeGuide(for: context.nextFocusedIndexPath)
    }

    /// Re-aim the leading-edge `UIFocusGuide` based on the newly-focused
    /// cell. See property doc on `leftEdgeFocusGuide` for the bug it
    /// prevents.
    private func updateLeftEdgeGuide(for indexPath: IndexPath?) {
        guard let indexPath,
              indexPath.section < sectionsSnapshot.count,
              indexPath.item > 0
        else {
            // No cell focused, or focus is on item 0 of a row, or out of
            // bounds — let the guide be transparent so Left can escape.
            leftEdgeFocusGuide.preferredFocusEnvironments = []
            return
        }
        let section = sectionsSnapshot[indexPath.section]
        switch section.kind {
        case .continueWatching, .recentlyAdded, .watchlist, .recommendations, .grid, .discoverList,
             .searchGrid:
            // Orthogonal rows AND the grid get the walk-back redirect:
            // point at the previous cell when it's already on screen
            // (ported from MediaLibraryViewController.updateLeftEdgeGuide).
            break
        case .hero, .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState:
            leftEdgeFocusGuide.preferredFocusEnvironments = []
            return
        }
        let target = IndexPath(item: indexPath.item - 1, section: indexPath.section)
        // Point the guide at the previous cell if it's already on screen.
        // Critically: DO NOT preemptively scroll the row to bring the
        // target into view -- that runs on every focus update (including
        // Right / Up / Down moves) and produces a "row keeps re-centering
        // under you" effect. UICollectionView prefetch usually keeps the
        // adjacent cell warm anyway; if it doesn't, the guide will fail
        // open (no redirect) and the system falls back to the existing
        // `shouldUpdateFocusIn:` block in commit `d181fd1` which handles
        // the discrete-Left case.
        if let cell = collectionView.cellForItem(at: target) {
            leftEdgeFocusGuide.preferredFocusEnvironments = [cell]
        } else {
            leftEdgeFocusGuide.preferredFocusEnvironments = []
        }
    }

    /// Returns the section index of the newly-focused view, looking either
    /// at the focused cell's indexPath (orthogonal rows) or — for the hero
    /// — at whichever section's overlay contains the focused button.
    private func focusedSectionIndex(in context: UICollectionViewFocusUpdateContext) -> Int? {
        if let nextIndexPath = context.nextFocusedIndexPath {
            return nextIndexPath.section
        }
        // `nextFocusedIndexPath` comes back nil at the collection level for two
        // cases here: (1) the hero, whose focusable Play/Info buttons live in a
        // SwiftUI subview rather than the cell itself, and (2) cells inside the
        // orthogonal (continuous) rows, which don't resolve to a collection-level
        // index path. Walk the focused view's superview chain to its enclosing
        // collection-view cell and read its section. This matters now that
        // `isScrollEnabled = false` hands us the vertical focus-scroll: the
        // engine no longer masks a nil section by scrolling on its own, so a
        // Down/Up move between orthogonal rows would otherwise fail to centre.
        return sectionIndex(forFocusedView: context.nextFocusedView)
    }

    /// Walk a focused view's superview chain to its enclosing collection-view
    /// cell and read that cell's section.
    private func sectionIndex(forFocusedView view: UIView?) -> Int? {
        var v: UIView? = view
        while let current = v {
            if let cell = current as? UICollectionViewCell,
               let ip = self.collectionView.indexPath(for: cell) {
                return ip.section
            }
            v = current.superview
        }
        return nil
    }
}

// MARK: - Staged Menu back (issue #19)

extension PlexHomeViewController: MenuBackHandling {
    /// Stage 1: a Menu press from below the top row snaps the page back to its
    /// top row instead of opening the sidebar. At the top row this declines, so
    /// the system performs its native sidebar reveal (stage 2), and from there
    /// `TVSidebarView.onExitCommand` returns to Home (stage 3).
    func handleMenuBack() -> Bool {
        guard isViewLoaded, let window = view.window, window.isKeyWindow else { return false }
        // Focus must be inside THIS page's collection. When a player, detail
        // carousel, tile menu or Settings page is up, focus lives inside it —
        // this page declines and Menu keeps its normal meaning there.
        guard let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
              focused.isDescendant(of: collectionView) else { return false }
        guard StagedMenuBack.shouldReturnToTop(
            focusedSection: sectionIndex(forFocusedView: focused),
            topSection: topSectionIndex
        ) else { return false }

        returnToTopRow()
        return true
    }

    /// Jump the page to its resting top offset and lay out, so the first
    /// section's cell exists. No animation: the focus engine re-resolves
    /// mid-flight and lands on whatever row is passing.
    private func scrollToContentTop() {
        // Cancel any in-flight focus-scroll so it can't animate back over us.
        offsetLink?.invalidate()
        offsetLink = nil
        collectionView.contentOffset = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
        collectionView.layoutIfNeeded()
    }

    /// Scroll to the top row and mark it as the preferred focus target, WITHOUT
    /// requesting a focus update.
    ///
    /// Split out because the requester is not always this controller.
    /// `setNeedsFocusUpdate()` is ignored unless the environment asking for it
    /// currently CONTAINS focus, so when Search hands off from the keyboard the
    /// request has to come from `SearchContainerViewController` (which contains
    /// both the keyboard and this page) while the aim is set here.
    func aimFocusAtTopRow() {
        scrollToContentTop()

        // Hero modes reuse the launch routing so focus lands on Play; Search
        // has no hero, so `wantsTopFocus` aims at its first section instead.
        if heroSectionIndex != nil {
            needsInitialHeroFocus = true
        } else {
            wantsTopFocus = true
        }
    }

    /// Snap to the top row and put focus there.
    ///
    /// The jump is deliberate. While the page is scrolled deep the top row's
    /// cell has been recycled, so focus cannot be routed to a cell that does
    /// not exist yet — and animating there first loses the race: the focus
    /// engine re-resolves mid-flight, lands on whatever row is passing, and
    /// scrolls that back into view (the page ends up one row higher instead of
    /// at the top). Setting the offset and laying out first creates the cell,
    /// so the focus request has somewhere to land.
    private func returnToTopRow() {
        aimFocusAtTopRow()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // The hero's buttons live in a SwiftUI subview that may not be
        // focusable until the next runloop turn; re-assert once it is.
        DispatchQueue.main.async { [weak self] in
            self?.nudgeInitialHeroFocusIfNeeded()
        }
    }
}
