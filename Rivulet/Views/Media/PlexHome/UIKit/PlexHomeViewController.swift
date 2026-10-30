// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The UIKit Home, also driving the library, Discover, Watchlist and Search surfaces by `mode`.
// `HeroBackdropView` sits behind the collection; sections run hero, Continue Watching, Recently Added
// per library, Watchlist, then Recommendations. Detail and the preview carousel present from here,
// and a dismissed preview's `PreviewSourceTarget` maps back to the tile to refocus.

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
    /// Library-mode-only: the library's Collections shelf. Each library key
    /// has its own cached controller, so the id cannot collide.
    static let libraryCollections = HomeSectionID(raw: "collections")
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
    /// The Discover surface: native recommendations, plus TMDB curated lists
    /// when Plex is signed in, using the shared hero and shelf layout.
    case discover
    /// The Search surface: no hero — a prompt/recents state when the query is
    /// empty, inline searching/error/no-results states, and grouped poster
    /// GRIDS of results (Movies & TV / Episodes & Seasons / Music). The query
    /// arrives from `SearchContainerViewController` via `updateSearchQuery`.
    case search
    /// Watchlist surface: no hero, one poster grid of every Plex Watchlist
    /// entry (issue #287). Entries are Discover metadata, so the tiles,
    /// the tap and the tile menu all reuse the Home watchlist row's paths.
    case watchlist
    /// Collection page: one Plex collection's members as a poster grid under
    /// the collection's title. `ref.itemID` is the collection ratingKey.
    case collection(MediaItem)
    /// One server's video playlists as a poster grid (its sidebar Playlists row).
    case playlists(providerID: String)
    /// Playlist page: a collection-style page of the entries in server order, under Play and Shuffle.
    case playlist(MediaPlaylist)
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
    /// count + focusable sort button and View menu,
    /// `MediaLibrarySortControl`).
    case sortHeader
    /// Library mode only — 6-across paginated poster grid of the whole
    /// library, sorted by `gridSort`; or, in the Collections view, the
    /// library's collection list whole.
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
    /// Watchlist mode only — every watchlist entry as a poster grid. Same
    /// layout as the library grid, but backed by `watchlistItems` (Discover
    /// entries, not MediaItems) so it reuses the row's cell, tap and menu.
    case watchlistGrid
    /// Search mode only — one grouped result grid (Movies & TV, Episodes &
    /// Seasons, Music) with a row-style header. Same 6-across poster grid
    /// as the library, no pagination (search caps at 80 results).
    case searchGrid
}

struct HomeSectionData {
    let id: HomeSectionID
    let kind: HomeSectionKind
    let title: String?
    /// Header style for the section (see `HubHeaderView.Style`).
    let headerStyle: HubHeaderView.Style
    /// Total item count from Plex for the "X of Y" indicator. nil when
    /// pagination hasn't loaded a total yet, which is the case for first
    /// render of every section.
    let totalSize: Int?
    /// MediaItems for hub, recommendations, CW and grid sections; shelves render from these
    /// instead of building PlexMetadata at launch.
    var items: [MediaItem]
    /// Watchlist entries for the watchlist section.
    let watchlistItems: [PlexWatchlistItem]
    /// Hero carousel items (PlexMetadata).
    let heroItems: [PlexMetadata]
    /// MediaItem-backed hero carousel items (Discover mode — TMDB-mapped).
    /// When non-empty, the hero cell uses the MediaItem configuration path
    /// instead of `heroItems`.
    var heroMediaItems: [MediaItem] = []
    let hubKey: String?
    let hubIdentifier: String?
    /// The header's server badge ("Plex", "Jellyfin"); nil with one server.
    var sourceBadge: String? = nil

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

    /// Watchlist mode: every entry as a poster grid. Untitled: the sidebar pill already names it.
    static func watchlistGrid(items: [PlexWatchlistItem]) -> HomeSectionData {
        HomeSectionData(
            id: .watchlist,
            kind: .watchlistGrid,
            title: nil,
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
    /// title for `MediaLibrarySortControl.configure(title:count:sortName:view:viewMenu:)`;
    /// count, sort name and view live on the controller
    /// (totalGridCount / gridSort / gridShowsCollections).
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

    /// Paginated poster grid. `items` carries the grid slots. Library mode
    /// passes no title (its sort header names the library); the collection
    /// page passes the collection's title, drawn in the Watchlist page's
    /// title style.
    static func grid(items: [MediaItem], title: String? = nil) -> HomeSectionData {
        HomeSectionData(
            id: .grid,
            kind: .grid,
            title: title,
            headerStyle: title == nil ? .swiftUIInfiniteRow : .swiftUIWatchlist,
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

    // Set by the host: opens the Music page for an artist or album.
    var onSelectMusic: ((PlexMetadata) -> Void)?


    /// Search mode: the controller changed the query itself (a recents pill
    /// was tapped) — the container mirrors it into the search bar.
    var onSearchQueryChangedByController: ((String) -> Void)?

    /// Surface selector — .home (default) or .library(key:title:). All
    /// library-specific behavior branches off this; home-mode code paths are
    /// byte-identical to before the mode was introduced.
    let mode: HomeMode

    /// Collection mode: runs once the page has been dismissed, never when it
    /// only covers itself with a carousel or detail. The carousel passes one
    /// that puts focus back on the below-fold tile that opened the page.
    var onDismiss: (() -> Void)?
    /// Library mode: the tab container, which saves the View choice and adds Folders.
    var onSelectViewMode: ((LibraryViewMode) -> Void)?

    var hasCollections: Bool { !libraryCollections.isEmpty }
    /// Collection mode's blur-fade transition. UIKit holds a transitioning
    /// delegate weakly, so the page keeps it alive (PersonDetailViewController
    /// does the same).
    private let blurFade = BlurFadeTransitioningDelegate()

    /// The collection or playlist a drill-in page shows; nil on every other surface.
    var drillInItem: MediaItem? {
        switch mode {
        case .collection(let item): item
        case .playlist(let playlist): playlist.item
        default: nil
        }
    }
    /// The collection and playlist pages: presented over the surface they were opened from.
    var isDrillInPage: Bool { drillInItem != nil || nativeHubSource != nil || loadedFeedItems != nil }

    /// The playlist page's rows, in server order; the grid shows their items.
    private(set) var playlistEntries: [PlaylistEntry] = []
    /// The playlist page's Move mode (nil on other pages), and the order it started from.
    private var entryMove: GrabReorderController?
    private var entriesBeforeMove: [PlaylistEntry] = []
    /// A refresh was held back or a load dropped during the move; reload when it ends without a server call.
    private var refreshAfterMove = false
    /// The playlists grid's lists, kept for `isSmart`: the grid holds only items.
    private var loadedPlaylists: [MediaPlaylist] = []

    /// Set for a library on a server other than Plex. Grid, rows,
    /// collections, A to Z bar and hero go through that server's
    /// `MediaProvider` instead of Plex's endpoints. The mode's key is
    /// `providerLibrary.settingsKey`, so sort and visibility settings never
    /// collide with a Plex section key.
    private let providerLibrary: MediaLibrary?
    private let nativeHubSource: MediaHub?
    private let loadedFeedItems: [MediaItem]?

    init(mode: HomeMode = .home, providerLibrary: MediaLibrary? = nil, nativeHub: MediaHub? = nil,
         loadedFeedItems: [MediaItem]? = nil) {
        self.mode = mode
        self.providerLibrary = providerLibrary
        self.nativeHubSource = nativeHub
        self.loadedFeedItems = loadedFeedItems
        // Library mode restores the persisted per-library sort; Home never reads gridSort.
        if case .library(let key, _) = mode {
            self.gridSort = LibrarySettingsManager.shared.getSortOption(for: key)
        } else {
            self.gridSort = .addedAtDesc
        }
        super.init(nibName: nil, bundle: nil)
        if let loadedFeedItems {
            gridItems = loadedFeedItems.map(Optional.some)
            totalGridCount = loadedFeedItems.count
            pageZero = .loaded
        }
        if isDrillInPage {
            // A drill-in like the person page and the standalone detail: the
            // shell has no navigation controller, so it blur-fades in over
            // whatever presented it.
            modalPresentationStyle = .overFullScreen
            transitioningDelegate = blurFade
        }
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
    /// This library's non-empty collections in server order, filled by
    /// refreshThisLibraryHubs. Feeds the Collections row and, while the
    /// Collections view is on, the grid. Kept as-is
    /// when a fetch fails.
    private var libraryCollections: [MediaItem] = []
    /// A provider library's own rows (Continue Watching, Recently Added), the
    /// counterpart of `dataStore.libraryItemsByKey[key]` for Plex.
    private var providerLibraryRows: CachedHomeRail = []
    /// MediaItem hero for a provider library, and for a Jellyfin-only Home.
    private var providerHeroItems: [MediaItem] = []

    /// First page of each collection pinned to this library page, keyed by
    /// `Pin.id`. Missing means not fetched; a failed fetch keeps the last page.
    private var libraryPinItems: [String: [PlexMetadata]] = [:]

    private let dataStore = PlexDataStore.shared
    private let authManager = PlexAuthManager.shared
    private let watchlistService = PlexWatchlistService.shared
    private let recommendationService = PersonalizedRecommendationService.shared

    /// Backmost ambient wash, diffused by the frost above it; latched once per screen
    /// (see updateAmbientIfNeeded()).
    private var ambientView: AmbientBackdropView!
    private var backgroundBlurView: UIVisualEffectView!
    private var backdropView: HeroBackdropView!
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HomeSectionID, HomeItemID>!

    /// Leading-edge guide that stops fast Left swipes escaping to the sidebar mid-row. `didUpdateFocus`
    /// points it at `item - 1`, or leaves it empty at item 0 so focus passes to the sidebar.
    private var leftEdgeFocusGuide: UIFocusGuide!

    /// Full-screen state placeholder (notConnected / loading / error / empty).
    /// `isHidden` toggles based on auth + data-store state precedence
    /// matching `PlexHomeView.body`.
    private var stateView: HomeStateView!
    /// True while `stateView` is showing a state that carries a focusable
    /// action button (.error / .empty). Drives preferredFocusEnvironments so a
    /// contentless Home always has a reachable focus target.
    private var stateViewHasFocusableAction = false
    /// Collection page only: a zero-size focus target that holds focus while
    /// page 0 is in flight, so focus never stays on the library tile under
    /// this modal. Visible only in the loading state (see updateHomeState).
    private let collectionFocusAnchor = PreviewFocusAnchorView()
    /// Transient toast for watchlist-write errors. Bottom-anchored, fades
    /// in when `watchlistService.transientWriteError` becomes non-nil.
    private var watchlistToast: WatchlistToastView!

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

    /// Per-section pagination state, keyed by HomeSectionID.
    private struct PaginationState {
        var loadedItems: [MediaItem]       // initial items + everything paginated in
        /// itemIDs that arrived via loadMoreIfNeeded, the only items allowed to survive a head refresh
        /// as tail extras. Without it, items that fell out of the hub head were re-appended forever.
        var paginatedKeys: Set<String> = []
        var totalSize: Int?
        var nextPage: Page? = nil
        var nativeHead: [MediaItemRef]? = nil
        var nativeHeadItems: [MediaItem]? = nil
        var nativeInitialPage: Page? = nil
        var nativeInitialTotal: Int? = nil
        var nativeRevision = 0
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
    /// The merged Continue Watching row's other copies, by the card shown: a
    /// card's watch-state actions go to every copy, or one would bring it back.
    private var mergedCWOthers: [MediaItemRef: [MediaItem]] = [:]
    private var mergedCWSources: CachedHomeRail = []
    private var isOpeningMergedCW = false
    static let mergedContinueWatchingID = HomeSectionID(raw: "rivulet.continueWatching")
    /// One-shot view-side companion to `pendingCWRemovals`: the shelf slot
    /// (section, tile index) of the removal that triggered the next snapshot
    /// apply, so the visible row can animate a batch DELETE at that index
    /// instead of crossfade-reloading. Consumed by `updateVisibleShelfRows`.
    private var pendingShelfRemoval: (sectionID: HomeSectionID, index: Int)?
    private let paginationPageSize = 24

    // MARK: Library-mode grid state
    //
    // The grid is sparse: one slot per item once the first page reports the total, so the alphabet
    // bar (#308) can jump without loading everything before it. `gridGeneration` bumps on every reset
    // so an in-flight page from an older sort discards itself.

    /// Grid slots as rendered: Plex pages map as they land, provider pages
    /// arrive mapped. nil = not loaded yet. `totalGridCount` long once the
    /// first page has landed. Slot identity is positional (`gridSlotID`), so
    /// a page landing under the focused cell reconfigures it in place instead
    /// of deleting it out from under the engine.
    private var gridItems: [MediaItem?] = []
    /// Authoritative library item count from Plex (drives the sort-header
    /// count and the slot array's length).
    private var totalGridCount = 0
    /// Active sort for the grid. Initialized from LibrarySettingsManager in
    /// `init` for library mode; never read in home mode.
    private var gridSort: LibrarySortOption
    /// Pages (by `gridPageSize` index) fetched or in flight this generation.
    /// A page that fails is removed so scrolling back over it retries.
    private var gridPagesRequested: Set<Int> = []
    /// Generation token — see the MARK comment above.
    private var gridGeneration = 0
    private var providerGridNextPage: Page? = Page(offset: 0, limit: 60)
    private var providerGridLoading = false
    private var providerGridTarget = 0
    private var catalogFilter = MediaCatalogFilter(selectedChoices: [:])
    private var catalogFacets: [MediaCatalogFacet] = []
    private var catalogLoadGeneration = 0
    /// Library grid page size.
    private let gridPageSize = 60
    /// Collection page only: page 0's outcome. An empty `gridItems` reads the
    /// same while the request is in flight, after it failed and after an
    /// empty answer, so updateHomeState reads this instead. Set by
    /// loadGridPage's page 0 success and catch, reset by the retry.
    private enum PageZeroState: Equatable { case loading, loaded, failed(String) }
    private var pageZero: PageZeroState = .loading
    /// Letter → offset table behind the alphabet bar; nil under a non-title
    /// sort or before the counts arrive.
    private var alphabetIndex: LibraryAlphabetIndex?
    /// Slot revealed by the last letter jump. Consumed by
    /// `indexPathForPreferredFocusedView` when Left leaves the bar for the
    /// grid; cleared once focus is in the grid.
    private var pendingGridFocusItem: Int?
    /// The Collections view. While on, `gridItems` is `libraryCollections`
    /// in server order.
    private var gridShowsCollections = false
    private let alphabetBar = LibraryAlphabetBarView()
    private let letterIndicator = LibraryLetterIndicatorView()
    /// Desired bar state; the fade's completion reads it so an interrupted
    /// hide cannot land after a newer show.
    private var alphabetBarShown = false
    /// One-shot: `preferredFocusEnvironments` routes the next focus update to
    /// `pendingGridFocusItem` (strip idle return, letter stepping).
    private var wantsPendingGridFocus = false
    /// A few seconds parked on a letter hands focus back to the grid.
    private var stripIdleWork: DispatchWorkItem?
    private var gridSectionIndex: Int? { sectionsSnapshot.firstIndex(where: { $0.kind == .grid }) }

    // MARK: Fast scroll (held Up/Down)
    //
    // After ~1.5s of a held arrow tvOS hands focus to its hidden fast-scroll index bar, which cannot
    // scroll this self-driven collection. That hand-off is the fast-mode signal: the offset is driven
    // here while the arrow stays down, and release lands focus on the centre tile.

    /// Up/Down arrow currently held, tracked at the controller so a hold that
    /// began on a tile is still known once focus sits on the hidden bar.
    private var heldArrow: UIPress.PressType?
    private var isOnSystemIndexBar = false
    private var fastScrollLink: CADisplayLink?
    private var fastScrollStart: CFTimeInterval = 0
    private var fastScrollLastTick: CFTimeInterval = 0
    /// The single item id of the sort-header section.
    private static let sortHeaderItemID = HomeItemID(sectionID: .sortHeader, itemID: "sort-header")

    private static func gridSlotID(_ index: Int) -> HomeItemID {
        HomeItemID(sectionID: .grid, itemID: "grid-\(index)")
    }

    /// Recommendations state (latched local copy — service caches itself).
    private var recommendations: [PlexMetadata] = []
    /// The profile `recommendations` was built for.
    private var recommendationsUserID = UserDefaults.standard.integer(forKey: PlexProfileSession.contentUserIDKey)
    private var isLoadingRecommendations = false
    private var recommendationsError: String?

    /// Empty-state copy for the current surface, without blaming another backend's library.
    private var emptyStateMessage: String {
        if nativeHubSource != nil || loadedFeedItems != nil { return "This list is empty." }
        switch mode {
        case .discover:
            return discoverModel.nativeSupportedProviders.isEmpty
                ? "Recommendations aren't available right now."
                : "Your server hasn't returned any recommendations yet."
        case .watchlist:
            return "Nothing in your Watchlist yet."
        case .collection:
            return "This collection is empty."
        case .playlists:
            return "No playlists yet."
        case .playlist:
            return "This playlist is empty."
        case .library where providerLibrary != nil:
            return "This library is empty."
        case .home where isJellyfinOnlyHome:
            return ServerDataStore.shared.sources.contains { $0.providerID.hasPrefix("silo:") }
                ? "Your server libraries appear to be empty." : "Your Jellyfin library appears to be empty."
        case .home, .library, .search:
            return "Your Plex library appears to be empty."
        }
    }

    /// Hero gate for every mode, despite the name: `showHomeHero` on Home, `showLibraryHero` (on when
    /// never set) on a library page.
    private var showHomeHero: Bool {
        if nativeHubSource != nil || loadedFeedItems != nil { return false }
        switch mode {
        case .home:
            return UserDefaults.standard.bool(forKey: "showHomeHero")
        case .library:
            return (UserDefaults.standard.object(forKey: "showLibraryHero") as? Bool) ?? true
        case .discover:
            return sectionsSnapshot.contains { $0.kind == .hero }
        case .search:
            return false  // Search has no hero — keyboard + results only
        case .watchlist:
            return false  // Watchlist is the grid alone
        case .collection, .playlist:
            return false  // A collection page is its title and grid
        case .playlists:
            return false  // The playlists grid alone, like Watchlist
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

    /// Search mode's top inset IS the safe area (see `updateContentTopInset`),
    /// so it has to be re-read whenever the search chrome grows or collapses.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateContentTopInset()
    }

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
        // No opaque base behind `backgroundBlurView`, so the blur samples what is behind the home. Search
        // keeps the clear root too: an opaque fill reads as a darker panel against the system surround.
        view.backgroundColor = .clear
        // Collection page: presented over the library through
        // BlurFadeAnimator, which assumes an opaque page.
        if isDrillInPage { view.backgroundColor = .black }

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
            if loadedFeedItems != nil { break }
            if nativeHubSource != nil {
                loadGridPage(containing: 0)
                break
            }
            // Library page: only this library's hubs. Paint from the flat MediaItem cache first, then refresh
            // from the network; the grid's first page loads in parallel.
            Task { @MainActor in
                if await dataStore.paintLibraryItemsFromCacheIfNeeded(forKey: key) {
                    applySnapshot(animated: false)
                    selectHeroItemsIfNeeded()
                    updateHomeState()
                }
                await refreshThisLibraryHubs()
            }
            if let library = providerLibrary,
               let provider = MediaProviderRegistry.shared.provider(for: library.providerID) as? SiloProvider {
                loadCatalogState(library: library, provider: provider)
            } else {
                loadGridPage(containing: 0)
            }
            loadAlphabetIndex()
        case .discover:
            // Native recommendations work independently of Plex's curated lists.
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
        case .watchlist:
            // Watchlist page: the service paints from its disk cache in init,
            // so the grid is already populated on a warm launch; this refresh
            // reconciles it with the account (subject to the 60s staleness
            // window the service enforces).
            Task { @MainActor in
                isLoadingWatchlist = watchlistService.watchlistItems.isEmpty
                updateHomeState()
                await watchlistService.fetchWatchlist()
                applySnapshot(animated: false)
                await reloadNativeWatchlist()
                isLoadingWatchlist = false
                updateHomeState()
            }
        case .playlists:
            // A server's playlists, whole in page 0.
            loadGridPage(containing: 0)
        case .collection, .playlist:
            // Collection page: its members only. No hubs, hero or alphabet
            // bar. The zero-size anchor is the page's focus target while
            // page 0 loads.
            collectionFocusAnchor.frame = .zero
            view.addSubview(collectionFocusAnchor)
            // A 416-member collection is 70 rows: keep tvOS's fast-scroll
            // index bar invisible, as library mode does. It still takes focus
            // on a held Up/Down, which starts the page's own fast scroll.
            collectionView.showsVerticalScrollIndicator = false
            collectionView.indexDisplayMode = .alwaysHidden
            loadGridPage(containing: 0)
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

    /// Native recommendations and, with Plex, curated lists and library matches.
    private let discoverModel = DiscoverViewModel()
    private var isLoadingDiscover = false
    /// Watchlist mode only: true while the first fetch of a cold (uncached)
    /// watchlist is in flight, so the surface shows the loading state instead
    /// of "Nothing in your Watchlist yet."
    private var isLoadingWatchlist = false
    private var nativeWatchlistItems: [MediaItem] = []
    private var nativeWatchlistErrors: [String: String] = [:]
    private var nativeFeedGeneration = 0
    private var nativeRows: [HomeSectionID: CachedHomeHub] = [:]
    private var providerFeedTask: Task<Void, Never>?
    private var nativeErrorMessages: [HomeSectionID: String] = [:]
    private var nativeHubAwaitingVisibility = false

    private func nativeErrorSections(_ errors: [String: String]) -> [HomeSectionData] {
        let errors = errors.merging(ServerDataStore.shared.visibilityErrors) { feed, visibility in "\(feed)\n\(visibility)" }
        return errors.keys.sorted().map { providerID in
            let id = HomeSectionID(raw: "nativeError:\(providerID)")
            let name = MediaProviderRegistry.shared.provider(for: providerID)?.displayName ?? providerID
            nativeErrorMessages[id] = "\(name): \(errors[providerID] ?? "")"
            return HomeSectionData(id: id, kind: .recommendationsError, title: nil,
                                   headerStyle: .swiftUIInfiniteRow, totalSize: nil, items: [],
                                   watchlistItems: [], heroItems: [], hubKey: nil, hubIdentifier: nil)
        }
    }
    private var nativeVisibleLibraryKeys: Set<String> = []

    private func reconciledNativeItems(_ row: CachedHomeHub) -> [MediaItem] {
        let id = HomeSectionID(raw: row.id)
        nativeRows[id] = row
        let initial: [MediaItem]
        if case .home = mode {
            initial = ServerDataStore.shared.homeRows.first { $0.id == row.id }?.items ?? row.items
        } else {
            initial = row.items
        }
        let refs = initial.map(\.ref)
        var state = paginationStates[id] ?? PaginationState(
            loadedItems: initial, totalSize: row.totalSize,
            isLoadingMore: false, hasReachedEnd: row.nextPage == nil)
        if state.nativeHeadItems != initial || state.nativeInitialPage != row.nextPage
            || state.nativeInitialTotal != row.totalSize {
            let headKeys = Set(initial.map { $0.ref.itemID })
            state.paginatedKeys.subtract(headKeys)
            let extras = state.loadedItems.filter { state.paginatedKeys.contains($0.ref.itemID) }
            state.loadedItems = initial + extras
            if state.nativeHead != refs || state.nativeInitialPage != row.nextPage {
                state.nextPage = row.nextPage
            }
            state.totalSize = row.totalSize
            state.hasReachedEnd = state.nextPage == nil
            state.nativeHead = refs
            state.nativeHeadItems = initial
            state.nativeInitialPage = row.nextPage
            state.nativeInitialTotal = row.totalSize
            state.nativeRevision += 1
            state.isLoadingMore = false
            paginationStates[id] = state
        }
        return visibleNativeItems(state.loadedItems)
    }

    private func nativeSection(_ row: CachedHomeHub) -> HomeSectionData {
        let id = HomeSectionID(raw: row.id)
        let items = reconciledNativeItems(row)
        let providerID = row.nativeProviderID ?? row.items.first?.ref.providerID
        let name = ServerDataStore.shared.labelsServers
            ? providerID.flatMap { MediaProviderRegistry.shared.provider(for: $0)?.displayName } : nil
        if row.style == .hero {
            return HomeSectionData(id: id, kind: .hero, title: row.title,
                                   headerStyle: .swiftUIInfiniteRow, totalSize: row.totalSize,
                                   items: [], watchlistItems: [], heroItems: [], heroMediaItems: items,
                                   hubKey: nil, hubIdentifier: row.hubIdentifier, sourceBadge: name)
        }
        var section = HomeSectionData.hub(id: id, title: row.title, items: items,
                                         isContinueWatching: row.isContinueWatching, hubKey: nil,
                                         hubIdentifier: row.hubIdentifier,
                                         totalSize: paginationStates[id]?.totalSize ?? row.totalSize)
        section.sourceBadge = name
        return section
    }

    private func visibleNativeItems(_ items: [MediaItem]) -> [MediaItem] {
        ServerDataStore.shared.visibleItems(items)
    }

    private func authorizedFeedItems(_ items: [MediaItem]) -> [MediaItem] {
        visibleNativeItems(items.filter { MediaProviderRegistry.shared.provider(for: $0.ref.providerID) != nil })
    }

    /// The merged shelf stays cheap. Resolve its native continuation only when See All is requested.
    private func openMergedContinueWatching() {
        guard !isOpeningMergedCW else { return }
        isOpeningMergedCW = true
        let generation = nativeFeedGeneration
        let sources = mergedCWSources
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isOpeningMergedCW = false }
            do {
                var lists: [[MediaItem]] = []
                for row in sources {
                    let id = HomeSectionID(raw: row.id)
                    var items = row.items
                    if row.nativeProviderID?.hasPrefix("silo:") == true {
                        _ = reconciledNativeItems(row)
                        items = paginationStates[id]?.loadedItems ?? row.items
                        var next = paginationStates[id]?.nextPage
                        var cursors = Set<String>()
                        var seen = Set(items.map(\.ref))
                        if row.canBrowse == true, let providerID = row.nativeProviderID,
                           let hubID = row.providerHubID,
                           let provider = MediaProviderRegistry.shared.provider(for: providerID) {
                            while let page = next {
                                if let cursor = page.cursor, !cursors.insert(cursor).inserted {
                                    throw MediaProviderError.backendSpecific(underlying: "Continue Watching returned a repeated page.")
                                }
                                let result = try await provider.hubItems(hubID, page: page)
                                guard generation == nativeFeedGeneration,
                                      MediaProviderRegistry.shared.provider(for: providerID) != nil else { return }
                                items.append(contentsOf: result.items.filter { seen.insert($0.ref).inserted })
                                next = result.nextPage
                            }
                        }
                    }
                    lists.append(authorizedFeedItems(items))
                }
                await ContinueWatchingRow.shared.resolveIdentities(in: lists, lookupKey: \.lookupKey)
                guard generation == nativeFeedGeneration else { return }
                let cards = ContinueWatchingRow.shared.cards(
                    lists, identity: { $0.identity ?? [] }, lookupKey: \.lookupKey,
                    watched: \.userState.lastViewedAt)
                    .filter { card in !card.copies.contains { self.pendingCWRemovals.contains($0.ref.itemID) } }
                let controller = PlexHomeViewController(
                    mode: .library(key: Self.mergedContinueWatchingID.raw, title: "Continue Watching"),
                    loadedFeedItems: cards.map(\.item))
                present(controller, animated: true)
            } catch {
                guard generation == nativeFeedGeneration else { return }
                watchlistToast.show(message: error.localizedDescription)
            }
        }
    }

    private func loadNativeHubPage(_ row: CachedHomeHub, sectionID: HomeSectionID) async {
        guard row.canBrowse == true, let providerID = row.nativeProviderID, let hubID = row.providerHubID,
              let provider = MediaProviderRegistry.shared.provider(for: providerID),
              var state = paginationStates[sectionID], !state.isLoadingMore,
              let page = state.nextPage else { return }
        let generation = nativeFeedGeneration
        state.isLoadingMore = true
        paginationStates[sectionID] = state
        applySnapshot(animated: false)
        do {
            let result = try await provider.hubItems(hubID, page: page)
            guard generation == nativeFeedGeneration,
                  MediaProviderRegistry.shared.provider(for: providerID) != nil,
                  var current = paginationStates[sectionID], current.nativeRevision == state.nativeRevision else { return }
            var seen = Set(current.loadedItems.map(\.ref))
            let added = result.items.filter { seen.insert($0.ref).inserted }
            current.loadedItems.append(contentsOf: added)
            current.paginatedKeys.formUnion(added.map { $0.ref.itemID })
            current.totalSize = result.total
            current.nextPage = result.nextPage
            current.hasReachedEnd = result.nextPage == nil
            current.isLoadingMore = false
            paginationStates[sectionID] = current
        } catch {
            guard generation == nativeFeedGeneration,
                  paginationStates[sectionID]?.nativeRevision == state.nativeRevision else { return }
            paginationStates[sectionID]?.isLoadingMore = false
            watchlistToast.show(message: error.localizedDescription)
        }
        applySnapshot(animated: false)
        if row.style == .hero { reconfigureHeroCell() }
    }

    private func reloadNativeWatchlist() async {
        let generation = nativeFeedGeneration
        let providers = ServerDataStore.shared.sources.compactMap {
            MediaProviderRegistry.shared.provider(for: $0.providerID)
        }.filter { $0.kind != .plex && $0.supportsWatchlist }
        var fetched: [String: [MediaItem]] = [:]
        var errors: [String: String] = [:]
        for provider in providers {
            do { fetched[provider.id] = try await provider.watchlistItems() }
            catch { errors[provider.id] = error.localizedDescription }
        }
        guard generation == nativeFeedGeneration, !Task.isCancelled else { return }
        nativeWatchlistItems = providers.flatMap { provider in
            fetched[provider.id] ?? nativeWatchlistItems.filter { $0.ref.providerID == provider.id }
        }
        nativeWatchlistErrors = errors
        applySnapshot(animated: false)
        updateHomeState()
    }

    private func openNativeHub(_ row: CachedHomeHub) {
        guard row.canBrowse == true, let providerID = row.nativeProviderID, let hubID = row.providerHubID,
              MediaProviderRegistry.shared.provider(for: providerID) != nil else { return }
        let hub = MediaHub(id: hubID, providerID: providerID, title: row.title, style: .shelf, items: [],
                           total: row.totalSize, nextPage: row.nextPage)
        let controller = PlexHomeViewController(mode: .library(key: row.id, title: row.title), nativeHub: hub)
        present(controller, animated: true)
    }

    private func loadProviderGridPage(containing index: Int) {
        guard index >= 0 else { return }
        providerGridTarget = max(providerGridTarget, index)
        guard !providerGridLoading, let page = providerGridNextPage else { return }
        // Cursor providers cannot jump to arbitrary offsets. Walk the returned chain up to the requested slot.
        if nativeHubSource != nil || (providerLibrary != nil && !catalogFacets.isEmpty) {
            guard !ServerDataStore.shared.isResolvingVisibility else { return }
            guard gridItems.isEmpty || index >= max(0, gridItems.count - 12) else { return }
        } else {
            guard gridItems.isEmpty || index >= page.offset else { return }
        }
        let providerID = nativeHubSource?.providerID ?? providerLibrary?.providerID
        guard let providerID, let provider = MediaProviderRegistry.shared.provider(for: providerID) else { return }
        let generation = gridGeneration
        let sort = Self.providerSort(gridSort)
        let hub = nativeHubSource
        let library = providerLibrary
        providerGridLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result: PagedResult<MediaItem>
                if let hub { result = try await provider.hubItems(hub.id, page: page) }
                else if let library, provider is SiloProvider, !catalogFacets.isEmpty {
                    result = try await provider.catalogItems(in: library, filter: catalogFilter, sort: sort, page: page)
                } else if let library { result = try await provider.items(in: library, sort: sort, page: page) }
                else { return }
                guard generation == gridGeneration,
                      MediaProviderRegistry.shared.provider(for: providerID) != nil else { return }
                providerGridLoading = false
                providerGridNextPage = result.nextPage
                pageZero = .loaded
                totalGridCount = result.total
                let slots: Range<Int>
                if hub != nil || (provider is SiloProvider && !catalogFacets.isEmpty) {
                    let oldCount = gridItems.compactMap { $0 }.count
                    var loaded = gridItems.compactMap { $0 }
                    var seen = Set(loaded.map(\.ref))
                    loaded.append(contentsOf: visibleNativeItems(result.items).filter { seen.insert($0.ref).inserted })
                    gridItems = loaded.map(Optional.some)
                    if result.nextPage != nil { gridItems.append(nil) }
                    slots = oldCount..<gridItems.count
                } else {
                    let slotCount = max(result.total, page.offset + result.items.count)
                    gridItems = Array(gridItems.prefix(slotCount))
                        + Array(repeating: nil, count: max(0, slotCount - gridItems.count))
                    slots = Self.gridSlotRange(start: page.offset, returned: result.items.count, slotCount: gridItems.count)
                    for (offset, item) in result.items.enumerated() where slots.contains(page.offset + offset) {
                        gridItems[page.offset + offset] = item
                    }
                }
                applySnapshot(animated: false)
                reconfigureGridSlots(slots)
                refreshSortHeaderCount()
                updateHomeState()
                if let next = providerGridNextPage,
                   ((hub != nil || (provider is SiloProvider && !catalogFacets.isEmpty))
                    ? gridItems.count <= providerGridTarget + 12 : next.offset <= providerGridTarget) {
                    loadProviderGridPage(containing: providerGridTarget)
                }
            } catch {
                guard generation == gridGeneration else { return }
                providerGridLoading = false
                if page.offset == 0 { pageZero = .failed(error.localizedDescription) }
                updateHomeState()
            }
        }
    }
    private func nativeAuthorityChanged() {
        nativeFeedGeneration += 1
        catalogLoadGeneration += 1
        catalogFacets = []
        catalogFilter = MediaCatalogFilter(selectedChoices: [:])
        searchTask?.cancel()
        searchToken += 1
        nativePeopleResults = []
        searchPeopleScope = [:]
        requestsSearchProvider = nil
        jellyfinSearchResults = []
        lastSubmittedQuery = ""
        providerFeedTask?.cancel()
        nativeRows = [:]
        paginationStates = [:]
        nativeWatchlistItems = []
        nativeWatchlistErrors = [:]
        nativeErrorMessages = [:]
        heroWatchlistRef = nil
        if providerLibrary != nil || nativeHubSource != nil {
            resetGrid()
            providerLibraryRows = []
            providerHeroItems = []
            libraryCollections = []
            if isSignedIn {
                if let library = providerLibrary,
                   let provider = MediaProviderRegistry.shared.provider(for: library.providerID) as? SiloProvider {
                    loadCatalogState(library: library, provider: provider)
                } else { loadGridPage(containing: 0) }
            }
        }
        switch mode {
        case .discover:
            discoverModel.invalidate()
            isLoadingDiscover = true
            providerFeedTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await discoverModel.load()
                guard !Task.isCancelled else { return }
                isLoadingDiscover = false
                applySnapshot(animated: false)
                updateHomeState()
            }
        case .watchlist:
            providerFeedTask = Task { [weak self] in await self?.reloadNativeWatchlist() }
        case .search:
            submitSearch()
        default: break
        }
        applySnapshot(animated: false)
        updateHomeState()
    }
    /// Original TMDB items per discover section, aligned index-for-index with
    /// the section's mapped MediaItems. Context menus and the hero need the
    /// TMDB originals (watchlist guid construction, library matching).
    private var discoverListItems: [HomeSectionID: [TMDBListItem]] = [:]

    /// Give the first native recommendation row the same hero treatment as
    /// Discover's curated feed, without adding a second copy of its cards.
    /// Explicit server styles and the remaining curation order stay intact.
    static func nativeDiscoverRows(_ rows: CachedHomeRail) -> CachedHomeRail {
        var rows = rows.filter { !$0.items.isEmpty }
        if !rows.contains(where: { $0.style == .hero }),
           let first = rows.first, first.style == .shelf,
           first.items.contains(where: { $0.artwork.backdrop != nil }) {
            rows[0].style = .hero
        }
        return rows
    }

    private func computeDiscoverSections() -> [HomeSectionData] {
        var sections: [HomeSectionData] = []
        let nativeRows = Self.nativeDiscoverRows(discoverModel.nativeHubs
            .filter { LibrarySettingsManager.shared.areServerLibrariesVisible($0.providerID) }
            .map { hub in
                var row = ServerDataStore.row(hub)
                row.items = visibleNativeItems(row.items)
                return row
            })
        for row in nativeRows {
            sections.append(nativeSection(row))
        }
        discoverListItems = [:]

        let heroTMDB = discoverModel.heroItems
        if !heroTMDB.isEmpty, !nativeRows.contains(where: { $0.style == .hero }) {
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

        return sections + nativeErrorSections(discoverModel.nativeErrors)
    }

    // MARK: - Search mode

    // Search: short debounce, token race protection, 2-char minimum, visible-library filtering, and
    // recents in UserDefaults.
    private var searchQuery = ""
    private var searchResults: [PlexMetadata] = []
    /// Jellyfin results for the current query; mixed into Plex's groups.
    private var jellyfinSearchResults: [MediaItem] = []
    private var nativePeopleResults: [MediaPersonResult] = []
    private var searchPeopleScope: [String: [String]] = [:]
    private var requestsSearchProvider: SiloProvider?
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
    /// The Apple TV app has none; this spares a remote server a request per key.
    private static let searchDebounceNs: UInt64 = 100_000_000
    private static let maxRecentSearches = 10
    private static let recentSearchItemsKey = "recentSearchItems"

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAwaitingSearchResults: Bool {
        guard trimmedSearchQuery.count >= Self.searchMinQueryLength else { return false }
        return isSearchLoading || lastSubmittedQuery != trimmedSearchQuery
    }

    /// Recently Searched is the items you OPENED from search, not the queries
    /// you typed (#292) — that is what the Apple TV app's row shows, and it is
    /// what makes a card able to carry artwork. `MediaItem` is already
    /// `Codable`, so it stores whole.
    private var recentSearchItems: [MediaItem] {
        let data = UserDefaults.standard.data(forKey: Self.recentSearchItemsKey) ?? Data()
        return (try? JSONDecoder().decode([MediaItem].self, from: data)) ?? []
    }

    private func saveRecentSearchItem(_ item: MediaItem) {
        var items = recentSearchItems
        items.removeAll { $0.ref == item.ref }
        items.insert(item, at: 0)
        if items.count > Self.maxRecentSearches {
            items = Array(items.prefix(Self.maxRecentSearches))
        }
        UserDefaults.standard.set(
            (try? JSONEncoder().encode(items)) ?? Data(), forKey: Self.recentSearchItemsKey)
    }

    private func removeRecentSearchItem(_ item: MediaItem) {
        let items = recentSearchItems.filter { $0.ref != item.ref }
        UserDefaults.standard.set(
            (try? JSONEncoder().encode(items)) ?? Data(), forKey: Self.recentSearchItemsKey)
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
            jellyfinSearchResults = []
            nativePeopleResults = []
            searchPeopleScope = [:]
            requestsSearchProvider = nil
            lastSubmittedQuery = ""
            applySnapshot(animated: false)
            return
        }

        searchTask?.cancel()
        searchToken += 1
        let currentToken = searchToken
        // Re-render now: "Searching" shows only when there are no results to keep.
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
        if trimmed == lastSubmittedQuery && !(searchResults.isEmpty && jellyfinSearchResults.isEmpty && nativePeopleResults.isEmpty) { return }

        searchTask?.cancel()
        searchToken += 1
        let currentToken = searchToken
        Task { await performSearch(query: trimmed, token: currentToken) }
    }

    /// Alternates two servers' results, each in its own relevance order, so
    /// neither server's best match sinks under the other's whole list. A
    /// title on both servers shows once per server.
    static func interleave(_ a: [MediaItem], _ b: [MediaItem]) -> [MediaItem] {
        var mixed: [MediaItem] = []
        mixed.reserveCapacity(a.count + b.count)
        for i in 0..<max(a.count, b.count) {
            if i < a.count { mixed.append(a[i]) }
            if i < b.count { mixed.append(b[i]) }
        }
        return mixed
    }

    /// An error only when no server returned anything: one server down must
    /// not hide the other's results, and "No results" must not show while a
    /// server failed.
    static func searchErrorMessage(plex: Result<[PlexMetadata], Error>,
                                   jellyfin: Result<[MediaItem], Error>) -> String? {
        let found = ((try? plex.get()) ?? []).count + ((try? jellyfin.get()) ?? []).count
        guard found == 0 else { return nil }
        if case .failure(let error) = plex { return error.localizedDescription }
        if case .failure(let error) = jellyfin { return error.localizedDescription }
        return nil
    }

    /// Not signed in is an empty answer, not a failure.
    private func plexSearch(_ query: String) async -> Result<[PlexMetadata], Error> {
        guard let serverURL = authManager.selectedServerURL,
              let authToken = authManager.selectedServerToken else { return .success([]) }
        do {
            return .success(try await PlexNetworkManager.shared.search(
                serverURL: serverURL, authToken: authToken, query: query, start: 0, size: 80))
        } catch {
            return .failure(error)
        }
    }

    /// Every other server, searched at once. One server down only loses its
    /// own results; a failure counts only when every server failed.
    private func otherServersSearch(_ query: String) async -> Result<[MediaItem], Error> {
        let store = ServerDataStore.shared
        let providers = store.sources.compactMap { MediaProviderRegistry.shared.provider(for: $0.providerID) }
            .filter { LibrarySettingsManager.shared.areServerLibrariesVisible($0.id) }
        guard !providers.isEmpty else { return .success([]) }
        let results = await withTaskGroup(of: (Int, Result<[MediaItem], Error>).self) { group in
            for (index, provider) in providers.enumerated() {
                let all = store.libraries.filter { $0.providerID == provider.id }
                let visible = store.visibleLibraries.filter { $0.providerID == provider.id }.map(\.id)
                group.addTask {
                    do {
                        // Hidden libraries' results stay out, as they do for Plex.
                        let items = visible.count < all.count
                            ? try await provider.search(query, inLibraries: visible)
                            : try await provider.search(query)
                        return (index, .success(items))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }.sorted { $0.key < $1.key }.map(\.value)
        }
        let found = results.compactMap { try? $0.get() }
        if found.isEmpty, case .failure(let error)? = results.first { return .failure(error) }
        return .success(found.flatMap { $0 })
    }

    private func performSearch(query: String, token: Int) async {
        guard authManager.selectedServerToken != nil || ServerDataStore.shared.isSignedIn else { return }

        isSearchLoading = true
        searchError = nil

        async let plex = plexSearch(query)
        async let jellyfin = otherServersSearch(query)
        async let people = searchNativePeople(query)
        async let requests = authorizedRequestsProvider()
        let (plexResult, jellyfinResult, peopleResult, requestProvider) = await (plex, jellyfin, people, requests)
        guard token == searchToken else { return }

        let filteredPlex = plexResult.map { filterSearchResults($0) }
        searchResults = (try? plexResult.get()) ?? []
        jellyfinSearchResults = visibleNativeItems((try? jellyfinResult.get()) ?? [])
        nativePeopleResults = peopleResult.results
        searchPeopleScope = peopleResult.scopes
        requestsSearchProvider = requestProvider
        isSearchLoading = false
        searchError = peopleResult.results.isEmpty
            ? Self.searchErrorMessage(plex: filteredPlex, jellyfin: jellyfinResult) : nil
        lastSubmittedQuery = query
        applySnapshot(animated: false)
        reconfigureVisibleSearchCells()
    }

    private func searchNativePeople(_ query: String) async -> (results: [MediaPersonResult], scopes: [String: [String]]) {
        let store = ServerDataStore.shared
        let providers = store.sources.compactMap { MediaProviderRegistry.shared.provider(for: $0.providerID) as? SiloProvider }
            .filter { LibrarySettingsManager.shared.areServerLibrariesVisible($0.id) }
        let scopes = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider.id, store.visibleLibraries.filter { $0.providerID == provider.id }.map(\.id))
        })
        let found = await withTaskGroup(of: [MediaPersonResult].self) { group in
            for provider in providers {
                guard let scope = scopes[provider.id], !scope.isEmpty else { continue }
                group.addTask { (try? await provider.searchPeople(query, inLibraries: scope)) ?? [] }
            }
            var found: [MediaPersonResult] = []
            for await results in group { found.append(contentsOf: results) }
            return found
        }
        return (found, scopes)
    }

    private func authorizedRequestsProvider() async -> SiloProvider? {
        let store = ServerDataStore.shared
        for source in store.sources where LibrarySettingsManager.shared.areServerLibrariesVisible(source.providerID) {
            guard let provider = MediaProviderRegistry.shared.provider(for: source.providerID) as? SiloProvider,
                  store.visibleLibraries.contains(where: { $0.providerID == provider.id }) else { continue }
            if let capability = try? await SiloRequests(provider: provider).status(), capability.isAvailable {
                return provider
            }
        }
        return nil
    }

    /// Dedupe + restrict to known types + pinned/visible libraries.
    /// Port of PlexSearchView.filteredResults.
    private var filteredSearchResults: [PlexMetadata] { filterSearchResults(searchResults) }

    private func filterSearchResults(_ results: [PlexMetadata]) -> [PlexMetadata] {
        if let plex = MediaProviderRegistry.shared.plexProvider,
           !LibrarySettingsManager.shared.areServerLibrariesVisible(plex.id) { return [] }
        // The section-attribution predicate Home's hero and Continue Watching use. It also normalizes
        // `librarySectionKey` ("/library/sections/3") against `PlexLibrary.key` ("3").
        let visibleKeys = PlexLibraryVisibilityFilter.normalizedKeySet(
            dataStore.visibleLibraries.map { $0.key }
        )
        let types = Set(["movie", "show", "season", "episode", "artist", "album", "track"])
        var seen = Set<String>()

        return results.filter { item in
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
        // A request in flight keeps the previous results on screen, as the
        // Apple TV app does; the state cell shows only with nothing to keep.
        if searchError != nil {
            return [.searchState()]
        }

        let filtered = filteredSearchResults
        let jellyfin = visibleNativeItems(jellyfinSearchResults)
        guard !filtered.isEmpty || !jellyfin.isEmpty || !nativePeopleResults.isEmpty else { return [.searchState()] }

        // Same grouping as PlexSearchView.groupedResults, each group mixing
        // both servers (Jellyfin music is not browsable yet, so Music is Plex's).
        let groups: [(key: String, title: String, metas: [PlexMetadata], jellyfin: [MediaItem])] = [
            ("titles", "Movies & TV", filtered.filter { $0.type == "movie" || $0.type == "show" },
             jellyfin.filter { $0.kind == .movie || $0.kind == .show }),
            ("episodes", "Episodes & Seasons", filtered.filter { $0.type == "episode" || $0.type == "season" },
             jellyfin.filter { $0.kind == .episode || $0.kind == .season }),
            ("music", "Music", filtered.filter { $0.type == "artist" || $0.type == "album" || $0.type == "track" }, [])
        ]

        var sections: [HomeSectionData] = []
        for group in groups where !(group.metas.isEmpty && group.jellyfin.isEmpty) {
            let id = HomeSectionID.searchGroup(group.key)
            sections.append(.searchGrid(id: id, title: group.title,
                                        items: Self.interleave(mapToMediaItems(group.metas), group.jellyfin)))
            // Music routing reads metas index-for-index; only an unmixed group
            // keeps that alignment, and only Music needs it.
            if group.jellyfin.isEmpty { searchGroupMetas[id] = group.metas }
        }
        if !nativePeopleResults.isEmpty {
            let people = nativePeopleResults.map { result in
                MediaItem(ref: MediaItemRef(providerID: result.providerID, itemID: result.person.id),
                          kind: .person, title: result.person.name, sortTitle: nil, overview: nil,
                          year: nil, contentRating: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
                          episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                          userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false),
                          artwork: MediaArtwork(poster: result.person.imageURL, backdrop: nil, thumbnail: nil, logo: nil),
                          parentArtwork: nil, grandparentArtwork: nil)
            }
            sections.append(.searchGrid(id: .searchGroup("people"), title: "People", items: people))
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
                (collectionView.cellForItem(at: indexPath) as? SearchRecentsCell)?
                    .configure(recentItems: recentSearchItems)
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
        return requestsSearchProvider == nil ? .noResults : .noResultsWithRequests
    }

    /// Tap routing for search results: music has its own routing
    /// (artist/album → Music page, track → play now); everything else
    /// opens the preview carousel over the tapped group — the same experience
    /// as tapping a library grid tile.
    private func handleSearchTap(section: HomeSectionData, indexPath: IndexPath) {
        if section.id == .searchGroup("people") {
            guard let result = nativePeopleResults[safe: indexPath.item],
                  let provider = MediaProviderRegistry.shared.provider(for: result.providerID) as? SiloProvider,
                  let scope = searchPeopleScope[result.providerID],
                  Set(scope) == Set(ServerDataStore.shared.visibleLibraries.filter { $0.providerID == result.providerID }.map(\.id)),
                  let detail = try? PersonDetailViewController.silo(result: result, provider: provider, inLibraries: scope)
            else { return }
            detail.onSelectItem = { [weak self] item in self?.selectMediaItem(item) }
            present(detail, animated: true)
            return
        }
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
        // Recently Searched is written HERE, on open, not on submit: the row
        // shows what you went to, not what you typed (#292). Music returns
        // above, so its 1:1 artwork never lands in a 2:3 card.
        if indexPath.item < section.items.count {
            saveRecentSearchItem(section.items[indexPath.item])
        }
        presentPreview(forSection: section, indexPath: indexPath)
    }

    /// Library-mode data load: this library's hubs into `dataStore.libraryHubs`.
    private func refreshThisLibraryHubs() async {
        guard nativeHubSource == nil, loadedFeedItems == nil else { return }
        if let library = providerLibrary {
            await refreshProviderLibrary(library)
            return
        }
        guard case .library(let key, _) = mode,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        isLoadingLibraryHubs = (dataStore.libraryHubs[key] == nil)
        updateHomeState()
        // The Collections list (type 18), fetched beside the hubs and awaited
        // before the apply. No sort: the server's titleSort order is
        // Kometa's curation.
        // ponytail: one page of 1000; a library with more collections is
        // truncated. Page on totalSize if one ever gets there.
        async let collectionsFetch = PlexNetworkManager.shared.getLibraryItemsWithTotal(
            serverURL: serverURL, authToken: token, sectionId: key,
            start: 0, size: 1000, type: 18
        )
        do {
            let hubs = try await PlexNetworkManager.shared.getLibraryHubs(
                serverURL: serverURL, authToken: token, sectionId: key
            )
            dataStore.libraryHubs[key] = hubs
            // Project to the MediaItem rail the library page renders from; also bumps libraryHubsVersion and
            // writes the flat library cache for next launch.
            dataStore.projectLibraryItems(forKey: key)
            libraryHubsError = nil
        } catch {
            // Keep stale content if we have any; only surface the error when
            // there's nothing to show (mirrors the home's hubsError handling).
            if (dataStore.libraryHubs[key] ?? []).isEmpty {
                libraryHubsError = error.localizedDescription
            }
        }
        // Assigned only on success: a failed fetch keeps the previous list and
        // never surfaces as a library error. `childCount > 0` drops the empty
        // ones (Kometa separators, emptied lists) at no request cost.
        var collectionsChanged = false
        if let result = try? await collectionsFetch {
            let collections = result.items.filter { ($0.childCount ?? 0) > 0 }
            // Every player exit comes through here and the list almost never
            // changes then, so an equal ratingKey sequence skips the follow-ups.
            let mapped = collections.map(mediaItemMapper())
            collectionsChanged = mapped.map(\.ref.itemID) != libraryCollections.map(\.ref.itemID)
            libraryCollections = mapped
            // Pinned Home rows take Plex's current collection titles. Every
            // successful fetch, not only a changed list: a rename keeps the
            // ratingKey, so it reads as an unchanged list. Writes nothing
            // unless a pinned title differs.
            if let libraryUUID = dataStore.libraries.first(where: { $0.key == key })?.uuid {
                HomeCollectionPins.updateTitles(from: collections, libraryUUID: libraryUUID)
            }
        }
        await fetchLibraryPins()
        isLoadingLibraryHubs = false
        applySnapshotKeepingFocusedRowStill()
        // The sort header's item id never changes, so the apply above never
        // re-vends it; without this it keeps whatever list it first saw, and
        // the View menu's Collections item (offered only while the list is
        // not empty) would stay missing, or linger after the list emptied.
        if collectionsChanged { refreshSortHeaderCount() }
        selectHeroItemsIfNeeded()
        updateHomeState()
        syncCollectionsGrid()
    }

    /// The provider half of `refreshThisLibraryHubs`: rows, collections and
    /// hero for a non-Plex library. A failed fetch keeps what was there.
    private func refreshProviderLibrary(_ library: MediaLibrary) async {
        guard let provider = MediaProviderRegistry.shared.provider(for: library.providerID) else { return }
        let generation = nativeFeedGeneration
        async let rows = provider.hubs(in: library)
        async let collections = provider.collections(in: library)
        var heroChanged = false
        do {
            let fetchedRows = try await rows.map(ServerDataStore.row)
            guard generation == nativeFeedGeneration,
                  MediaProviderRegistry.shared.provider(for: library.providerID) != nil else { return }
            providerLibraryRows = fetchedRows
            let hero = Self.heroItems(from: providerLibraryRows)
            heroChanged = hero.map(\.ref.itemID) != providerHeroItems.map(\.ref.itemID)
            providerHeroItems = hero
        } catch {
            homeUIKitLog.debug("[Library] provider rows fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        var collectionsChanged = false
        do {
            let collections = try await collections
            guard generation == nativeFeedGeneration,
                  MediaProviderRegistry.shared.provider(for: library.providerID) != nil else { return }
            collectionsChanged = collections.map(\.ref.itemID) != libraryCollections.map(\.ref.itemID)
            libraryCollections = collections
        } catch {
            homeUIKitLog.debug("[Library] provider collections fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        if heroChanged { heroCurrentIndex = 0 }
        applySnapshotKeepingFocusedRowStill()
        if collectionsChanged { refreshSortHeaderCount() }
        // The hero cell's item id is constant, so the apply above never
        // re-vends it; without this it keeps the first list while the
        // backdrop reads the new one.
        if heroChanged { reconfigureHeroCell() }
        updateBackdropForCurrentHeroItem()
        updateHomeState()
        syncCollectionsGrid()
    }

    /// Fetches the first page of every collection pinned to this library page.
    /// A 404 unpins (deleted, or no longer visible to this profile), the same
    /// rule `PlexDataStore.loadPinnedCollections` applies to Home pins.
    private func fetchLibraryPins() async {
        guard case .library(let key, _) = mode,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let libraryUUID = dataStore.libraries.first(where: { $0.key == key })?.uuid else { return }
        let pins = HomeCollectionPins.pins(in: .library).filter { $0.libraryUUID == libraryUUID }
        await withTaskGroup(of: (HomeCollectionPins.Pin, [PlexMetadata]?, Bool).self) { group in
            for pin in pins {
                group.addTask {
                    do {
                        let page = try await PlexNetworkManager.shared.getHubItems(
                            serverURL: serverURL, authToken: token, hubKey: pin.childrenKey)
                        return (pin, page.items, false)
                    } catch PlexAPIError.httpError(let statusCode, _) where statusCode == 404 {
                        return (pin, nil, true)
                    } catch {
                        return (pin, nil, false)
                    }
                }
            }
            for await (pin, items, gone) in group {
                if gone {
                    libraryPinItems[pin.id] = nil
                    HomeCollectionPins.unpin(ratingKey: pin.ratingKey, libraryUUID: libraryUUID, in: .library)
                } else if let items {
                    libraryPinItems[pin.id] = items
                }
            }
        }
    }

    /// The pinned rows this library page draws, in pin order: this library's
    /// pins that have a non-empty first page and that Plex does not already
    /// show here as a hub (an admin-promoted collection).
    nonisolated static func libraryPinRows(pins: [HomeCollectionPins.Pin],
                                           libraryUUID: String,
                                           hubKeys: Set<String>,
                                           fetched: [String: [PlexMetadata]])
        -> [(pin: HomeCollectionPins.Pin, items: [PlexMetadata])] {
        pins.compactMap { pin in
            guard pin.libraryUUID == libraryUUID, !hubKeys.contains(pin.childrenKey),
                  let items = fetched[pin.id], !items.isEmpty else { return nil }
            return (pin, items)
        }
    }

    /// The apply for refreshThisLibraryHubs. The Collections row has no warm cache, so it can appear or
    /// vanish on a live page; shift the offset by however far the apply moved the focused section, or
    /// a row inserted above pushes the focused tile down.
    private func applySnapshotKeepingFocusedRowStill() {
        // Pinned rows arrive the same way, right after it.
        func lateRows() -> [HomeSectionID] {
            sectionsSnapshot.map(\.id).filter { $0 == .libraryCollections || $0.raw.hasPrefix("libraryPin:") }
        }
        let lateRowsBefore = lateRows()
        let focusedID = focusedSectionForHandoff.flatMap { sectionsSnapshot[safe: $0]?.id }
        let minYBefore = focusedID.flatMap { firstItemMinY(ofSection: $0) }
        applySnapshot(animated: false)
        guard lateRows() != lateRowsBefore,
              let focusedID, let minYBefore else { return }
        collectionView.layoutIfNeeded()
        guard let minYAfter = firstItemMinY(ofSection: focusedID) else { return }
        let oldY = collectionView.contentOffset.y
        let newY = max(-collectionView.adjustedContentInset.top, oldY + minYAfter - minYBefore)
        collectionView.contentOffset.y = newY
        // A focus scroll in flight follows its target; move it too or the
        // scroll pulls the page back by the shift.
        if offsetLink != nil {
            offsetTargetY += newY - oldY
        }
    }

    private func firstItemMinY(ofSection id: HomeSectionID) -> CGFloat? {
        guard let section = sectionsSnapshot.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: section))?.frame.minY
    }

    // MARK: - Library grid data

    /// Loads the page holding slot `index` unless it is loaded or in flight.
    /// The first page to land sizes the slot array from Plex's total; a later
    /// page resizes it if the library changed underneath. A landed page
    /// reconfigures its slots in place (positional identity), so the focused
    /// cell is never deleted out from under the engine, and a page that
    /// fails is forgotten so scrolling back over it retries.
    private func loadGridPage(containing index: Int) {
        guard loadedFeedItems == nil else { return }
        // Collections state: the grid is `libraryCollections`, already whole,
        // so `willDisplay`'s look-ahead paging goes inert.
        guard !gridShowsCollections else { return }
        if providerLibrary != nil || nativeHubSource != nil {
            loadProviderGridPage(containing: index)
            return
        }
        guard index >= 0,
              gridItems.isEmpty || index < gridItems.count else { return }
        let pageSize = gridPageSize
        let fetchPage: (Int) async throws -> (items: [MediaItem], totalSize: Int?)
        if case .playlists(let providerID) = mode {
            guard let provider = MediaProviderRegistry.shared.provider(for: providerID) else { return }
            let generation = gridGeneration
            fetchPage = { [weak self] start in
                guard start == 0 else { return ([], nil) }
                let lists = try await provider.videoPlaylists()
                if let self, self.gridGeneration == generation { self.loadedPlaylists = lists }
                return (lists.map(\.item), lists.count)
            }
        } else if case .playlist(let playlist) = mode {
            // Every entry in page 0. Kept whole beside the grid, which has only their items.
            guard let provider = MediaProviderRegistry.shared.provider(for: playlist.item.ref.providerID) else { return }
            let generation = gridGeneration
            fetchPage = { [weak self] start in
                guard start == 0 else { return ([], nil) }
                let entries = try await provider.playlistEntries(playlist.item.ref)
                if let self, self.gridGeneration == generation { self.playlistEntries = entries }
                return (entries.map(\.item), entries.count)
            }
        } else if case .collection(let item) = mode, !item.ref.isPlex {
            // A provider collection (a Jellyfin box set): members arrive whole, so page 0 is the page.
            guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
            fetchPage = { start in
                guard start == 0 else { return ([], nil) }
                let members = try await provider.children(of: item.ref)
                return (members, members.count)
            }
        } else if let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken {
            let network = PlexNetworkManager.shared
            let map = mediaItemMapper()
            if case .library(let key, _) = mode {
                let sort = gridSort.apiParameter
                fetchPage = { start in
                    let result = try await network.getLibraryItemsWithTotal(
                        serverURL: serverURL,
                        authToken: token,
                        sectionId: key,
                        start: start,
                        size: pageSize,
                        sort: sort
                    )
                    return (result.items.map(map), result.totalSize)
                }
            } else if case .collection(let item) = mode {
                // The members through the hub pager, in the collection's own
                // collectionSort (the server ignores sort=). Never getChildren or
                // PlexProvider.children(of:): /library/metadata/{rk}/children
                // returns nothing for a smart collection.
                let childrenKey = "/library/collections/\(item.ref.itemID)/children"
                fetchPage = { start in
                    let result = try await network.getHubItems(
                        serverURL: serverURL,
                        authToken: token,
                        hubKey: childrenKey,
                        start: start,
                        count: pageSize
                    )
                    return (result.items.map(map), result.totalSize)
                }
            } else {
                return
            }
        } else {
            return
        }
        let page = index / gridPageSize
        guard gridPagesRequested.insert(page).inserted else { return }
        let gen = gridGeneration
        let start = page * gridPageSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await fetchPage(start)
                guard gen == self.gridGeneration else { return }
                if page == 0 { self.pageZero = .loaded }
                let total = result.totalSize ?? max(self.gridItems.count, start + result.items.count)
                let countChanged = total != self.gridItems.count
                if countChanged {
                    self.totalGridCount = total
                    self.gridItems = Array(self.gridItems.prefix(total))
                        + Array(repeating: nil, count: max(0, total - self.gridItems.count))
                }
                // A reload can land after the grid shrank below this page's
                // start: the range stays empty instead of trapping on start..<end.
                let slots = Self.gridSlotRange(
                    start: start, returned: result.items.count, slotCount: self.gridItems.count
                )
                for (offset, item) in result.items.enumerated() where slots.contains(start + offset) {
                    self.gridItems[start + offset] = item
                }
                // Same slot count: the identities are unchanged, so patch the page into the
                // rendered sections instead of rebuilding a snapshot of every slot in the library.
                if !countChanged, let grid = self.sectionsSnapshot.firstIndex(where: {
                    if case .grid = $0.kind { $0.items.count == self.gridItems.count } else { false }
                }) {
                    for slot in slots { self.sectionsSnapshot[grid].items[slot] = self.gridItems[slot] ?? .gridPlaceholder }
                } else {
                    self.applySnapshot(animated: false)
                }
                if countChanged || page == 0 {
                    self.refreshSortHeaderCount()
                    self.updateHomeState()
                }
                self.reconfigureGridSlots(slots)
            } catch {
                guard gen == self.gridGeneration else { return }
                self.gridPagesRequested.remove(page)
                if page == 0 { self.pageZero = .failed(error.localizedDescription) }
                // First page: hub rows still render; updateHomeState surfaces
                // a library-level error only when there are no hubs either.
                if self.gridItems.isEmpty { self.updateHomeState() }
            }
        }
    }

    /// Re-vend the cells of a landed page. Slot identifiers never change, so
    /// `applySnapshot` alone leaves the placeholder cards on screen.
    private func reconfigureGridSlots(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        var snap = dataSource.snapshot()
        guard snap.sectionIdentifiers.contains(.grid) else { return }
        snap.reconfigureItems(range.map(Self.gridSlotID))
        dataSource.apply(snap, animatingDifferences: false)
    }

    /// Slots a landed page may write: `start..<end`, with `end` clamped to the
    /// slot count and never below `start`. A reload can answer for a page that
    /// begins past a grid that has since shrunk, and `start..<end` with
    /// `end < start` traps.
    nonisolated static func gridSlotRange(start: Int, returned: Int, slotCount: Int) -> Range<Int> {
        start..<max(start, min(start + returned, slotCount))
    }

    /// Re-requests every loaded grid page in place, for when a member's watch state may have changed.
    /// The generation bump drops in-flight pages, which are re-requested below.
    // ponytail: re-requests every loaded page (a library scrolled deep can hold
    // dozens); fetch only visible pages if it shows up.
    private func reloadLoadedGridPages() {
        if loadedFeedItems != nil {
            applySnapshot(animated: false)
            return
        }
        if providerLibrary != nil || nativeHubSource != nil {
            resetGrid()
            loadGridPage(containing: 0)
            return
        }
        gridGeneration += 1
        let pages = gridPagesRequested
        gridPagesRequested = []
        pages.forEach { loadGridPage(containing: $0 * gridPageSize) }
    }

    // MARK: - Alphabet bar (issue #308)

    /// Fetches the per-letter counts behind the alphabet bar. Title sorts
    /// only: under any other order the letters do not map to offsets.
    private func loadAlphabetIndex() {
        guard nativeHubSource == nil, loadedFeedItems == nil else { return }
        alphabetIndex = nil
        alphabetBarShown = false
        alphabetBar.setLetters([])
        alphabetBar.isHidden = true
        guard case .library(let key, _) = mode,
              !gridShowsCollections,
              gridSort == .titleAsc || gridSort == .titleDesc else { return }
        let gen = gridGeneration
        let descending = gridSort == .titleDesc
        let fetchCounts: () async throws -> [PlexFirstCharacter]
        if let library = providerLibrary {
            guard let provider = MediaProviderRegistry.shared.provider(for: library.providerID) else { return }
            fetchCounts = { try await provider.letterCounts(in: library) }
        } else {
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }
            fetchCounts = {
                try await PlexNetworkManager.shared.getLibraryFirstCharacters(
                    serverURL: serverURL, authToken: token, sectionId: key)
            }
        }
        Task { @MainActor [weak self] in
            guard let characters = try? await fetchCounts(),
                  let self, gen == self.gridGeneration else { return }
            let index = LibraryAlphabetIndex(characters: characters, descending: descending)
            guard index.entries.count > 1 else { return }
            self.alphabetIndex = index
            self.alphabetBar.setLetters(index.entries.map(\.title))
            let focusedKind = self.focusedSectionForHandoff.flatMap { self.sectionsSnapshot[safe: $0]?.kind }
            if focusedKind == .grid, let slot = TileLongPress.focusedCell(in: self.collectionView)?.item {
                self.alphabetBar.entryIndex = index.entryIndex(containing: slot)
            }
            self.setAlphabetBarVisible(focusedKind == .grid)
        }
    }

    /// The bar is up only while focus is in the grid (or on the bar itself).
    /// Hidden, not merely transparent, so it leaves the focus graph.
    private func setAlphabetBarVisible(_ visible: Bool) {
        let show = visible && alphabetIndex != nil
        guard show != alphabetBarShown else { return }
        alphabetBarShown = show
        if !show { letterIndicator.hide() }
        if show { alphabetBar.isHidden = false }
        UIView.animate(withDuration: 0.2, animations: {
            self.alphabetBar.alpha = show ? 1 : 0
        }, completion: { finished in
            // An interrupted fade reports finished == false; only a fade
            // that ran to the end may hide, and only if nothing re-showed.
            if finished, !self.alphabetBarShown { self.alphabetBar.isHidden = true }
        })
    }

    /// Alphabet bar: snap the grid so the first title under the focused
    /// letter heads the viewport. Snapped, not animated: a jump can span
    /// thousands of points, and an animated offset would dequeue hundreds of
    /// cells per frame on the way. The pages behind the new viewport load
    /// through willDisplay like any other scroll.
    private func jumpGrid(toLetterAt index: Int) {
        guard let entry = alphabetIndex?.entries[safe: index],
              let gridSection = sectionsSnapshot.firstIndex(where: { $0.kind == .grid }),
              entry.offset < gridItems.count,
              let attrs = collectionView.layoutAttributesForItem(at: IndexPath(item: entry.offset, section: gridSection))
        else { return }
        offsetLink?.invalidate()
        offsetLink = nil
        // Centre the row, which is where the focus-scroll puts it anyway, so
        // landing on it afterwards does not move the grid a second time.
        let target = attrs.frame.midY - collectionView.bounds.height / 2
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.contentOffset = CGPoint(x: 0, y: max(-collectionView.adjustedContentInset.top, min(target, maxOffset)))
        collectionView.layoutIfNeeded()
        pendingGridFocusItem = entry.offset
    }

    /// Hand focus to the jumped-to slot. Asked through the controller, which
    /// contains the strip: a request naming the cell is dropped while focus
    /// sits outside that cell (measured), the same rule as setNeedsFocusUpdate.
    private func focusPendingGridSlot() {
        guard pendingGridFocusItem != nil else { return }
        wantsPendingGridFocus = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Left, Select, Menu and the idle timer on the strip: back to the grid at
    /// the current letter, failing that the tile nearest the centre.
    private func leaveStrip() {
        stripIdleWork?.cancel()
        // Hidden before the request: visible, it occludes the tiles under it.
        letterIndicator.hide()
        if let grid = gridSectionIndex,
           pendingGridFocusItem.flatMap({ collectionView.cellForItem(at: IndexPath(item: $0, section: grid)) }) == nil {
            pendingGridFocusItem = centerGridIndexPath()?.item
        }
        focusPendingGridSlot()
    }

    /// From a letter, the engine's own Left search lands on the shell's edge
    /// catcher, and Right on a shelf tile peeking past the strip. No
    /// directional move may leave the strip. leaveStrip's own request is not
    /// asked here (measured), so it passes.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // Move mode: focus stays on the held tile, and only its own follow-the-step request passes.
        if let entryMove, entryMove.isMoving {
            guard context.focusHeading.isEmpty, let grid = gridSectionIndex, let next = context.nextFocusedView,
                  let held = collectionView.cellForItem(at: IndexPath(item: entryMove.index, section: grid))
            else { return false }
            return next.isDescendant(of: held)
        }
        if let prev = context.previouslyFocusedView, prev.isDescendant(of: alphabetBar),
           let next = context.nextFocusedView, !next.isDescendant(of: alphabetBar),
           !context.focusHeading.isEmpty || !next.isDescendant(of: view) {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    private func scheduleStripIdleReturn() {
        stripIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.leaveStrip() }
        stripIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
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

    /// Plex's sort list for the matching library type, minus resolution:
    /// Jellyfin cannot sort by it (an unknown sortBy is ignored).
    static func providerSortOptions(for kind: MediaLibrary.LibraryKind) -> [LibrarySortOption] {
        let plexType: String? = switch kind {
        case .movies: "movie"
        case .shows: "show"
        default: nil
        }
        return LibrarySortOption.options(for: plexType).filter { $0 != .resolutionDesc && $0 != .resolutionAsc }
    }

    static func providerSort(_ option: LibrarySortOption) -> SortOption {
        switch option {
        case .addedAtDesc: .addedAtDesc
        case .addedAtAsc: .addedAtAsc
        case .titleAsc: .titleAsc
        case .titleDesc: .titleDesc
        case .releaseDateDesc: .releaseDateDesc
        case .releaseDateAsc: .releaseDateAsc
        case .ratingDesc: .ratingDesc
        case .lastEpisodeAddedDesc: .lastContentAddedDesc
        // Not offered for provider libraries (`providerSortOptions`).
        case .resolutionDesc, .resolutionAsc: .addedAtDesc
        }
    }

    /// The current library's Plex type ("movie", "show", ...), which picks the sort options.
    private var currentLibraryType: String? {
        guard case .library(let key, _) = mode else { return nil }
        return dataStore.libraries.first(where: { $0.key == key })?.type
    }

    /// The sort menu: this library's options, the active one checked.
    private func sortMenu() -> UIMenu {
        let options = providerLibrary.map { Self.providerSortOptions(for: $0.kind) }
            ?? LibrarySortOption.options(for: currentLibraryType)
        var actions: [UIMenuElement] = options.map { option in
            UIAction(title: option.displayName, state: option == gridSort ? .on : .off) { [weak self] _ in
                self?.applySort(option)
            }
        }
        if !catalogFacets.isEmpty {
            actions.append(UIAction(title: "Filters", image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { [weak self] _ in
                self?.showCatalogFilters()
            })
        }
        return UIMenu(children: actions)
    }

    private func loadCatalogState(library: MediaLibrary, provider: SiloProvider) {
        catalogLoadGeneration += 1
        let generation = catalogLoadGeneration
        let revision = provider.authorityRevision
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                async let offered = provider.catalogFacets(in: library)
                async let saved = provider.loadCatalogFilter(in: library)
                let (facets, filter) = try await (offered, saved)
                guard generation == catalogLoadGeneration, revision == provider.authorityRevision,
                      MediaProviderRegistry.shared.provider(for: library.providerID) != nil else { return }
                catalogFacets = facets ?? []
                catalogFilter = filter
            } catch {
                guard generation == catalogLoadGeneration else { return }
                catalogFacets = []
                catalogFilter = MediaCatalogFilter(selectedChoices: [:])
            }
            resetGrid()
            pageZero = .loading
            refreshSortHeaderCount()
            loadGridPage(containing: 0)
        }
    }

    private func showCatalogFilters() {
        guard let library = providerLibrary,
              let provider = MediaProviderRegistry.shared.provider(for: library.providerID) as? SiloProvider,
              !catalogFacets.isEmpty else { return }
        let controller = SiloCatalogFilterViewController(facets: catalogFacets, selection: catalogFilter) { [weak self] selection in
            guard let self else { return }
            let revision = provider.authorityRevision
            Task { @MainActor in
                do {
                    try await provider.saveCatalogFilter(selection, in: library)
                    guard let current = MediaProviderRegistry.shared.provider(for: library.providerID) as? SiloProvider,
                          current.authorityRevision == revision,
                          self.providerLibrary?.settingsKey == library.settingsKey else { return }
                    self.catalogFilter = selection
                    self.resetGrid()
                    self.pageZero = .loading
                    self.applySnapshot(animated: false)
                    self.loadGridPage(containing: 0)
                } catch { return }
            }
        }
        present(controller, animated: true)
    }

    /// Persists the new sort, resets the grid (bumping the generation token
    /// so any in-flight page discards itself), and reloads the first page.
    /// The snapshot + sort-header reconfigure run immediately so the sort
    /// name flips on selection rather than after the fetch resolves.
    private func applySort(_ option: LibrarySortOption) {
        guard case .library(let key, _) = mode, option != gridSort else { return }
        gridSort = option
        LibrarySettingsManager.shared.setSortOption(option, for: key)
        resetGrid()
        // Read only by a provider library: its empty state waits on page 0.
        pageZero = .loading
        applySnapshot(animated: false)
        refreshSortHeaderCount()
        loadGridPage(containing: 0)
        loadAlphabetIndex()
    }

    /// Empties the grid for a new source: a sort change or the Titles /
    /// Collections switch. The generation bump makes any in-flight page
    /// discard itself. The remembered focus path goes off because it can name
    /// a slot the new grid lacks (titles slot 500 in a 71-slot collections
    /// grid), and entering the collection view on such a path moves focus
    /// nowhere. The `.grid` focus branch turns it back on.
    private func resetGrid() {
        gridGeneration += 1
        gridItems = []
        totalGridCount = 0
        gridPagesRequested = []
        providerGridNextPage = Page(offset: 0, limit: gridPageSize)
        providerGridLoading = false
        providerGridTarget = 0
        pendingGridFocusItem = nil
        collectionView.remembersLastFocusedIndexPath = false
    }

    /// Puts the whole collection list into the grid slots, in server order
    /// (`[MediaItem]` upcasts to `[MediaItem?]` implicitly). The
    /// reconfigure is required: `grid-N` ids are the same in both states, so
    /// the apply alone leaves the old posters on screen.
    private func showCollectionsInGrid() {
        gridItems = libraryCollections
        totalGridCount = libraryCollections.count
        applySnapshot(animated: false)
        refreshSortHeaderCount()
        reconfigureGridSlots(0..<gridItems.count)
    }

    /// Titles or Collections. Collections come whole in server order: no paging, A-Z bar or sort
    /// (`sort=mediaHeight:desc` returns an empty list). No focus request: the header re-vends the same
    /// cell, so focus stays on the View button.
    func setGridShowsCollections(_ on: Bool) {
        guard on != gridShowsCollections else { return }
        gridShowsCollections = on
        guard isViewLoaded else { return }
        resetGrid()
        if on {
            showCollectionsInGrid()
        } else {
            // The grid is empty, so there are no slots to reconfigure.
            pageZero = .loading
            applySnapshot(animated: false)
            refreshSortHeaderCount()
            loadGridPage(containing: 0)
        }
        loadAlphabetIndex()
    }

    /// Runs after every library refresh. While the grid shows collections it
    /// holds its own copy of `libraryCollections`; a refreshed list replaces
    /// that copy in place (no `resetGrid()`, which is for user toggles only)
    /// unless the grid is busy.
    private func syncCollectionsGrid() {
        guard gridShowsCollections else { return }
        // Busy: focus in the grid, or anything presented over this page (a
        // collection page opened from the grid, the tile menu popup). Slot
        // ids are positional, so a swap would repaint the focused tile, or
        // the tile focus returns to, with a different collection.
        let focusedSection = focusedSectionForHandoff
        let busy = (focusedSection != nil && focusedSection == gridSectionIndex)
            || presentedViewController != nil
        switch Self.collectionsGridUpdate(
            gridKeys: gridItems.map { $0?.ref.itemID },
            listKeys: libraryCollections.map(\.ref.itemID),
            isGridBusy: busy
        ) {
        case .unchanged:
            break
        case .hold:
            // ponytail: a held swap waits for the next list fetch (the next
            // .plexDataNeedsRefresh); apply it when focus leaves the grid if
            // stale collection posters ever show up in use.
            break
        case .titles:
            setGridShowsCollections(false)
        case .apply:
            showCollectionsInGrid()
        }
    }

    /// What a refreshed collection list does to a grid showing collections.
    nonisolated enum CollectionsGridUpdate { case unchanged, titles, hold, apply }

    /// An empty list returns to Titles first, even under focus and even when
    /// the grid is already empty: with no collections the header hides the
    /// switch, so an empty collections grid would have no way out. Any other
    /// change waits while the grid is busy. Order counts, because the slots
    /// are positional: a reordered list is a change.
    nonisolated static func collectionsGridUpdate(
        gridKeys: [String?], listKeys: [String?], isGridBusy: Bool
    ) -> CollectionsGridUpdate {
        if listKeys.isEmpty { return .titles }
        if gridKeys == listKeys { return .unchanged }
        return isGridBusy ? .hold : .apply
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Collection page: own Menu from the start of the blur-fade (see
        // handleMenuBack). The library that presented it already installed
        // the interceptor; viewDidAppear registering again is harmless.
        if isDrillInPage { MenuPressInterceptor.register(self) }
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Only a real dismissal. A carousel presented over the collection page
        // (.overFullScreen) never makes it disappear at all.
        if isBeingDismissed { onDismiss?() }
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

    /// Focus leaving the whole collection sends no per-cell unfocus, so a TVPosterView can stay enlarged.
    /// When focus returns, clear that look on every visible poster but the newly focused one.
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

    /// Launch focus lands on the hero's Play, not the engine's default (an off-screen CW tile). While
    /// set, preferredFocusEnvironments routes to the hero; cleared once the hero has focus or the user
    /// moves.
    private var needsInitialHeroFocus = true

    private var heroSectionIndex: Int? {
        sectionsSnapshot.firstIndex(where: { $0.kind == .hero })
    }

    /// The section a staged Menu back returns to. Every hero-bearing mode
    /// (home, library, discover) tops out at the hero; Search has no hero, so
    /// its first section is the top.
    private var topSectionIndex: Int {
        heroSectionIndex ?? (isDrillInPage ? gridSectionIndex : nil) ?? 0
    }

    /// Set while a staged Menu back is pulling focus to the top section. Only
    /// used by modes with no hero — hero modes reuse `needsInitialHeroFocus`
    /// so focus lands on Play exactly as it does at launch.
    private var wantsTopFocus = false

    /// Set by `focusRowAbove()` for exactly one focus update: the section whose
    /// first cell should take focus. Cleared as soon as it is read.
    private var pendingRowFocusSection: Int?

    /// Whether the focus engine has moved focus since this was last read.
    /// See the note in `didUpdateFocusIn`; read through `consumeEngineMovedFocus`.
    private var engineMovedFocus = false

    /// The section focus was in most recently. Survives focus leaving the page.
    private(set) var lastFocusedSection: Int?

    /// Read-and-clear: did the engine move focus since the last press?
    func consumeEngineMovedFocus() -> Bool {
        defer { engineMovedFocus = false }
        return engineMovedFocus
    }

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

    /// Top inset: 0 with the hero, otherwise room for the first row.
    private func updateContentTopInset() {
        // Search reads the safe area: measured on tvOS 26.5, the results view stays full screen and
        // publishes `safeAreaInsets.top = 306` for the keyboard chrome, which `.never` would drop. Only the
        // top is read, since the 80pt side insets would shift every row. With no hero, clear the sidebar
        // pill (#298); Search hides the pill instead.
        var noHeroTop = ShellPillMetrics.contentClearance
        if case .search = mode { noHeroTop = view.safeAreaInsets.top }
        let topInset: CGFloat = showHomeHero ? 0 : noHeroTop
        if collectionView.contentInset.top != topInset {
            collectionView.contentInset.top = topInset
        }
    }

    /// Single chokepoint for driving the hero backdrop. Forwards to the view,
    /// and when the URL is nil — no image will ever load — marks the hero ready
    /// immediately so the startup splash doesn't wait for an image that isn't
    /// coming. The non-nil case is reported by `onFirstImageLoaded` once the
    /// image is on screen.
    private func setHeroBackdrop(url: URL?, paging: Bool = false) {
        backdropView.setBackdrop(url: url, paging: paging)
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
        // Discover, provider libraries and a Jellyfin Home use MediaItem hero items; without this branch
        // the guard below clears the backdrop.
        var isMediaItemHero = providerLibrary != nil
        if case .discover = mode { isMediaItemHero = true }
        let isHomeMediaHero = { if case .home = mode { homeHeroSource != .plex } else { false } }()
        if isMediaItemHero || isHomeMediaHero || heroShowsList {
            // Home's list is computed rather than read off the snapshot: the
            // Plex hero paths set the backdrop before they apply, and a stale
            // empty read would release the splash before the image is up.
            let items = heroShowsList ? listHeroItems
                : isHomeMediaHero ? homeMediaHeroItems()
                : sectionsSnapshot.first(where: { $0.kind == .hero })?.heroMediaItems ?? []
            guard showHomeHero, !items.isEmpty else {
                setHeroBackdrop(url: nil)
                return
            }
            let clamped = max(0, min(heroCurrentIndex, items.count - 1))
            updateBackdrop(forMediaItem: items[clamped])
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
    private func updateBackdrop(for item: PlexMetadata, paging: Bool = false) {
        guard showHomeHero,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            setHeroBackdrop(url: nil)
            return
        }
        let request = item.heroBackdropRequest(serverURL: serverURL, authToken: token)
        let url = request.backdropURL ?? request.thumbnailURL
        setHeroBackdrop(url: url, paging: paging)
    }

    /// MediaItem-backed backdrop (Discover hero — TMDB CDN URLs are absolute,
    /// no server/token needed).
    private func updateBackdrop(forMediaItem item: MediaItem, paging: Bool = false) {
        guard showHomeHero else {
            setHeroBackdrop(url: nil)
            return
        }
        let request = item.heroBackdropRequest()
        setHeroBackdrop(url: request.backdropURL ?? request.thumbnailURL, paging: paging)
    }

    /// Discover hero Play, shown only for library-matched items: plays the match directly, falling back
    /// to the carousel.
    private func discoverHeroPlay(_ item: MediaItem) {
        if item.ref.providerID != "tmdb" {
            guard item.isAvailable != false else { return }
            playItem(item)
            return
        }
        guard let heroTMDB = discoverListItems[.hero],
              let index = heroIndex(of: item, in: heroTMDB)
        else { return }
        let tmdbItem = heroTMDB[index]
        Task { @MainActor in
            // Matched in the library: play the file directly, like the home hero's Play.
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
        if item.ref.providerID != "tmdb" {
            applyMediaItemHeroState(for: item, on: cell)
            return
        }
        let matched = item.tmdbID.map { discoverModel.inLibraryTMDBIds.contains($0) } ?? false
        let onWatchlist = item.tmdbID.map { watchlistService.contains(tmdbId: $0) } ?? false
        cell.overlay.setMediaItemPrimaryAction(matchedInLibrary: matched, isOnWatchlist: onWatchlist)
    }

    /// The MediaItem hero's primary action. Discover decides per TMDB title;
    /// a provider library or Home hero shows library items, so always Play,
    /// with the watchlist circle when the slide's server keeps a watchlist.
    private func applyMediaItemHeroState(for item: MediaItem, on cell: HeroOverlayCell?) {
        if case .discover = mode, item.ref.providerID == "tmdb" {
            applyDiscoverHeroState(for: item, on: cell)
            return
        }
        // A watchlist title not in the library: no Play, only its watchlist pill.
        if item.ref.providerID == TMDBMediaMapper.providerID {
            let onWatchlist = item.tmdbID.map { watchlistService.contains(tmdbId: $0) } ?? false
            cell?.overlay.setMediaItemPrimaryAction(matchedInLibrary: false, isOnWatchlist: onWatchlist)
            return
        }
        let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID)
        let canWatchlist = provider?.supportsWatchlist ?? false
        heroWatchlistRef = item.ref
        // A Watchlist hero slide starts bookmarked, so the lookup below does not flash the + first.
        let likelyOnList = heroShowsList && Self.heroContent == .watchlist
            && watchlistHeroItems.contains { $0.ref == item.ref }
        cell?.overlay.setMediaItemPrimaryAction(matchedInLibrary: item.isAvailable != false, isOnWatchlist: likelyOnList,
                                                canWatchlist: canWatchlist)
        guard canWatchlist, let provider else { return }
        let generation = nativeFeedGeneration
        Task { @MainActor [weak self, weak cell] in
            let onList = await provider.isOnWatchlist(item.ref)
            // The slide may have moved on while the provider looked it up.
            guard let self, self.nativeFeedGeneration == generation,
                  self.heroWatchlistRef == item.ref else { return }
            cell?.overlay.setMediaItemPrimaryAction(matchedInLibrary: item.isAvailable != false, isOnWatchlist: onList,
                                                    canWatchlist: true)
        }
    }

    /// The slide `applyMediaItemHeroState` last drew, so a late watchlist
    /// answer for an earlier slide is dropped.
    private var heroWatchlistRef: MediaItemRef?

    /// The hero's watchlist circle for a library item: the slide's own
    /// provider adds or removes it, then the slide redraws from its answer.
    private func toggleProviderWatchlist(for item: MediaItem, on cell: HeroOverlayCell?) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
              provider.supportsWatchlist else { return }
        let generation = nativeFeedGeneration
        Task { @MainActor [weak self, weak cell] in
            let onList = await provider.isOnWatchlist(item.ref)
            guard let self, self.nativeFeedGeneration == generation else { return }
            if onList {
                try? await provider.removeFromWatchlist(item.ref)
            } else {
                try? await provider.addToWatchlist(item.ref)
            }
            guard self.nativeFeedGeneration == generation, self.heroWatchlistRef == item.ref,
                  let cell else { return }
            self.applyMediaItemHeroState(for: item, on: cell)
        }
    }

    /// Toggle the Plex Discover watchlist for a TMDB-mapped MediaItem.
    /// Shared by the hero pill and tile context menus.
    private func toggleDiscoverWatchlist(for item: MediaItem, completion: (() -> Void)? = nil) {
        if item.ref.providerID != "tmdb" {
            toggleProviderWatchlist(for: item, on: nil)
            completion?()
            return
        }
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
    /// in-memory (LibraryGUIDIndex); the matched items arrive in one batched fetch.
    private func upgradeDiscoverItems(_ items: [MediaItem]) async -> [MediaItem] {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return items }
        let providerID = MediaProviderRegistry.shared.plexProvider?.id ?? "plex:\(serverURL)"
        var matches: [(index: Int, entry: LibraryGUIDIndex.Entry)] = []
        for (i, item) in items.enumerated() {
            guard item.ref.providerID == "tmdb",
                  let decoded = TMDBMediaMapper.decodeItemID(item.ref.itemID),
                  item.isMetadataOnly,
                  discoverModel.inLibraryTMDBIds.contains(decoded.tmdbId),
                  let entry = await LibraryGUIDIndex.shared.lookup(tmdbId: decoded.tmdbId, type: decoded.type)
            else { continue }
            matches.append((i, entry))
        }
        guard !matches.isEmpty else { return items }
        let owned = await LibraryGUIDIndex.items(for: matches.map(\.entry), serverURL: serverURL, authToken: token)
        var out = items
        for match in matches {
            guard let plex = owned[match.entry.ratingKey] else { continue }
            out[match.index] = PlexMediaMapper.item(plex, providerID: providerID, serverURL: serverURL, authToken: token)
        }
        return out
    }

    // MARK: - State overlays (loading / empty / error / not-connected,
    //          watchlist toast)

    private func configureStateOverlays() {
        // Full-screen state placeholder.
        stateView = HomeStateView()
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        stateView.onAction = { [weak self] in
            guard let self else { return }
            // Collection page and provider library: Try Again (page 0
            // failed) and Refresh (empty) both ask for page 0 again. A
            // settled empty page 0 is still marked requested, so forget it
            // first.
            let isPlaylists = if case .playlists = self.mode { true } else { false }
            if self.isDrillInPage || isPlaylists || self.providerLibrary != nil {
                self.pageZero = .loading
                self.updateHomeState()
                self.gridPagesRequested.remove(0)
                if self.providerLibrary != nil || self.nativeHubSource != nil { self.resetGrid() }
                self.loadGridPage(containing: 0)
                if self.providerLibrary != nil {
                    self.loadAlphabetIndex()
                    // The rows failed with page 0 too; fetch them again.
                    Task { await self.refreshThisLibraryHubs() }
                }
                return
            }
            if case .discover = self.mode {
                self.nativeAuthorityChanged()
                return
            }
            if case .watchlist = self.mode {
                Task { await self.reloadNativeWatchlist() }
                return
            }
            if case .home = self.mode, ServerDataStore.shared.isSignedIn {
                ServerDataStore.shared.reload()
            }
            if self.isJellyfinOnlyHome { return }
            Task { await self.dataStore.refreshHubs() }
        }
        view.addSubview(stateView)

        // Bottom-anchored toast for watchlist write reverts.
        watchlistToast = WatchlistToastView()
        view.addSubview(watchlistToast)

        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            watchlistToast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            watchlistToast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80)
        ])
    }

    /// Signed in to the server this surface reads. A provider library needs
    /// its own provider; Home and Search take any signed-in server; the rest
    /// are Plex surfaces.
    private var isSignedIn: Bool {
        if let loadedFeedItems {
            if loadedFeedItems.isEmpty { return authManager.hasCredentials || ServerDataStore.shared.isSignedIn }
            return loadedFeedItems.contains { MediaProviderRegistry.shared.provider(for: $0.ref.providerID) != nil }
        }
        if let nativeHubSource {
            return MediaProviderRegistry.shared.provider(for: nativeHubSource.providerID) != nil
        }
        if let providerLibrary {
            return MediaProviderRegistry.shared.provider(for: providerLibrary.providerID) != nil
        }
        switch mode {
        case .home, .search, .discover, .watchlist:
            return authManager.hasCredentials || ServerDataStore.shared.isSignedIn
        case .collection(let item) where !item.ref.isPlex:
            return MediaProviderRegistry.shared.provider(for: item.ref.providerID) != nil
        case .playlist(let playlist):
            return MediaProviderRegistry.shared.provider(for: playlist.item.ref.providerID) != nil
        case .playlists(let providerID):
            return MediaProviderRegistry.shared.provider(for: providerID) != nil
        default:
            return authManager.hasCredentials
        }
    }

    /// Home with Jellyfin signed in and Plex not: its rows, hero, empty
    /// copy and Refresh are Jellyfin's.
    private var isJellyfinOnlyHome: Bool {
        guard case .home = mode else { return false }
        return !authManager.hasCredentials && ServerDataStore.shared.isSignedIn
    }

    /// Page 0's outcome, for surfaces whose content waits on the grid.
    private var pageZeroState: (loading: Bool, error: String?) {
        switch pageZero {
        case .loading: (true, nil)
        case .loaded: (false, nil)
        case .failed(let message): (false, message)
        }
    }

    /// Evaluate auth + data-store state and show the right overlay (or
    /// the home content). Precedence: credentials → data → loading →
    /// error → content.
    private func updateHomeState() {
        let hasCredentials = isSignedIn
        // Data presence/loading/error per mode: the home reads the global hub
        // store; a library page reads its own hub fetch state.
        let isLoadingHubs: Bool
        let hubsError: String?
        let hubsEmpty: Bool
        switch mode {
        case .home:
            let jellyfin = ServerDataStore.shared
            isLoadingHubs = dataStore.isLoadingHubs || isInitialHomeLoadPending
                || (jellyfin.isLoading && jellyfin.homeRows.isEmpty)
                || jellyfin.isResolvingVisibility
            // Without Plex the Plex store's error ("Not authenticated") is not
            // this Home's: a Jellyfin-only Home takes the empty state instead.
            hubsError = (authManager.hasCredentials ? dataStore.hubsError : nil)
                ?? jellyfin.feedErrors.values.sorted().first
            // "Empty" keys off `homeItems`, never `hubs`: on a cold sign-in `hubs` fills before the
            // projection, and a hubs-based check takes the content path with no rows, a blank unfocusable Home.
            // Visible rows only: rows that are all hidden must take the empty
            // state, never the content path with nothing in it.
            hubsEmpty = dataStore.homeItems.isEmpty && jellyfin.visibleHomeRows.isEmpty
        case .library(let key, _):
            if providerLibrary != nil || nativeHubSource != nil || loadedFeedItems != nil {
                // Rows arrive with the provider fetch; until page 0 lands the
                // page is loading, after that the grid decides empty.
                let state = pageZeroState
                isLoadingHubs = state.loading
                // A failed page 0 with rows in hand still shows the rows,
                // as a Plex library does.
                let failedWithRows = state.error != nil && !providerLibraryRows.isEmpty
                hubsError = failedWithRows ? nil : state.error
                hubsEmpty = (loadedFeedItems.map { authorizedFeedItems($0).isEmpty } ?? gridItems.isEmpty) && !failedWithRows
            } else {
                isLoadingHubs = isLoadingLibraryHubs
                hubsError = libraryHubsError
                // A hub-less library with grid content still shows content —
                // "empty" means no projected rows AND no hubs AND no grid items.
                hubsEmpty = (dataStore.libraryItemsByKey[key] ?? []).isEmpty
                    && (dataStore.libraryHubs[key] ?? []).isEmpty
                    && gridItems.isEmpty
            }
        case .discover:
            isLoadingHubs = isLoadingDiscover || discoverModel.loading || ServerDataStore.shared.isResolvingVisibility
            // Native failures retain their error semantics. Plex's TMDB service
            // returns [] on failure, so only that source settles as empty.
            hubsError = discoverModel.nativeErrors.values.sorted().first
                ?? ServerDataStore.shared.visibilityErrors.values.sorted().first
            // Only visible content counts; error rows are not recommendations.
            hubsEmpty = discoverModel.heroItems.isEmpty
                && discoverModel.forYou.isEmpty
                && TMDBDiscoverSection.allCases.allSatisfy { discoverModel.items(for: $0).isEmpty }
                && discoverModel.nativeHubs
                    .filter { LibrarySettingsManager.shared.areServerLibrariesVisible($0.providerID) }
                    .allSatisfy { visibleNativeItems($0.items).isEmpty }
        case .search:
            // Search renders its own inline prompt/searching/error states as
            // sections — the only full-screen state is notConnected.
            isLoadingHubs = false
            hubsError = nil
            hubsEmpty = false
        case .watchlist:
            isLoadingHubs = isLoadingWatchlist || ServerDataStore.shared.isResolvingVisibility
            // A failed fetch with a populated cache keeps showing the cache;
            // with nothing cached the message is the empty state, which reads
            // correctly either way (the watchlist really has nothing to show).
            hubsError = nativeWatchlistErrors.values.sorted().first
                ?? ServerDataStore.shared.visibilityErrors.values.sorted().first
            hubsEmpty = watchlistService.watchlistItems.isEmpty && visibleNativeItems(nativeWatchlistItems).isEmpty
        case .collection, .playlist, .playlists:
            // Page 0's own outcome: an empty grid reads the same while the
            // request is in flight, after it failed and after an empty answer.
            let state = pageZeroState
            isLoadingHubs = state.loading
            hubsError = state.error
            hubsEmpty = gridItems.isEmpty
        }

        // Precedence: notConnected → loading → error → empty → content.
        // Only the error/empty states carry a focusable button; track that so
        // preferredFocusEnvironments can steer the engine onto it (otherwise a
        // contentless Home can trap focus — see Docs/bugs/fresh-signin-blank-home.md).
        let isWaitingForHero = shouldWaitForHeroBeforeContent(hubsEmpty: hubsEmpty)
        stateViewHasFocusableAction = false
        var showsLoading = false
        if !hasCredentials {
            stateView.configure(kind: .notConnected)
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
        } else if (isLoadingHubs && hubsEmpty) || isWaitingForHero {
            stateView.configure(kind: .loading)
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            showsLoading = true
        } else if let error = hubsError, hubsEmpty {
            stateView.configure(kind: .error(message: error))
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            stateViewHasFocusableAction = true
            setNeedsFocusUpdate()
        } else if hubsEmpty {
            stateView.configure(kind: .empty(message: emptyStateMessage))
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            stateViewHasFocusableAction = true
            setNeedsFocusUpdate()
        } else {
            // Content path: cached content renders whether or not the server
            // is reachable. Offline is announced by `ConnectionAlert` and
            // costs this layout nothing.
            let wasUnfocusable = collectionView.isHidden
            stateView.isHidden = true
            collectionView.isHidden = false
            // A hidden collection is invisible to the focus engine and un-hiding does not make it look
            // again, so tell the shell to re-drive.
            if wasUnfocusable, isDrillInPage {
                // Collection page: a modal, where the shell's re-drive does nothing. Page 0 was applied while
                // hidden, so lay out and request the first tile explicitly.
                collectionView.layoutIfNeeded()
                if let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)),
                   let system = UIFocusSystem.focusSystem(for: collectionView) {
                    system.requestFocusUpdate(to: cell)
                    system.updateFocusIfNeeded()
                }
            } else if wasUnfocusable {
                // Reloaded from nothing (a profile switch): top of the page, as at launch.
                aimFocusAtTopRow()
                NotificationCenter.default.post(name: .contentBecameFocusable, object: nil)
            }
            backdropView.isHidden = !showHomeHero
            ConnectionAlert.presentOnceIfOffline(from: self)
        }

        // Collection page: the anchor is visible only while page 0 is in
        // flight, so it never competes with the grid or the state view's
        // button. Entering loading again (the retry) re-resolves focus, which
        // moves it off the Try Again button that just vanished.
        if isDrillInPage {
            collectionFocusAnchor.isHidden = !showsLoading
            if showsLoading { setNeedsFocusUpdate() }
        }

        // Splash handoff: the launch splash dismisses on dataStore.isHomeContentReady, set on any settled
        // state (content, empty, error). Without it the splash rides its 15s timeout.
        if hasCredentials, !(isLoadingHubs && hubsEmpty), !isWaitingForHero, !dataStore.isHomeContentReady {
            // Deferred: this can run inside a SwiftUI view update, where publishing is not allowed.
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
              authManager.hasCredentials,
              !hubsEmpty,
              !dataStore.isHomeHeroReady else { return false }
        return true
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
        // Search: name the scroll view that drives the search chrome. With none set UIKit guesses, and the
        // guess collapsed the field on the way down and never restored it.
        if case .search = mode {
            setContentScrollView(collectionView, for: .top)
        }
        // No hero: 48pt of room above the first row.
        updateContentTopInset()
        // Not in search mode: its content swaps wholesale, and an invalid remembered path makes the engine
        // produce no focus update at all. Preview-dismiss restore uses `pendingPreviewRestore`.
        if case .search = mode {
            collectionView.remembersLastFocusedIndexPath = false
        } else {
            collectionView.remembersLastFocusedIndexPath = true
        }
        collectionView.clipsToBounds = false
        // We drive every vertical move from `didUpdateFocusIn`. Left enabled, the engine's own scroll
        // animator races the CADisplayLink driver in `animateContentOffset` and stutters.
        collectionView.isScrollEnabled = false

        // Select long-press on a grid tile → tile action menu. Our own
        // recognizer: the system context-menu path never engages on tvOS 26
        // (see TileMenuPopupViewController's header).
        collectionView.addGestureRecognizer(
            TileLongPress.makeRecognizer(target: self, action: #selector(handleGridLongPress(_:))))
        if case .playlist = mode { installEntryMove() }

        collectionView.register(HubHeaderView.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: HubHeaderView.reuseID)
        collectionView.register(PosterCell.self, forCellWithReuseIdentifier: PosterCell.reuseID)
        collectionView.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
        collectionView.register(ContinueWatchingCell.self, forCellWithReuseIdentifier: ContinueWatchingCell.reuseID)
        collectionView.register(PlaylistCardCell.self, forCellWithReuseIdentifier: PlaylistCardCell.reuseID)
        collectionView.register(HeroOverlayCell.self, forCellWithReuseIdentifier: HeroOverlayCell.reuseID)
        collectionView.register(HeroLoadingCell.self, forCellWithReuseIdentifier: HeroLoadingCell.reuseID)
        collectionView.register(WatchlistPosterCell.self, forCellWithReuseIdentifier: WatchlistPosterCell.reuseID)
        collectionView.register(PosterSkeletonCell.self, forCellWithReuseIdentifier: PosterSkeletonCell.reuseID)
        collectionView.register(RecommendationsStateCell.self, forCellWithReuseIdentifier: RecommendationsStateCell.reuseID)
        // Library-mode sort header (inert registration in home mode — the
        // .sortHeader section only ever exists in library snapshots).
        collectionView.register(MediaLibrarySortControl.self, forCellWithReuseIdentifier: MediaLibrarySortControl.reuseID)
        collectionView.register(PlaylistHeaderCell.self, forCellWithReuseIdentifier: PlaylistHeaderCell.reuseID)
        // Search-mode cells (inert registrations in other modes).
        collectionView.register(SearchRecentsCell.self, forCellWithReuseIdentifier: SearchRecentsCell.reuseID)
        collectionView.register(SearchStateCell.self, forCellWithReuseIdentifier: SearchStateCell.reuseID)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Library alphabet bar (issue #308), over the grid's trailing margin.
        // Hidden until focus is in the grid, so Right from a hub row's last
        // tile cannot land on it and jump a grid the user is not looking at.
        if case .library = mode {
            // tvOS's fast-scroll index bar stays invisible. It still takes
            // focus ~1.5s into a held Up/Down (see didUpdateFocusIn); that
            // hand-off is the signal for our own fast scroll below.
            collectionView.showsVerticalScrollIndicator = false
            collectionView.indexDisplayMode = .alwaysHidden
            alphabetBar.translatesAutoresizingMaskIntoConstraints = false
            alphabetBar.isHidden = true
            alphabetBar.alpha = 0
            alphabetBar.onLetterFocused = { [weak self] index in
                guard let self else { return }
                self.letterIndicator.letter = self.alphabetIndex?.entries[safe: index]?.title
                self.jumpGrid(toLetterAt: index)
                // Letter-to-letter moves never involve the collection view,
                // so its focus delegate cannot reset the idle timer; do it here.
                self.scheduleStripIdleReturn()
            }
            alphabetBar.onLetterSelected = { [weak self] in self?.leaveStrip() }
            alphabetBar.onFocusContainmentChanged = { [weak self] inside in
                if inside { self?.letterIndicator.show() } else { self?.letterIndicator.hide() }
            }
            letterIndicator.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(letterIndicator)
            view.addSubview(alphabetBar)
            NSLayoutConstraint.activate([
                alphabetBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                alphabetBar.widthAnchor.constraint(equalToConstant: LibraryAlphabetBarView.width),
                alphabetBar.topAnchor.constraint(equalTo: view.topAnchor),
                alphabetBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                letterIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                letterIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                letterIndicator.widthAnchor.constraint(equalToConstant: 220),
                letterIndicator.heightAnchor.constraint(equalToConstant: 220)
            ])
        }

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
            let layout = makeHeroSectionLayout()
            // Discover's leading row is the showcase itself, like its TMDB
            // hero, not a shelf title below the artwork competing with the
            // next recommendation header.
            if case .discover = mode { return layout }
            if nativeRows[section.id] != nil {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(64)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .bottom)
                header.contentInsets.leading = MediaRowMetrics.rowLeading
                layout.boundarySupplementaryItems = [header]
            }
            return layout
        case .continueWatching, .recentlyAdded, .recommendations, .discoverList, .searchGrid:
            return makeHubSectionLayout(section: section, isContinueWatching: section.kind == .continueWatching)
        case .watchlist:
            return makeHubSectionLayout(section: section, isContinueWatching: false)
        case .recommendationsLoading, .recommendationsError:
            return makeRecommendationsStateLayout()
        case .sortHeader:
            return makeSortHeaderSectionLayout()
        case .grid, .watchlistGrid:
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
        // On the content margin from the PANEL edge, like the grid below it.
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: MediaRowMetrics.rowLeading, bottom: 24, trailing: MediaRowMetrics.rowTrailing)
        return section
    }

    /// Multi-column poster grid (library + search modes). Derived ENTIRELY
    /// from MediaRowMetrics so grid columns land exactly where the shelf
    /// rows' at-rest tiles sit: the tile's frame inset and spacing,
    /// posterFullCount across, which makes the computed column width the
    /// tile's frame width and rests its artwork on the grid.
    /// Search-mode group grids add a row-style header when titled.
    private func makeGridSectionLayout(section data: HomeSectionData) -> NSCollectionLayoutSection {
        // Music libraries render 1:1 square tiles, playlists 16:9 cards; everything else 2:3.
        let isPlaylists = if case .playlists = mode { true } else { false }
        let tile = isPlaylists ? MediaRowMetrics.playlist
            : (data.isMusic ? MediaRowMetrics.music : MediaRowMetrics.poster)
        let columns = isPlaylists ? MediaRowMetrics.playlistFullCount : MediaRowMetrics.posterFullCount
        // Posters sit on Apple's row pitch; the other tiles keep their padded rows with a gap.
        let isPosterGrid = !isPlaylists && !data.isMusic
        let groupHeight = isPosterGrid ? MediaRowMetrics.posterGridPitch
            : tile.frame.height + MediaRowMetrics.focusGrowthPadding

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
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
                                                       count: columns)
        group.interItemSpacing = .fixed(tile.gap)

        let section = NSCollectionLayoutSection(group: group)
        // Margins from the PANEL edge to match the shelves (not the safe area).
        section.contentInsetsReference = .none
        section.interGroupSpacing = isPosterGrid ? 0 : 24
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 24,
            leading: tile.leading,
            bottom: 48,
            trailing: tile.leading
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
            // The header follows the section's insets (the frame inset), so
            // add the rest of the margin to rest it on the artwork's edge.
            header.contentInsets.leading = MediaRowMetrics.rowLeading - tile.leading
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

    /// Single full-width cell for the recommendations loading and error states; the cell pads itself.
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
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(Self.heroHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        // Edge-referenced like the hub rows (the overlay's internal rowLeading
        // is measured from the panel edge). Insets stay zero — the overlay
        // cell already owns its own vertical composition.
        section.contentInsetsReference = .none
        // Small bottom gap so the first row (Continue Watching) sits a bit
        // lower, separated from the hero.
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: Self.heroShelfGap, trailing: 0)
        return section
    }

    /// The hero section: the screen less 200 pt, then a 40 pt gap to the first shelf.
    private static var heroHeight: CGFloat { max(400, UIScreen.main.bounds.height - 200) }
    private static let heroShelfGap: CGFloat = 40
    /// The line the backdrop's bottom catches up with: 40 pt above the hero's
    /// bottom, leaving Apple's ~100 pt between the art and the first row title.
    private static var heroBackdropFloor: CGFloat { heroHeight - 40 }

    /// Nothing covers Home, so a hero page change would be seen. Checks the
    /// window's root: the carousel and player present from the shell, not here.
    private var heroCanAutoAdvance: Bool {
        guard let root = view.window?.rootViewController else { return false }
        return root.presentedViewController == nil
    }

    /// One full-width ShelfRowCell per hub section, scrolling itself rather than an orthogonal section
    /// (see ShelfRowCell for why and for the landing math).
    private func makeHubSectionLayout(section: HomeSectionData, isContinueWatching: Bool) -> NSCollectionLayoutSection {
        let tile = isContinueWatching
            ? MediaRowMetrics.continueWatching
            : (section.isMusic ? MediaRowMetrics.music : MediaRowMetrics.poster)
        let rowHeight = tile.frame.height + MediaRowMetrics.focusGrowthPadding  // room for focus growth

        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(rowHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])

        let layoutSection = NSCollectionLayoutSection(group: group)
        // Full-bleed row from the PANEL edge (not the safe area): the
        // ShelfRowCell carries the margin and the peeking sliver
        // internally.
        layoutSection.contentInsetsReference = .none
        // Titled rows: header baseline to artwork and artwork to next artwork follow Apple's
        // measured spacing (`shelfInsets`). The row's flow layout centres the tiles in their padding.
        let insets = section.title != nil
            ? MediaRowMetrics.shelfInsets(for: tile)
            : (top: MediaRowMetrics.rowTopInset, bottom: MediaRowMetrics.rowBottomInset)
        layoutSection.contentInsets = NSDirectionalEdgeInsets(
            top: insets.top,
            leading: 0,
            bottom: insets.bottom,
            trailing: 0
        )

        if section.title != nil {
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(MediaRowMetrics.headerHeight)
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
            self.configureHeader(header, section: indexPath.section)
            return header
        }
    }

    private func configureHeader(_ header: HubHeaderView, section index: Int) {
        let section = sectionsSnapshot[index]
        let loadedCount: Int
        switch section.kind {
        case .hero, .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState:
            loadedCount = 0
        case .continueWatching, .recentlyAdded, .recommendations, .grid, .discoverList,
             .searchGrid:
            loadedCount = section.items.count
        case .watchlist, .watchlistGrid: loadedCount = section.watchlistItems.count
        }
        header.configure(
            title: section.title ?? "",
            style: section.headerStyle,
            loadedCount: loadedCount,
            totalCount: section.totalSize,
            sourceBadge: section.sourceBadge
        )
        if section.id == Self.mergedContinueWatchingID,
           mergedCWSources.contains(where: { showsBrowseAll(for: $0) && $0.nextPage != nil }) {
            header.onSeeAll = { [weak self] in self?.openMergedContinueWatching() }
        } else if let row = nativeRows[section.id], showsBrowseAll(for: row) {
            header.onSeeAll = { [weak self] in self?.openNativeHub(row) }
        } else {
            header.onSeeAll = nil
        }
    }

    private func showsBrowseAll(for row: CachedHomeHub) -> Bool {
        guard row.canBrowse == true, let providerID = row.nativeProviderID,
              let provider = MediaProviderRegistry.shared.provider(for: providerID) else { return false }
        return provider.showsHubBrowseAll
    }

    /// Headers are configured only at dequeue, and a diffable apply never
    /// re-vends a header whose section id survived, so a header change on a
    /// visible row (the server badge) is pushed in place.
    private func reconfigureVisibleHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind)
        where indexPath.section < sectionsSnapshot.count {
            guard let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                    as? HubHeaderView else { continue }
            configureHeader(header, section: indexPath.section)
        }
    }

    private func cell(for itemID: HomeItemID, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        guard indexPath.section < sectionsSnapshot.count else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath)
        }
        let section = sectionsSnapshot[indexPath.section]
        let perfKey = "\(itemID.sectionID.raw):\(itemID.itemID)"

        // Skeleton: a sentinel itemID at the row's end while a page loads.
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
                // MediaItem hero (same overlay, MediaItem configuration path):
                // Discover's TMDB titles, or a provider library's own items,
                // which play and open info like any library tile.
                let isDiscover: Bool = { if case .discover = mode { return true } else { return false } }()
                let showHeroServerBadge: Bool = { if case .home = mode { return true } else { return false } }()
                cell.configure(withMediaItems: HeroOverlayCell.MediaItemConfiguration(
                    items: section.heroMediaItems,
                    initialIndex: heroCurrentIndex,
                    onIndexChanged: { [weak self, weak cell] newIndex, item in
                        guard let self else { return }
                        self.heroCurrentIndex = newIndex
                        self.updateBackdrop(forMediaItem: item, paging: true)
                        self.applyMediaItemHeroState(for: item, on: cell)
                        if newIndex >= section.heroMediaItems.count - 3,
                           let row = self.nativeRows[section.id] {
                            Task { await self.loadNativeHubPage(row, sectionID: section.id) }
                        }
                    },
                    onPlay: { [weak self] item in
                        if isDiscover { self?.discoverHeroPlay(item) } else { self?.playResolvingEpisode(item) }
                    },
                    onInfo: { [weak self] item in
                        if isDiscover { self?.discoverHeroInfo(item) } else { self?.presentStandaloneExpandedDetail(item) }
                    },
                    onToggleWatchlist: { [weak self, weak cell] item in
                        guard item.ref.providerID == TMDBMediaMapper.providerID else {
                            self?.toggleProviderWatchlist(for: item, on: cell)
                            return
                        }
                        self?.toggleDiscoverWatchlist(for: item) { [weak self, weak cell] in
                            self?.applyMediaItemHeroState(for: item, on: cell)
                        }
                    },
                    // Home names each slide's server while both are signed in.
                    badge: showHeroServerBadge ? { item in
                        guard item.ref.providerID != TMDBMediaMapper.providerID else { return nil }
                        return Self.sourceBadge(for: item.ref,
                                                labelsServers: ServerDataStore.shared.labelsServers)
                    } : nil
                ))
                cell.overlay.onFocusEntered = { [weak self] in
                    self?.scrollHeroIntoView(sectionID: section.id)
                }
                cell.overlay.autoAdvanceGate = { [weak self] in self?.heroCanAutoAdvance ?? false }
                if heroCurrentIndex < section.heroMediaItems.count {
                    applyMediaItemHeroState(for: section.heroMediaItems[heroCurrentIndex], on: cell)
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
                    self.updateBackdrop(for: item, paging: true)
                },
                onInfo: { [weak self] item in self?.presentDetailPage(for: item) },
                onPlay: { [weak self] item in self?.playItemDirectly(item) },
                onFocusEntered: { [weak self] in
                    self?.scrollHeroIntoView(sectionID: section.id)
                }
            ))
            cell.overlay.autoAdvanceGate = { [weak self] in self?.heroCanAutoAdvance ?? false }
            return cell

        case .continueWatching, .recentlyAdded, .recommendations, .watchlist, .discoverList, .searchGrid:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            Perf.interval(.cellPrepare, key: perfKey) {
                configureShelfRow(cell, sectionID: section.id)
            }
            return cell

        case .grid:
            if case .playlists = mode {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PlaylistCardCell.reuseID, for: indexPath) as! PlaylistCardCell
                if let item = section.items[safe: indexPath.item], !item.isGridPlaceholder {
                    cell.configure(item: item, isSmart: listedPlaylist(for: item)?.isSmart == true)
                }
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
            if indexPath.item < section.items.count {
                let item = section.items[indexPath.item]
                if item.isGridPlaceholder {
                    cell.configurePlaceholder()
                } else {
                    Perf.interval(.cellPrepare, key: perfKey) {
                        cell.configure(item: item)
                        if loadedFeedItems != nil {
                            cell.setSourceBadge(Self.sourceBadge(for: item.ref,
                                                               labelsServers: ServerDataStore.shared.labelsServers))
                        }
                    }
                }
            }
            return cell

        case .watchlistGrid:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: WatchlistPosterCell.reuseID, for: indexPath) as! WatchlistPosterCell
            if let item = section.watchlistItems[safe: indexPath.item] {
                Perf.interval(.cellPrepare, key: perfKey) {
                    cell.configure(item: item)
                }
            }
            return cell

        case .sortHeader:
            if case .playlist = mode {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PlaylistHeaderCell.reuseID, for: indexPath) as! PlaylistHeaderCell
                cell.configure(title: section.title ?? "")
                cell.onPlay = { [weak self] in
                    guard let self else { return }
                    startPlaylist(playlistEntries, at: 0, shuffled: false)
                }
                cell.onShuffle = { [weak self] in
                    guard let self else { return }
                    startPlaylist(playlistEntries, at: 0, shuffled: true)
                }
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MediaLibrarySortControl.reuseID, for: indexPath) as! MediaLibrarySortControl
            // Read only when the cell is dequeued or reconfigured, which is why
            // a changed list calls refreshSortHeaderCount().
            let modes: [LibraryViewMode] = [.titles] + (libraryCollections.isEmpty ? [] : [.collections])
                + (onSelectViewMode == nil ? [] : [.folders])
            let viewMenu = LibraryViewMode.menu(modes, current: gridShowsCollections ? .collections : .titles) {
                [weak self] mode in
                guard let self else { return }
                if let onSelectViewMode { onSelectViewMode(mode) } else { setGridShowsCollections(mode == .collections) }
            }
            cell.configure(
                title: section.title ?? "",
                count: totalGridCount,
                sortName: gridSort.displayName,
                sortMenu: sortMenu(),
                view: gridShowsCollections ? .collections : .titles,
                viewMenu: viewMenu
            )
            return cell

        case .recommendationsLoading:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: RecommendationsStateCell.reuseID, for: indexPath) as! RecommendationsStateCell
            cell.configure(state: .loading)
            return cell

        case .recommendationsError:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: RecommendationsStateCell.reuseID, for: indexPath) as! RecommendationsStateCell
            if let message = nativeErrorMessages[section.id] {
                cell.configure(state: .error(message: message))
                cell.onRetry = { [weak self] in
                    guard let self else { return }
                    ServerDataStore.shared.reload()
                    self.nativeAuthorityChanged()
                }
                return cell
            }
            cell.configure(state: .error(message: recommendationsError ?? "Unknown error"))
            cell.onRetry = { [weak self] in
                Task { await self?.refreshRecommendations(force: true) }
            }
            return cell

        case .searchPrompt:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SearchRecentsCell.reuseID, for: indexPath) as! SearchRecentsCell
            cell.configure(recentItems: recentSearchItems)
            // A card reopens the ITEM, the way the Apple TV row does. It no
            // longer re-runs a stored query, so nothing is written back into
            // the keyboard field.
            cell.onRecentSelected = { [weak self] item in self?.selectMediaItem(item) }
            return cell

        case .searchState:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SearchStateCell.reuseID, for: indexPath) as! SearchStateCell
            cell.configure(state: currentSearchState)
            cell.onRetry = { [weak self] in self?.submitSearch() }
            cell.onRequests = { [weak self] in
                guard let self, let provider = self.requestsSearchProvider,
                      !self.trimmedSearchQuery.isEmpty else { return }
                self.present(SiloRequestsViewController(provider: provider, context: .search(self.trimmedSearchQuery)), animated: true)
            }
            return cell
        }
    }

    // MARK: - Data store observation

    private func observeDataStore() {
        ServerDataStore.shared.$visibilityVersion.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if nativeHubSource != nil {
                    let resolving = ServerDataStore.shared.isResolvingVisibility
                    if resolving {
                        if !nativeHubAwaitingVisibility {
                            resetGrid()
                            pageZero = .loading
                        }
                        nativeHubAwaitingVisibility = true
                    } else if nativeHubAwaitingVisibility {
                        nativeHubAwaitingVisibility = false
                        loadGridPage(containing: 0)
                    }
                }
                applySnapshot(animated: false)
                reconfigureHeroCell()
                updateHomeState()
            }
            .store(in: &dataStoreObservers)
        ServerDataStore.shared.$libraries.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                applySnapshot(animated: false)
                reconfigureHeroCell()
                reconfigureVisibleHeaders()
                updateHomeState()
            }
            .store(in: &dataStoreObservers)
        nativeVisibleLibraryKeys = Set(Self.sidebarLibraryOrder())
            .union(LibrarySettingsManager.shared.hiddenLibraryServerIDs)
        LibrarySettingsManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let visible = Set(Self.sidebarLibraryOrder())
                    .union(LibrarySettingsManager.shared.hiddenLibraryServerIDs)
                guard visible != nativeVisibleLibraryKeys else { return }
                nativeVisibleLibraryKeys = visible
                if nativeHubSource != nil {
                    resetGrid()
                    loadGridPage(containing: 0)
                }
                if case .search = mode {
                    lastSubmittedQuery = ""
                    submitSearch()
                }
                if case .discover = mode {
                    providerFeedTask?.cancel()
                    providerFeedTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await discoverModel.load()
                        guard !Task.isCancelled else { return }
                        applySnapshot(animated: false)
                        reconfigureHeroCell()
                        reconfigureVisibleHeaders()
                        updateHomeState()
                    }
                }
                applySnapshot(animated: false)
                reconfigureHeroCell()
                reconfigureVisibleHeaders()
                updateHomeState()
            }
            .store(in: &dataStoreObservers)
        ServerDataStore.shared.$sources.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.nativeAuthorityChanged() }
            .store(in: &dataStoreObservers)
        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if case .watchlist = self.mode { Task { await self.reloadNativeWatchlist() } }
                if case .discover = self.mode, !self.discoverModel.nativeSupportedProviders.isEmpty {
                    self.providerFeedTask?.cancel()
                    self.providerFeedTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await discoverModel.load()
                        guard !Task.isCancelled else { return }
                        applySnapshot(animated: false)
                        reconfigureHeroCell()
                        updateHomeState()
                    }
                }
            }
            .store(in: &dataStoreObservers)
        // Rows come from the MediaItem projection: `homeItemsVersion` for Home, `libraryHubsVersion` for
        // libraries. `setNeedsSnapshotApply` coalesces a burst into one apply per runloop turn.
        dataStore.$homeItemsVersion
            .merge(with: dataStore.$libraryHubsVersion)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setNeedsSnapshotApply()
                self?.updateHomeState()
            }
            .store(in: &dataStoreObservers)

        // `hubsVersion` drives hero selection and state precedence; the Plex hero reads `dataStore.hubs`.
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
                    case .watchlist:
                        break  // playback state doesn't change what is on the watchlist
                    case .home:
                        await self.dataStore.refreshHubs()
                        await self.dataStore.refreshLibraryHubs()
                        if self.enablePersonalizedRecommendations {
                            await self.refreshRecommendations(force: true)
                        }
                    case .library:
                        // Repaint badges (show unwatched counts, #333). The
                        // reload bumps the generation, which discards an
                        // in-flight letter count; ask again.
                        self.reloadLoadedGridPages()
                        self.loadAlphabetIndex()
                        await self.refreshThisLibraryHubs()
                    case .collection, .playlist, .playlists:
                        // Playback and detail-page watch changes: re-request
                        // the loaded pages so badges and progress repaint.
                        // A playlist page also picks up entry edits; the grid, created and deleted lists.
                        // Mid-move a reload would reorder the grid under the held tile: run it after.
                        if self.entryMove?.isMoving == true { self.refreshAfterMove = true; return }
                        self.reloadLoadedGridPages()
                    }
                }
            }
            .store(in: &dataStoreObservers)

        // A library page draws its own pins: refetch and repaint on any change.
        if case .library = mode {
            NotificationCenter.default.publisher(for: HomeCollectionPins.changedNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        await self.fetchLibraryPins()
                        self.applySnapshotKeepingFocusedRowStill()
                    }
                }
                .store(in: &dataStoreObservers)
        }

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
        case .discover, .search, .watchlist, .collection, .playlists, .playlist:
            break
        }

        // Jellyfin rows, the sign-in that labels Plex's rows, Home Rows
        // toggles and Sidebar Libraries changes (none of these move
        // PlexDataStore's version when only Jellyfin is affected).
        if case .home = mode {
            let jellyfin = ServerDataStore.shared
            jellyfin.$homeRows.map { _ in () }
                .merge(with: jellyfin.$sources.map { _ in () },
                       jellyfin.$isLoading.map { _ in () },
                       jellyfin.$trending.dropFirst().map { _ in () },
                       ContinueWatchingRow.shared.$version.dropFirst().map { _ in () },
                       LibrarySettingsManager.shared.objectWillChange.map { _ in () },
                       NotificationCenter.default.publisher(for: HomeRowSettings.changedNotification).map { _ in () })
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.jellyfinHomeRowsChanged()
                }
                .store(in: &dataStoreObservers)
        }
    }

    /// Home's MediaItem hero slides as last drawn (Jellyfin's, both
    /// servers' mixed, or one of Home's lists).
    private var homeMediaHeroRefs: [MediaItemRef] = []

    /// What Home's hero shows (#414): trending, or one of Home's own lists.
    enum HeroContent: String, CaseIterable {
        case trending, continueWatching, recentlyAdded, watchlist
    }

    static var heroContent: HeroContent {
        HeroContent(rawValue: SettingsStore.string("homeHeroContent", default: "")) ?? .trending
    }

    /// The list the hero shows, as Home last built it.
    private var listHeroItems: [MediaItem] = []
    private var lastHeroContent = PlexHomeViewController.heroContent
    /// The watchlist's first entries mapped to library or TMDB items, and the entry ids they came from.
    private var watchlistHeroItems: [MediaItem] = []
    private var watchlistHeroSourceIDs: [String]?
    private var watchlistHeroTask: Task<Void, Never>?

    /// Home's hero shows a list instead of trending; an empty list keeps trending.
    private var heroShowsList: Bool {
        guard case .home = mode, showHomeHero, Self.heroContent != .trending else { return false }
        return !listHeroItems.isEmpty
    }

    /// The hero's slides for a list choice, from Home's rows as just built.
    private func heroItemsForList(from sections: [HomeSectionData], rail: [(row: CachedHomeHub, kind: MediaProviderKind)]) -> [MediaItem] {
        switch Self.heroContent {
        case .trending: return []
        case .continueWatching: return sections.first { $0.kind == .continueWatching }?.items ?? []
        case .recentlyAdded:
            let rows = rail.filter { !$0.row.isContinueWatching && Self.isRecentlyAddedRow($0.row) }
            return Array(Self.roundRobin(rows.map(\.row.items))
                .filter { ($0.grandparentArtwork?.backdrop ?? $0.artwork.backdrop) != nil }
                .prefix(10))
        case .watchlist:
            refreshWatchlistHeroIfNeeded()
            return watchlistHeroItems
        }
    }

    /// Plex's recently added hubs (`movie.recentlyadded`) and every other server's `<library>.recentlyAdded` row.
    static func isRecentlyAddedRow(_ row: CachedHomeHub) -> Bool {
        (row.hubIdentifier ?? row.id).lowercased().contains("recentlyadded")
    }

    /// One item from each list in turn, so no library's additions bury another's.
    static func roundRobin(_ lists: [[MediaItem]]) -> [MediaItem] {
        var out: [MediaItem] = []
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count { out.append(list[i]) }
        }
        return out
    }

    /// Maps the watchlist's first entries once per change; Home redraws when they land.
    private func refreshWatchlistHeroIfNeeded() {
        let entries = Array(watchlistService.watchlistItems.prefix(10))
        let ids = entries.map(\.id)
        guard ids != watchlistHeroSourceIDs else { return }
        watchlistHeroSourceIDs = ids
        watchlistHeroTask?.cancel()
        watchlistHeroTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.buildWatchlistMediaItems(from: entries).map(\.item)
                .filter { ($0.grandparentArtwork?.backdrop ?? $0.artwork.backdrop) != nil }
            guard !Task.isCancelled else { return }
            self.watchlistHeroItems = items
            self.applySnapshot(animated: false)
        }
    }

    /// `labelsServers` as the hero last drew its badges. Always false on a
    /// Plex-only Home.
    private var homeMediaHeroLabels = false
    /// `labelsServers` as last drawn: a flip re-badges every row.
    private var lastLabelsServers = ServerDataStore.shared.labelsServers

    /// Runs after every apply on Home. The hero cell's item id is constant,
    /// so the apply never re-vends it; without this it keeps the old slides
    /// while the backdrop reads the new ones (as `refreshProviderLibrary`).
    /// One place for every change: a Jellyfin reload, a Plex hero upgrade or
    /// fallback landing in the mixed list, a sign-in or sign-out.
    private func revendHomeMediaHeroIfChanged(_ sections: [HomeSectionData]) {
        guard case .home = mode else { return }
        let refs = sections.first(where: { $0.kind == .hero })?.heroMediaItems.map(\.ref) ?? []
        let labels = ServerDataStore.shared.labelsServers
        let labelsChanged = labels != homeMediaHeroLabels
        homeMediaHeroLabels = labels
        guard refs != homeMediaHeroRefs else {
            // Same slides, other server count (Plex signed out under a
            // Jellyfin-only list): only the badges change.
            if labelsChanged { reconfigureHeroCell() }
            return
        }
        homeMediaHeroRefs = refs
        heroCurrentIndex = 0
        reconfigureHeroCell()
        updateBackdropForCurrentHeroItem()
        // The list hero emptied: trending takes the slot back.
        if refs.isEmpty, Self.heroContent != .trending { selectHeroItemsIfNeeded() }
    }

    private func jellyfinHomeRowsChanged() {
        let labels = ServerDataStore.shared.labelsServers
        let labelsFlipped = labels != lastLabelsServers
        lastLabelsServers = labels
        if labelsFlipped {
            applySnapshot(animated: false)
        } else {
            setNeedsSnapshotApply()
        }
        if labelsFlipped { reconfigureVisibleHeaders() }
        updateHomeState()
    }

    private func observeWatchlist() {
        watchlistService.$watchlistItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                self.setNeedsSnapshotApply()
                // Watchlist mode renders NOTHING else, so removing the last
                // entry empties the collection: re-evaluate the state overlay
                // or the surface is left blank with no focusable content.
                if case .watchlist = self.mode { self.updateHomeState() }
                // Only the row's leading tiles are worth prewarming; the grid's
                // cells fetch their own art as they scroll into view.
                self.prewarmWatchlistArtwork(Array(items.prefix(20)))
            }
            .store(in: &dataStoreObservers)

        // Transient watchlist write-error toast.
        watchlistService.$transientWriteError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.watchlistToast.show(message: message)
            }
            .store(in: &dataStoreObservers)
    }

    private func observeAuth() {
        // Connection state drives the notConnectedView precedence (via
        // hasCredentials → authToken) and, on the content path, the
        // once-per-outage offline popup.
        authManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Home with Jellyfin: a Plex sign-in saves the server after
                // the token, so only this sink sees `labelsServers` turn true.
                // Without a Jellyfin account nothing here can change.
                if case .home = self.mode, ServerDataStore.shared.isSignedIn {
                    self.jellyfinHomeRowsChanged()
                } else {
                    self.updateHomeState()
                }
            }
            .store(in: &dataStoreObservers)

        authManager.$authToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Home: a Plex sign-out swaps in the Jellyfin hero.
                if case .home = self.mode { self.jellyfinHomeRowsChanged() } else { self.updateHomeState() }
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
                    if Self.heroContent != self.lastHeroContent {
                        self.lastHeroContent = Self.heroContent
                        self.applySnapshot(animated: false)
                    }
                    let userID = UserDefaults.standard.integer(forKey: PlexProfileSession.contentUserIDKey)
                    if userID != self.recommendationsUserID {
                        self.recommendationsUserID = userID
                        self.recommendations = []
                        self.recommendationsError = nil
                        self.applySnapshot(animated: false)
                    }
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
                    // A provider library's hero skips selectHeroItemsIfNeeded,
                    // so a hero switched on here needs its backdrop. Free when
                    // the URL is unchanged.
                    if self.providerLibrary != nil { self.updateBackdropForCurrentHeroItem() }
                }
            }
            .store(in: &dataStoreObservers)
    }

    /// Last-seen shown-on-Home library set, so the UserDefaults observer can
    /// tell a library-visibility change from any other defaults write.
    private var lastHomeLibraryKeys: Set<String>?

    /// Re-derives Home's cross-library content when the libraries on Home change. `LibrarySettingsManager`
    /// posts no notification, and CW and the hero are filtered from caches written under the old set.
    /// Keyed on `librariesPinnedToHome`, the set Home draws rows from.
    private func reprojectIfHomeLibrariesChanged() {
        guard case .home = mode else { return }
        let keys = Set(dataStore.librariesPinnedToHome.map { $0.key })
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

    /// Coalesces snapshot rebuilds: 4-6 data signals burst at launch, each a full apply (1.9-3.5s on
    /// device). One apply per main-runloop turn services the burst.
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
        let oldHero = sectionsSnapshot.first { $0.kind == .hero }
        let newHero = sections.first { $0.kind == .hero }
        let isDiscover = if case .discover = mode { true } else { false }
        if isDiscover, oldHero?.heroMediaItems.map(\.ref) != newHero?.heroMediaItems.map(\.ref) {
            heroCurrentIndex = 0
        }
        sectionsSnapshot = sections
        updateContentTopInset()

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
                // Positional identity: slot N is "grid-N" whether it holds an
                // item or a placeholder, so a page landing under the focused
                // cell reconfigures it in place instead of deleting it.
                ids = section.items.indices.map(Self.gridSlotID)
            case .watchlistGrid:
                // Entry ids are stable and unique per watchlist entry, so a
                // removal deletes exactly its own tile.
                ids = section.watchlistItems.map { HomeItemID(sectionID: section.id, itemID: $0.id) }
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
        revendHomeMediaHeroIfChanged(sections)
        if isDiscover {
            // The hero keeps its diffable identity on a native feed refresh.
            // Re-vend changed slides and update (or clear) the matching backdrop.
            if oldHero?.id == newHero?.id, oldHero?.heroMediaItems != newHero?.heroMediaItems {
                reconfigureHeroCell()
            }
            updateBackdropForCurrentHeroItem()
        }
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
        case .hero, .grid, .watchlistGrid, .recommendationsLoading, .recommendationsError,
             .sortHeader, .searchPrompt, .searchState: return false
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
                // A show's unwatched count and watched glyph (#333).
                hasher.combine(item.childProgress)
                hasher.combine(item.userState.isPlayed)
                // A poster changed on the server keeps the same items.
                hasher.combine(item.artwork)
                hasher.combine(item.grandparentArtwork)
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

    /// Binds a row's tile provider to a captured section value, so the row's count and its tiles come
    /// from one snapshot. A live lookup disagreed with the row's `realCount` and left skeletons mid-row.
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
            // The next few cards build now, so one reaching the edge arrives finished.
            let ahead = (indexPath.item + 1)..<min(indexPath.item + 5, section.items.count)
            ContinueWatchingCell.prewarm(section.items[ahead], scale: innerCV.traitCollection.displayScale)
            return cell
        case .recentlyAdded, .recommendations, .discoverList, .searchGrid:
            let cell = innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: indexPath) as! PosterCell
            Perf.interval(.cellPrepare, key: perfKey) {
                let item = section.items[indexPath.item]
                cell.configure(item: item)
                if section.kind == .searchGrid {
                    cell.setSourceBadge(Self.sourceBadge(for: item.ref,
                                                         labelsServers: ServerDataStore.shared.labelsServers))
                }
            }
            return cell
        case .watchlist:
            let cell = innerCV.dequeueReusableCell(withReuseIdentifier: WatchlistPosterCell.reuseID, for: indexPath) as! WatchlistPosterCell
            Perf.interval(.cellPrepare, key: perfKey) {
                cell.configure(item: section.watchlistItems[indexPath.item])
            }
            return cell
        case .hero, .grid, .watchlistGrid, .recommendationsLoading, .recommendationsError,
             .sortHeader, .searchPrompt, .searchState:
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
        case .hero, .grid, .watchlistGrid, .recommendationsLoading, .recommendationsError,
             .sortHeader, .searchPrompt, .searchState:
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
        case .hero, .watchlist, .watchlistGrid, .recommendations, .grid, .discoverList,
             .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState, .searchGrid:
            return  // No pagination for these (hubKey == nil)
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
            presentTileMenu(for: item, isContinueWatching: section.kind == .continueWatching,
                            shelfLocation: (sectionID: sectionID, itemIndex: itemIndex))
        case .discoverList:
            presentDiscoverTileMenu(sectionID: sectionID, itemIndex: itemIndex)
        case .searchGrid:
            guard itemIndex < section.items.count else { return }
            // People have no title actions. Reuse Select's native person route,
            // including its current provider and visible-library scope checks.
            if sectionID == .searchGroup("people") {
                handleShelfTap(sectionID: sectionID, itemIndex: itemIndex)
                return
            }
            // Music results (artist/album/track) route to the music surfaces;
            // the Plex watched/watchlist menu doesn't apply to them.
            if let meta = searchGroupMetas[sectionID]?[safe: itemIndex],
               ["artist", "album", "track"].contains(meta.type ?? "") {
                return
            }
            let item = section.items[itemIndex]
            presentTileMenu(for: item, isContinueWatching: false)
        case .watchlist:
            presentWatchlistTileMenu(sectionID: sectionID, itemIndex: itemIndex)
        case .hero, .grid, .watchlistGrid, .recommendationsLoading, .recommendationsError,
             .sortHeader, .searchPrompt, .searchState:
            return  // hero / state cells don't get menus
        }
    }

    /// The focused tile's frame in window coordinates, the menu anchor.
    /// The cell is the lockup frame, which the focused artwork fills.
    private func focusedTileFrame() -> CGRect? {
        var view = UIFocusSystem.focusSystem(for: self.view)?.focusedItem as? UIView
        while let current = view, !(current is UICollectionViewCell) { view = current.superview }
        guard let cell = view as? UICollectionViewCell else { return nil }
        return cell.convert(cell.bounds, to: nil)
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
        for press in presses {
            switch press.type {
            case .upArrow, .downArrow:
                heldArrow = press.type
                if isOnSystemIndexBar { startFastScroll() }
            case .leftArrow, .select:
                if isOnSystemIndexBar { landFocusOnCenterTile() }
            default:
                break
            }
        }
        for press in presses where press.type == .playPause {
            isHandlingPlayPausePress = true
            playFocusedTile()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releaseHeldArrow(presses)
        for press in presses where press.type == .playPause && isHandlingPlayPausePress {
            isHandlingPlayPausePress = false
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releaseHeldArrow(presses)
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
        guard presentedViewController == nil, entryMove?.isMoving != true, let item = focusedPlayableItem() else { return }
        playResolvingEpisode(item)
    }

    /// A show or a season has no playable media of its own, so Play has to
    /// resolve to a concrete episode first, through the item's own provider.
    /// Same composition as the preview carousel's Play pill (`playHeroItem`),
    /// so the two surfaces can never disagree about which episode a Play
    /// press starts.
    private func playResolvingEpisode(_ item: MediaItem, sourceID: String? = nil) {
        guard item.isAvailable != false else { return }
        guard item.kind == .show || item.kind == .season else {
            playItem(item, sourceID: sourceID)
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
        guard case .grid = section.kind, let item = section.items[safe: indexPath.item],
              !item.isGridPlaceholder else { return nil }
        return playableItem(item)
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
        case .watchlist, .watchlistGrid, .hero, .grid, .recommendationsLoading,
             .recommendationsError, .sortHeader, .searchPrompt, .searchState:
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
        case .collection, .playlist, .person, .unknown:
            return nil
        }
    }

    /// A library tile's long-press menu: the Music menu for a music tile, the video one otherwise.
    private func presentTileMenu(for item: MediaItem, isContinueWatching: Bool,
                                 shelfLocation: (sectionID: HomeSectionID, itemIndex: Int)? = nil,
                                 gridIndex: Int? = nil) {
        if presentMusicTileMenuIfNeeded(for: item) { return }
        let provider = playableItem(item).flatMap { MediaProviderRegistry.shared.provider(for: $0.ref.providerID) }
        Task { @MainActor [weak self] in
            // Cached per provider after the first menu.
            let canDelete = await provider?.canDeleteMedia() ?? false
            guard let self else { return }
            var sections = tileMenuSections(for: item, isContinueWatching: isContinueWatching,
                                            shelfLocation: shelfLocation)
            if let gridIndex, let entryGroup = playlistEntryActions(at: gridIndex, item: item) {
                sections.insert(entryGroup, at: 0)
            }
            if canDelete, let provider {
                sections.append([TileMenuAction(title: "Delete", systemImage: "trash", destructive: true) {
                    [weak self] in self?.confirmDelete(item, provider: provider)
                }])
            }
            presentTileMenu(sections: sections)
        }
    }

    private func confirmDelete(_ item: MediaItem, provider: any MediaProvider) {
        let message = item.kind == .show || item.kind == .season
            ? "Every episode's files will be deleted from \(provider.displayName). This cannot be undone."
            : "The files will be deleted from \(provider.displayName). This cannot be undone."
        let alert = UIAlertController(title: "Delete \u{201C}\(item.title)\u{201D}?", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            Task { @MainActor in
                do {
                    try await provider.deleteMedia(item.ref)
                    NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
                } catch {
                    let failed = UIAlertController(title: "Couldn't Delete", message: error.localizedDescription,
                                                   preferredStyle: .alert)
                    failed.addAction(UIAlertAction(title: "OK", style: .cancel))
                    self?.present(failed, animated: true)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func presentTileMenu(sections: [[TileMenuAction]]) {
        guard sections.contains(where: { !$0.isEmpty }), presentedViewController == nil else { return }
        // animated: false — the popup runs its own grow-from-the-tile
        // entrance/exit (see TileMenuPopupViewController).
        present(TileMenuPopupViewController(sections: sections,
                                            sourceFrame: focusedTileFrame()), animated: false)
    }

    /// Discover tile menu: Details when library-matched, watchlist add or remove for everything.
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
                    let providerID = MediaProviderRegistry.shared.plexProvider?.id ?? "plex:\(serverURL)"
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

    /// Watchlist tile menu: details and remove. Entries are `PlexWatchlistItem`s, so the watched menu
    /// does not apply.
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
        // Collection page: the collection's own art when it has some (12 of
        // 112 on the measured server), else its first loaded member. Never
        // Home's rows, which are not on this page.
        if let collection = drillInItem {
            let member = sectionsSnapshot.first { !$0.items.isEmpty }?.items.first?.heroBackdropRequest()
            guard let url = collection.heroBackdropRequest().backdropURL
                    ?? member?.backdropURL ?? member?.thumbnailURL else { return }
            ambientView.setAmbient(url: url)
            return
        }
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
        if let loadedFeedItems, case .library(_, let title) = mode {
            let items = authorizedFeedItems(loadedFeedItems)
            return items.isEmpty ? [] : [.grid(items: items, title: title)]
        }
        if let hub = nativeHubSource {
            return gridItems.isEmpty ? [] : [.grid(items: mapGridSlots(gridItems), title: hub.title)]
        }
        if case .library(let key, let title) = mode {
            return computeLibrarySections(libraryKey: key, libraryTitle: title)
        }
        if case .discover = mode {
            return computeDiscoverSections()
        }
        if case .watchlist = mode {
            let items = watchlistService.watchlistItems
            var rows = items.isEmpty ? [] : [HomeSectionData.watchlistGrid(items: items)]
            for source in ServerDataStore.shared.sources {
                let items = visibleNativeItems(nativeWatchlistItems.filter { $0.ref.providerID == source.providerID })
                guard !items.isEmpty else { continue }
                rows.append(.searchGrid(id: .init(raw: "watchlist:\(source.providerID)"),
                                        title: "\(source.name) · Watchlist", items: items))
            }
            return rows + nativeErrorSections(nativeWatchlistErrors)
        }
        // One titled grid; the header is supplementary, so the grid stays
        // section 0 (`topSectionIndex`) and Menu never stages a return-to-top.
        if case .collection(let item) = mode {
            return gridItems.isEmpty ? [] : [.grid(items: mapGridSlots(gridItems), title: item.title)]
        }
        if case .playlists = mode {
            return gridItems.isEmpty ? [] : [.grid(items: mapGridSlots(gridItems))]
        }
        // Title, Play and Shuffle ride the header cell; `topSectionIndex` keeps Menu dismissing.
        if case .playlist(let playlist) = mode {
            return gridItems.isEmpty ? [] : [.sortHeader(title: playlist.item.title), .grid(items: mapGridSlots(gridItems))]
        }
        if case .search = mode {
            return computeSearchSections()
        }

        var sections: [HomeSectionData] = []

        // Hero (when enabled): the real carousel once items resolve; while
        // the trending fetch is in flight the section stays in the snapshot
        // as a fixed-height placeholder so rows below never shift.
        let jellyfin = ServerDataStore.shared
        let heroSource = homeHeroSource
        let hasNativeFeatured = jellyfin.visibleHomeRows.contains { $0.style == .hero }
        if showHomeHero, !hasNativeFeatured, heroSource == .plex {
            if !heroItems.isEmpty {
                sections.append(.hero(items: heroItems))
            } else if heroState == .loading {
                sections.append(.hero(items: []))
            }
        } else if showHomeHero, !hasNativeFeatured, heroSource == .both, isPlexHeroPending {
            if heroState == .loading { sections.append(.hero(items: [])) }
        } else if showHomeHero, !hasNativeFeatured {
            // Without Plex, Jellyfin's trending titles (its newest additions
            // when too few match); with both servers, those mixed with Plex's
            // hero (Jellyfin's alone when Plex's ends unavailable).
            let items = homeMediaHeroItems()
            if !items.isEmpty { sections.append(.discoverHero(items: items)) }
        }

        // CW and per-library Recently Added rows come from `dataStore.homeItems`; each CachedHomeHub maps
        // straight to a HomeSectionData. Other servers' rows sit beside Plex's, paired by server (`homeRail`).
        // With more than one server, Continue Watching is one merged row under one id (#87).
        let labelsServers = jellyfin.labelsServers
        let plexVisible = MediaProviderRegistry.shared.plexProvider.map {
            LibrarySettingsManager.shared.areServerLibrariesVisible($0.id)
        } ?? true
        let rail = Self.homeRail(plex: plexVisible ? dataStore.homeItems : [], jellyfin: jellyfin.visibleHomeRows,
                                 libraryOrder: Self.sidebarLibraryOrder())
        var cwOthers: [MediaItemRef: [MediaItem]] = [:]
        mergedCWSources = labelsServers ? rail.filter(\.row.isContinueWatching).map(\.row) : []
        var mergedCWSection: HomeSectionData?
        if labelsServers {
            // A removal in flight hides the whole card, so another server's copy
            // does not stand in for the one just removed.
            let cwItems = mergedCWSources.map { row in
                row.nativeProviderID?.hasPrefix("silo:") == true ? reconciledNativeItems(row) : row.items
            }
            let cards = ContinueWatchingRow.shared.cards(cwItems,
                                                         identity: { $0.identity ?? [] }, lookupKey: \.lookupKey,
                                                         watched: \.userState.lastViewedAt)
                .filter { card in !card.copies.contains { pendingCWRemovals.contains($0.ref.itemID) } }
            for card in cards where !card.others.isEmpty { cwOthers[card.item.ref] = card.others }
            if !cards.isEmpty {
                mergedCWSection = .hub(id: Self.mergedContinueWatchingID, title: "Continue Watching",
                                       items: cards.map(\.item), isContinueWatching: true, hubKey: nil,
                                       hubIdentifier: Self.mergedContinueWatchingID.raw)
            }
        }
        mergedCWOthers = cwOthers
        for (hub, kind) in rail {
            if labelsServers && hub.isContinueWatching {
                if let section = mergedCWSection {
                    sections.append(section)
                    mergedCWSection = nil
                }
                continue
            }
            if hub.nativeProviderID?.hasPrefix("silo:") == true {
                if hub.style == .hero, !showHomeHero { continue }
                sections.append(nativeSection(hub))
                continue
            }
            let id = HomeSectionID(raw: hub.id)
            let merged = mergedItems(forSection: id, initial: hub.items)
            var items = merged.items
            if hub.isContinueWatching, !pendingCWRemovals.isEmpty {
                items.removeAll { pendingCWRemovals.contains($0.ref.itemID) }
            }
            var section = HomeSectionData.hub(
                id: id,
                title: hub.title,
                items: items,
                isContinueWatching: hub.isContinueWatching,
                hubKey: hub.hubKey,
                hubIdentifier: hub.hubIdentifier,
                totalSize: merged.totalSize ?? hub.totalSize
            )
            section.sourceBadge = labelsServers
                ? Self.serverName(providerID: hub.items.first?.ref.providerID, kind: kind) : nil
            sections.append(section)
        }

        // Native featured rows keep their server-defined position and slides.
        listHeroItems = hasNativeFeatured ? [] : heroItemsForList(from: sections, rail: rail)
        if heroShowsList {
            sections.removeAll { $0.kind == .hero }
            sections.insert(.discoverHero(items: listHeroItems), at: 0)
        }

        // Watchlist
        // Uncapped: the row is the only place Home shows the watchlist, so a
        // cap here hid entries the user added and could not otherwise reach.
        // Tiles cost nothing until the row scrolls to them, and the tap path
        // maps a window around the tapped entry rather than the whole list.
        let watchlistItems = watchlistService.watchlistItems
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
            // else: no section when recommendations come back empty.
        }

        return sections + nativeErrorSections(ServerDataStore.shared.errors)
    }

    /// Preserve legacy Plex/Jellyfin library ordering without moving native rows.
    /// The renderer merges cross-server Continue Watching at its earliest position;
    /// native-only layouts retain the server's exact sequence and route metadata.
    static func homeRail(plex: CachedHomeRail, jellyfin: CachedHomeRail, libraryOrder: [String] = [])
        -> [(row: CachedHomeHub, kind: MediaProviderKind)] {
        let tag = { (rows: [CachedHomeHub], kind: MediaProviderKind) in rows.map { (row: $0, kind: kind) } }
        let nativeRows = jellyfin.filter { $0.nativeProviderID?.hasPrefix("silo:") == true }
        let legacyRows = jellyfin.filter { $0.nativeProviderID?.hasPrefix("silo:") != true }
        var libraryRows = tag(plex.filter { !$0.isContinueWatching }, .plex)
            + tag(legacyRows.filter { !$0.isContinueWatching }, .jellyfin)
        if !libraryOrder.isEmpty {
            let rank = Dictionary(libraryOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            var last = -1
            let ranked = libraryRows.map { entry -> (entry: (row: CachedHomeHub, kind: MediaProviderKind), rank: Int) in
                last = entry.row.libraryKey.flatMap { rank[$0] } ?? last
                return (entry, last)
            }
            libraryRows = ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
                .map(\.element.entry)
        }
        return tag(plex.filter(\.isContinueWatching), .plex)
            + tag(legacyRows.filter(\.isContinueWatching), .jellyfin)
            + libraryRows
            + tag(nativeRows, .silo)
    }

    /// Every visible library's key in the sidebar's order across servers.
    static func sidebarLibraryOrder() -> [String] {
        let plex = PlexDataStore.shared.visibleSidebarLibraries.map(\.key)
        let others = ServerDataStore.shared.visibleLibraries.map(\.settingsKey)
        return LibrarySettingsManager.shared.arrange(plex + others) { $0 }
    }

    /// The badge naming an item's server, shown only with multiple visible sources.
    static func sourceBadge(for ref: MediaItemRef, labelsServers: Bool) -> String? {
        labelsServers ? serverName(providerID: ref.providerID,
                                  kind: ref.providerID.hasPrefix("silo:") ? .silo : (ref.isJellyfin ? .jellyfin : .plex)) : nil
    }

    /// The server's own name ("Angel", "Rivulet Test"), falling back to the
    /// backend's name when the provider is no longer registered.
    static func serverName(providerID: String?, kind: MediaProviderKind) -> String {
        let registry = MediaProviderRegistry.shared
        let provider = providerID.flatMap(registry.provider(for:))
            ?? (kind == .plex ? registry.plexProvider
                : registry.enabledProviders().first { $0.kind == kind })
        return provider?.displayName ?? kind.displayName
    }

    /// A provider surface's hero: the newest additions with a backdrop, up to
    /// ten, the way a Plex library's hub-backed hero falls back to its
    /// recent items.
    static func heroItems(from rows: CachedHomeRail) -> [MediaItem] {
        let featured = rows.filter { $0.style == .hero }
        return Array((featured.isEmpty ? rows.filter { !$0.isContinueWatching } : featured)
            .flatMap(\.items)
            .filter { ($0.grandparentArtwork?.backdrop ?? $0.artwork.backdrop) != nil }
            .prefix(10))
    }

    /// The other servers' Home hero: their trending titles, one library at a
    /// time, when enough have a backdrop; their newest additions otherwise.
    static func heroItems(trending: [[MediaItem]], rows: CachedHomeRail) -> [MediaItem] {
        let picks = Array(roundRobin(trending)
            .filter { ($0.grandparentArtwork?.backdrop ?? $0.artwork.backdrop) != nil }
            .prefix(10))
        return picks.count >= heroTMDBMinMatches ? picks : heroItems(from: rows)
    }

    /// Which signed-in servers Home's hero draws from.
    enum HomeHeroSource { case plex, jellyfin, both, none }

    static func homeHeroSource(plexSignedIn: Bool, jellyfinSignedIn: Bool) -> HomeHeroSource {
        switch (plexSignedIn, jellyfinSignedIn) {
        case (true, false): .plex
        case (false, true): .jellyfin
        case (true, true): .both
        case (false, false): .none
        }
    }

    /// Both servers' hero slides, alternating, so neither server's picks
    /// sink under the other's.
    static func mixedHeroItems(plex: [MediaItem], jellyfin: [MediaItem], cap: Int) -> [MediaItem] {
        Array(interleave(plex, jellyfin).prefix(cap))
    }

    private var homeHeroSource: HomeHeroSource {
        let plexVisible = MediaProviderRegistry.shared.plexProvider.map {
            LibrarySettingsManager.shared.areServerLibrariesVisible($0.id)
        } ?? true
        return Self.homeHeroSource(plexSignedIn: authManager.hasCredentials && plexVisible,
                                   jellyfinSignedIn: !ServerDataStore.shared.visibleHomeRows.isEmpty)
    }

    /// Plex's hero has not resolved yet: no slot before selection starts,
    /// the placeholder while it runs, exactly as on a Plex-only Home.
    private var isPlexHeroPending: Bool {
        heroItems.isEmpty && (heroState == .idle || heroState == .loading)
    }

    /// Home's MediaItem hero: Jellyfin's alone, or both servers' mixed once
    /// Plex's has resolved (`heroItems` stays the Plex source of truth and is
    /// mapped here, at render time; Jellyfin's alone when Plex's ends
    /// unavailable). Empty for a Plex-only Home, whose hero is `heroItems`.
    private func homeMediaHeroItems() -> [MediaItem] {
        let store = ServerDataStore.shared
        if let featured = store.visibleHomeRows.first(where: { $0.style == .hero }) {
            return visibleNativeItems(paginationStates[HomeSectionID(raw: featured.id)]?.loadedItems ?? featured.items)
        }
        let jellyfin = Self.heroItems(trending: store.visibleTrending, rows: store.visibleHomeRows)
        switch homeHeroSource {
        case .plex: return []
        case .jellyfin, .none: return jellyfin
        case .both:
            if isPlexHeroPending { return [] }
            return Self.mixedHeroItems(plex: heroItems.map(mediaItemMapper()), jellyfin: jellyfin, cap: 10)
        }
    }

    /// Library-mode section assembly: hero (from the library's own hubs) +
    /// one row per library hub, in Plex's order — its Continue Watching,
    /// Recently Added/Released, genre rows, etc. No watchlist row, no
    /// recommendations. Rows reuse the home's hub pipeline verbatim, so they
    /// get `mergedItems` pagination (hubKey) for free.
    private func computeLibrarySections(libraryKey key: String, libraryTitle: String) -> [HomeSectionData] {
        guard LibrarySettingsManager.shared.isLibraryVisible(providerLibrary?.settingsKey ?? key) else { return [] }
        var sections: [HomeSectionData] = []

        let hasFeatured = providerLibraryRows.contains { $0.style == .hero }
        if showHomeHero, !hasFeatured, providerLibrary != nil {
            if !providerHeroItems.isEmpty { sections.append(.discoverHero(items: providerHeroItems)) }
        } else if showHomeHero, !hasFeatured {
            if !heroItems.isEmpty {
                sections.append(.hero(items: heroItems))
            } else if heroState == .loading {
                sections.append(.hero(items: []))
            }
        }

        // Library hub rows come from `dataStore.libraryItemsByKey[key]`. The Recent and Discovery Rows
        // gates apply here at render time, never in `projectLibraryItems`, which writes the on-disk rail.
        let showRecentRows = (UserDefaults.standard.object(forKey: "showLibraryRecentRows") as? Bool) ?? true
        let showDiscoveryRows = (UserDefaults.standard.object(forKey: "showLibraryRecommendations") as? Bool) ?? true

        let firstHubRow = sections.count
        var hubRowKinds: [(isContinueWatching: Bool, isRecent: Bool)] = []
        let hubRows = providerLibrary == nil ? (dataStore.libraryItemsByKey[key] ?? []) : providerLibraryRows
        for hub in hubRows {
            if hub.nativeProviderID?.hasPrefix("silo:") == true {
                if !showRecentRows, isRecentRow(hub) { continue }
                if !showDiscoveryRows, !isEssentialRow(hub) { continue }
                if hub.style == .hero, !showHomeHero { continue }
                sections.append(nativeSection(hub))
                continue
            }
            if !showRecentRows, isRecentRow(hub) { continue }
            if !showDiscoveryRows, !isEssentialRow(hub) { continue }
            hubRowKinds.append((isContinueWatching: hub.isContinueWatching, isRecent: isRecentRow(hub)))
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

        // Collections: placed after the gates, so it follows whatever CW and
        // recent rows survive. Not part of projectLibraryItems (that rail is
        // written to disk and re-projected without this list), so it has no
        // warm-launch cache and arrives with refreshThisLibraryHubs. No
        // hubKey, so loadMoreIfNeeded never pages it.
        if !libraryCollections.isEmpty {
            sections.insert(.hub(
                id: .libraryCollections,
                title: "Collections",
                items: libraryCollections,
                isContinueWatching: false,
                hubKey: nil,
                hubIdentifier: nil,
                totalSize: libraryCollections.count
            ), at: firstHubRow + Self.collectionsRowInsertionIndex(rows: hubRowKinds))
        }

        // Collections pinned to this page, right after the Collections row.
        // Not gated by Recent / Discovery Rows: the user asked for each one.
        if let libraryUUID = dataStore.libraries.first(where: { $0.key == key })?.uuid {
            var at = firstHubRow + Self.collectionsRowInsertionIndex(rows: hubRowKinds)
                + (libraryCollections.isEmpty ? 0 : 1)
            let rows = Self.libraryPinRows(
                pins: HomeCollectionPins.pins(in: .library), libraryUUID: libraryUUID,
                hubKeys: Set((dataStore.libraryHubs[key] ?? []).compactMap(\.key)),
                fetched: libraryPinItems)
            for row in rows {
                let id = HomeSectionID(raw: "libraryPin:\(row.pin.ratingKey)")
                let merged = mergedItems(forSection: id, initial: mapToMediaItems(row.items))
                sections.insert(.hub(
                    id: id,
                    title: row.pin.title,
                    items: merged.items,
                    isContinueWatching: false,
                    hubKey: row.pin.childrenKey,
                    hubIdentifier: nil,
                    totalSize: merged.totalSize
                ), at: at)
                at += 1
            }
        }

        // Below the hub rows: the sort header (library title + count + sort
        // button) and the whole-library poster grid. Always present so the
        // header renders while the grid's first page is still in flight (an
        // empty grid section lays out at zero height). gridItems arrives
        // mapped; unloaded slots become placeholders for the cell.
        sections.append(.sortHeader(title: libraryTitle))
        sections.append(.grid(items: mapGridSlots(gridItems)))

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

    /// Where the Collections row goes among a library's hub rows: right after
    /// the LAST Continue Watching or recent row, else first. Keyed on the
    /// last essential row so a genre or promoted-collection hub that an
    /// admin moved above them cannot pull Collections up with it.
    nonisolated static func collectionsRowInsertionIndex(rows: [(isContinueWatching: Bool, isRecent: Bool)]) -> Int {
        rows.lastIndex { $0.isContinueWatching || $0.isRecent }.map { $0 + 1 } ?? 0
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

    /// Merged items (initial plus paginated-in) and total size for a section, seeding its state on
    /// first use. Dedupes by `ref.itemID`.
    private func mergedItems(forSection id: HomeSectionID, initial: [MediaItem])
    -> (items: [MediaItem], totalSize: Int?) {
        if var state = paginationStates[id] {
            // The fresh projection is always the head; only paginated-in extras survive. A refresh can reorder
            // or advance progress without changing the item set.
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
        metas.map(mediaItemMapper())
    }

    /// Grid slots → cell items, position for position. An unloaded slot
    /// becomes `MediaItem.gridPlaceholder`.
    private func mapGridSlots(_ slots: [MediaItem?]) -> [MediaItem] {
        slots.map { $0 ?? .gridPlaceholder }
    }

    private func mediaItemMapper() -> (PlexMetadata) -> MediaItem {
        let serverURL = authManager.selectedServerURL ?? ""
        let token = authManager.selectedServerToken ?? ""
        let providerID = MediaProviderRegistry.shared.plexProvider?.id ?? "plex:\(serverURL)"
        return { PlexMediaMapper.item($0, providerID: providerID, serverURL: serverURL, authToken: token) }
    }

    private func isRecentlyAdded(_ hub: PlexHub) -> Bool {
        let id = hub.hubIdentifier?.lowercased() ?? ""
        let title = hub.title?.lowercased() ?? ""
        return id.contains("recentlyadded") || title.contains("recently added")
    }

    // MARK: - Hero selection

    private static let heroItemCap = 9
    private static let heroTMDBMinMatches = 3
    /// Narrowest backdrop, in pixels, that still reads sharp full screen on a 4K panel (#385).
    private static let heroMinimumArtWidth = 1280

    /// Hero slot state. `.loading` holds a fixed-height placeholder so rows never shift. `.unavailable`
    /// gives the slot up once TMDB and the hub fallback both come back empty on settled hubs.
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

        // Hero source and cache slot: Home uses the global hubs under "home", a library its own hubs
        // under its library key.
        let cacheKey: String
        let sourceHubs: [PlexHub]
        switch mode {
        case .discover, .search, .watchlist, .collection, .playlists, .playlist:
            return  // no Plex-hub hero on these surfaces
        case .home:
            // Jellyfin-only, or showing a list: MediaItem hero
            guard authManager.hasCredentials, !heroShowsList else { return }
            cacheKey = "home"
            sourceHubs = dataStore.hubs
        case .library(let key, _):
            if providerLibrary != nil { return }  // MediaItem hero
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
        case .discover, .search, .watchlist, .collection, .playlists, .playlist: isTMDBEligible = false
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

    /// Drops hero candidates from libraries removed from Home. Neither `/hubs` nor `LibraryGUIDIndex`
    /// knows the client-side Home set, and only PlexMetadata carries section attribution, so this is the
    /// last place to apply it. Fails open on an unloaded library list. Library heroes are left alone.
    private func heroItemsVisibleOnHome(_ items: [PlexMetadata]) -> [PlexMetadata] {
        switch mode {
        case .home:
            if let plex = MediaProviderRegistry.shared.plexProvider,
               !LibrarySettingsManager.shared.areServerLibrariesVisible(plex.id) { return [] }
            return PlexLibraryVisibilityFilter.filter(
                items,
                toLibraryKeys: dataStore.librariesPinnedToHome.map { $0.key }
            )
        case .library, .discover, .search, .watchlist, .collection, .playlists, .playlist:
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

    /// Up to `cap` owned library items from TMDB trending. `type == nil` (Home) interleaves movies and
    /// TV; a typed library fetches only its own type.
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

        // Twice the cap, so dropping low-resolution art still fills the hero.
        var entries: [LibraryGUIDIndex.Entry] = []
        for item in ordered {
            if let entry = await LibraryGUIDIndex.shared.lookup(tmdbId: item.id, type: item.mediaType) {
                entries.append(entry)
                if entries.count >= cap * 2 { break }
            }
        }
        let auth = PlexAuthManager.shared
        var matches: [PlexMetadata] = []
        if let serverURL = auth.selectedServerURL, let token = auth.selectedServerToken, !entries.isEmpty {
            let owned = await LibraryGUIDIndex.items(for: entries, serverURL: serverURL, authToken: token)
            matches = entries.compactMap { owned[$0.ratingKey] }
        }
        matches = Array(await sharpHeroItems(matches).prefix(cap))
        let matchTitles = matches.map { "\($0.title ?? "?") [\($0.type ?? "?")]" }.joined(separator: ", ")
        homeUIKitLog.debug("[Hero] computeTMDBHero: \(ordered.count, privacy: .public) trending items -> \(matches.count, privacy: .public) matches (cap=\(cap, privacy: .public)): \(matchTitles, privacy: .public)")
        return matches
    }

    /// Drops items whose backdrop is missing or too small to show full screen. An image that
    /// can't be read keeps its item. Reads each original once; the hero shows the same bytes.
    static func sharpHeroItems(_ items: [PlexMetadata]) async -> [PlexMetadata] {
        let auth = PlexAuthManager.shared
        guard let serverURL = auth.selectedServerURL, let token = auth.selectedServerToken else { return items }
        let urls = items.map { item -> URL? in
            let request = item.heroBackdropRequest(serverURL: serverURL, authToken: token)
            return request.backdropURL ?? request.thumbnailURL
        }
        let widths = await withTaskGroup(of: (Int, Int?).self) { group in
            for (index, url) in urls.enumerated() {
                guard let url else { continue }
                group.addTask { (index, await ImageCacheManager.shared.pixelWidth(for: url)) }
            }
            var widths: [Int: Int?] = [:]
            for await (index, width) in group { widths[index] = width }
            return widths
        }
        let kept = items.indices.filter { index in
            guard let width = widths[index] else { return false }  // no artwork at all
            return width.map { $0 >= heroMinimumArtWidth } ?? true
        }
        if kept.count < items.count {
            homeUIKitLog.debug("[Hero] dropped \(items.count - kept.count, privacy: .public) items with low-resolution art")
        }
        return kept.map { items[$0] }
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
            guard authManager.hasCredentials, !heroShowsList else { return }
            cacheKey = "home"
            heroType = nil
        case .library(let key, _):
            guard providerLibrary == nil else { return }
            // A typed library must resolve to a concrete type; a non-video
            // library (nil) is not eligible and must bail here so the home
            // interleave path never runs on it.
            // Libraries may not have loaded yet (type resolves to nil); reset so a
            // later trigger, once libraries load, can re-attempt at this generation.
            guard let t = trendingHeroType() else { lastUpgradedIndexGeneration = -1; return }
            cacheKey = key
            heroType = t
        case .discover, .search, .watchlist, .collection, .playlists, .playlist:
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
        case .discover, .search, .watchlist, .collection, .playlists, .playlist: return
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
        let heroes = sectionsSnapshot.filter { $0.kind == .hero }.map {
            HomeItemID(sectionID: $0.id, itemID: "hero-overlay")
        }.filter { snap.indexOfItem($0) != nil }
        guard !heroes.isEmpty else { return }
        snap.reconfigureItems(heroes)
        dataSource.apply(snap, animatingDifferences: false)
    }

    // MARK: - Recommendations

    @MainActor
    private func refreshRecommendations(force: Bool) async {
        guard enablePersonalizedRecommendations else { return }
        if force || recommendations.isEmpty { isLoadingRecommendations = true }
        recommendationsError = nil
        // A profile switch mid-fetch: the new profile's refresh owns the row.
        let contentUserID = { UserDefaults.standard.integer(forKey: PlexProfileSession.contentUserIDKey) }
        let userID = contentUserID()

        do {
            let items = try await recommendationService.recommendations(
                forceRefresh: force,
                contentType: .moviesAndShows
            )
            guard userID == contentUserID() else { return }
            recommendations = items
            isLoadingRecommendations = false
            applySnapshot(animated: false)
        } catch {
            guard userID == contentUserID() else { return }
            recommendations = []
            recommendationsError = error.localizedDescription
            isLoadingRecommendations = false
            applySnapshot(animated: false)
        }
    }

    // MARK: - Direct play

    /// Continue Watching play (tile tap and "Watch from Beginning"). The player needs PlexMetadata,
    /// resolved lazily by ratingKey; the resume prompt reads the MediaItem so it shows without waiting.
    private func playItem(_ item: MediaItem, fromBeginning: Bool = false, sourceID: String? = nil) {
        guard item.isAvailable != false else { return }
        // Every Home, library and search play routes here. Only the Plex path
        // resolves a ratingKey; any other item plays through its own provider,
        // behind the same resume prompt.
        if !item.ref.isPlex {
            let offsetSec = item.userState.viewOffset
            if promptResumeOrRestart, !fromBeginning, item.isInProgress, offsetSec > 0 {
                presentResumeChoice(forMediaItem: item, offsetSec: offsetSec, sourceID: sourceID)
            } else {
                resolveAndPlay(item, fromBeginning: fromBeginning, sourceID: sourceID)
            }
            return
        }
        let ratingKey = item.ref.itemID
        guard !ratingKey.isEmpty,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        // Resume prompt: gate on the MediaItem's own progress, then resolve
        // the metadata for the chosen branch.
        let offsetSec = item.userState.viewOffset
        if promptResumeOrRestart, !fromBeginning, item.isInProgress, offsetSec > 0 {
            presentResumeChoice(forMediaItem: item, offsetSec: offsetSec, sourceID: sourceID)
            return
        }

        Task { @MainActor in
            guard let meta = try? await PlexNetworkManager.shared.getFullMetadata(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            ) else { return }
            playItemDirectly(meta, fromBeginning: fromBeginning, mediaID: sourceID)
        }
    }

    /// Resume-or-restart prompt driven by a MediaItem (CW play path). Resolves
    /// PlexMetadata lazily inside the chosen action so the prompt itself never
    /// blocks on the network.
    private func presentResumeChoice(forMediaItem item: MediaItem, offsetSec: TimeInterval, sourceID: String? = nil,
                                     onChoice: ((_ fromBeginning: Bool) -> Void)? = nil) {
        let play = onChoice ?? { [weak self] in self?.resolveAndPlay(item, fromBeginning: $0, sourceID: sourceID) }
        let offsetMs = Int(offsetSec * 1000)
        let alert = UIAlertController(
            title: "Resume Playback?",
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Resume from \(PlexMetadata.formatResumeTime(offsetMs))", style: .default) { _ in
            play(false)
        })
        alert.addAction(UIAlertAction(title: "Start from Beginning", style: .default) { _ in
            play(true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Resolve a MediaItem to PlexMetadata by ratingKey and play it, bypassing
    /// the resume prompt (the caller already made the resume/restart choice).
    private func resolveAndPlay(_ item: MediaItem, fromBeginning: Bool, sourceID: String? = nil) {
        if !item.ref.isPlex {
            ProviderPlayer.play(item, fromBeginning: fromBeginning, sourceID: sourceID, from: self, onDismiss: nil)
            return
        }
        let ratingKey = item.ref.itemID
        guard !ratingKey.isEmpty,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        Task { @MainActor in
            guard let meta = try? await PlexNetworkManager.shared.getFullMetadata(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            ) else { return }
            presentPlayer(for: meta, fromBeginning: fromBeginning, mediaID: sourceID)
        }
    }

    /// Plays a PlexMetadata item, with the resume-or-restart prompt when `promptResumeOrRestart` is on.
    private func playItemDirectly(_ item: PlexMetadata, fromBeginning: Bool = false, mediaID: String? = nil) {
        if promptResumeOrRestart,
           !fromBeginning,
           item.isInProgress,
           let offsetMs = item.viewOffset, offsetMs > 0 {
            presentResumeChoice(for: item, offsetMs: offsetMs, mediaID: mediaID)
        } else {
            presentPlayer(for: item, fromBeginning: fromBeginning, mediaID: mediaID)
        }
    }

    private func presentResumeChoice(for item: PlexMetadata, offsetMs: Int, mediaID: String? = nil) {
        let alert = UIAlertController(
            title: "Resume Playback?",
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Resume from \(PlexMetadata.formatResumeTime(offsetMs))", style: .default) { [weak self] _ in
            self?.presentPlayer(for: item, fromBeginning: false, mediaID: mediaID)
        })
        alert.addAction(UIAlertAction(title: "Start from Beginning", style: .default) { [weak self] _ in
            self?.presentPlayer(for: item, fromBeginning: true, mediaID: mediaID)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func presentPlayer(for item: PlexMetadata, fromBeginning: Bool, mediaID: String? = nil) {
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
                loadingThumbImage: thumbImage,
                preferredMediaID: mediaID
            )
            PlayerPresenter.present(viewModel: viewModel, from: self, onDismiss: { [weak self] in
                Task { await self?.dataStore.refreshHubs() }
            })
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
            return  // the embedded buttons open their own menus
        case .searchPrompt, .searchState:
            return  // recents pills / Try Again are FocusableActionButtons
        case .continueWatching, .recentlyAdded, .recommendations, .watchlist, .discoverList, .searchGrid:
            return  // shelf rows route taps through their own delegate (handleShelfTap)
        case .grid:
            guard let item = section.items[safe: indexPath.item], !item.isGridPlaceholder else { return }
            presentPreview(forSection: section, indexPath: indexPath)
        case .watchlistGrid:
            Task { await openWatchlistPreview(section: section, tappedIndex: indexPath.item, indexPath: indexPath) }
        }
    }


    /// Detail for a MediaItem (tile-menu "More Info", "Go to"): the season page, the episode page,
    /// the standalone expanded detail for everything else.
    private func selectMediaItem(_ item: MediaItem) {
        if item.kind == .season {
            present(SeasonDetailViewController(season: item), animated: true)
        } else if item.kind == .episode {
            let page = MediaItemDetailPageViewController(
                item: item,
                seriesTitle: nil,
                onPlay: { [weak self] target, sourceID in self?.playResolvingEpisode(target, sourceID: sourceID) })
            present(page, animated: true)
        } else {
            presentStandaloneExpandedDetail(item)
        }
    }

    /// Hero Info: the full expanded detail, presented standalone (one item, Menu dismisses).
    private func presentDetailPage(for meta: PlexMetadata) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let providerID = MediaProviderRegistry.shared.plexProvider?.id ?? "plex:\(serverURL)"
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

    /// A Plex music tile outside Search (Home's Recently Added in Music). The tile does not
    /// say album, artist or track, so the item is fetched first. False for any other tile.
    private func withMusicItem(for item: MediaItem,
                               _ then: @escaping @MainActor (MusicItem) async -> Void) -> Bool {
        guard item.isMusic == true,
              item.ref.providerID == MediaProviderRegistry.shared.plexProvider?.id,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return false }
        Task { [weak self] in
            do {
                let meta = try await PlexNetworkManager.shared.getMetadata(
                    serverURL: serverURL, authToken: token, ratingKey: item.ref.itemID)
                guard let provider = MusicProviderRegistry.shared.primaryProvider,
                      let music = PlexMusicMapper.item(meta, providerID: provider.id,
                                                       serverURL: serverURL, authToken: token) else { return }
                await then(music)
            } catch {
                MusicPresenter.reportFailure(error, from: self)
            }
        }
        return true
    }

    /// Select on a music tile, routed as Search routes it.
    private func openMusicIfNeeded(_ item: MediaItem) -> Bool {
        withMusicItem(for: item) { [weak self] music in
            switch music {
            case .album(let album): MusicPresenter.showAlbum(album, from: self)
            case .artist(let artist): MusicPresenter.showArtist(artist, from: self)
            case .track(let track): MusicQueue.shared.playNow(track: track)
            }
        }
    }

    /// Long press on a music tile: the Music library's menu, not the video one.
    private func presentMusicTileMenuIfNeeded(for item: MediaItem) -> Bool {
        let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem
        let tileFrame = focusedTileFrame()
        return withMusicItem(for: item) { [weak self] music in
            await MusicMenus.loadPlaylists()
            // The fetches took a moment: no menu for a tile focus has already left.
            guard let self, UIFocusSystem.focusSystem(for: view)?.focusedItem === focused else { return }
            let navigate: (MusicNavigationRequest) -> Void = { [weak self] in MusicPresenter.show($0, from: self) }
            let rows = switch music {
            case .album(let album): MusicMenus.album(album, navigate: navigate)
            case .artist(let artist): MusicMenus.artist(artist)
            case .track(let track): MusicMenus.track(track, screen: .songs, navigate: navigate)
            }
            MusicMenus.presentPopup(rows, from: self, sourceFrame: tileFrame)
        }
    }

    private func playMusicTrack(_ plexMeta: PlexMetadata) {
        guard let provider = MusicProviderRegistry.shared.primaryProvider,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let track = PlexMusicMapper.track(plexMeta, providerID: provider.id, serverURL: serverURL, authToken: token)
        MusicQueue.shared.playNow(track: track)
    }

    // MARK: - Preview presentation

    /// Opens a collection tile on its own page; false for anything else. Walks the whole modal stack, so
    /// page, member, collection tile unwinds to the existing page instead of stacking a second.
    @discardableResult
    static func openCollectionIfNeeded(_ item: MediaItem,
                                       from presenter: UIViewController,
                                       onDismiss: (() -> Void)? = nil) -> Bool {
        guard item.kind == .collection else { return false }
        return openDrillIn(item, mode: .collection(item), from: presenter, onDismiss: onDismiss)
    }

    /// `openCollectionIfNeeded` for a playlist tile.
    @discardableResult
    static func openPlaylistIfNeeded(_ item: MediaItem,
                                     listed: MediaPlaylist? = nil,
                                     from presenter: UIViewController,
                                     onDismiss: (() -> Void)? = nil) -> Bool {
        guard item.kind == .playlist else { return false }
        return openDrillIn(item, mode: .playlist(listed ?? PlaylistAvailability.shared.playlist(for: item)),
                           from: presenter, onDismiss: onDismiss)
    }

    /// The playlists grid's own copy of a tile's list, which knows `isSmart`.
    private func listedPlaylist(for item: MediaItem) -> MediaPlaylist? {
        loadedPlaylists.first { $0.item.ref == item.ref }
    }

    private static func openDrillIn(_ item: MediaItem, mode: HomeMode,
                                    from presenter: UIViewController,
                                    onDismiss: (() -> Void)?) -> Bool {
        var top = presenter
        while let presented = top.presentedViewController { top = presented }
        var node: UIViewController? = top
        while let vc = node {
            if let page = vc as? PlexHomeViewController, let open = page.drillInItem,
               open.kind == item.kind, open.ref.itemID == item.ref.itemID {
                // dismiss on a presenter unwinds what it presented. On a page
                // that is already on top it would dismiss the page itself.
                if page.presentedViewController != nil { page.dismiss(animated: true) }
                return true
            }
            node = vc.presentingViewController
        }
        let page = PlexHomeViewController(mode: mode)
        page.onDismiss = onDismiss
        top.present(page, animated: true)
        return true
    }

    /// Plays `entries` in list order from `index`, or shuffled. Play from the top
    /// offers the list's continue point first, in the Resume Playback popup's look.
    func startPlaylist(_ entries: [PlaylistEntry], at index: Int, shuffled: Bool, title: String? = nil) {
        if shuffled {
            if let queue = PlayQueue.shuffled(entries) { playQueue(queue) }
            return
        }
        guard index == 0, let resume = PlayQueue.continuePoint(in: entries), resume > 0 else {
            if let queue = PlayQueue(entries: entries, startingAt: index) { playQueue(queue) }
            return
        }
        var title = title
        if title == nil, case .playlist(let playlist) = mode { title = playlist.item.title }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (label, start) in [("Continue with \u{201C}\(entries[resume].item.title)\u{201D}", resume),
                               ("Play from Beginning", 0)] {
            alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                if let queue = PlayQueue(entries: entries, startingAt: start) { self?.playQueue(queue) }
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Starts a playlist on its current entry, behind that entry's own resume prompt.
    private func playQueue(_ queue: PlayQueue<PlaylistEntry>) {
        let item = queue.current.item
        let play: (Bool) -> Void = { [weak self] fromBeginning in
            guard let self else { return }
            ProviderPlayer.play(item, fromBeginning: fromBeginning, playQueue: queue, from: self, onDismiss: nil)
        }
        let offsetSec = item.userState.viewOffset
        guard promptResumeOrRestart, item.isInProgress, offsetSec > 0 else { return play(false) }
        presentResumeChoice(forMediaItem: item, offsetSec: offsetSec, onChoice: play)
    }

    private func presentPreview(forSection section: HomeSectionData, indexPath: IndexPath) {
        guard indexPath.item < section.items.count else { return }
        // Grid taps, every shelf row (handleShelfTap) and search
        // (handleSearchTap) all come through here. A collection never opens
        // the carousel, whose Play would hand the collection's key to the player.
        if Self.openCollectionIfNeeded(section.items[indexPath.item], from: self)
            || Self.openPlaylistIfNeeded(section.items[indexPath.item],
                                         listed: listedPlaylist(for: section.items[indexPath.item]), from: self) {
            return
        }
        // Nor does music: the carousel is a video surface.
        if openMusicIfNeeded(section.items[indexPath.item]) { return }
        // The library grid is sparse (unloaded slots are placeholders), so the
        // carousel gets only what has loaded, with the tapped slot remapped to
        // its index in that list. Every other section maps 1:1 and keeps its
        // nil index map, which the shelf entry morph reads as "all tiles".
        let allIDs = sourceItemIDs(for: section)
        let loaded = section.items.indices.filter { !section.items[$0].isGridPlaceholder }
        guard let selected = loaded.firstIndex(of: indexPath.item) else { return }

        presentPreviewOverlay(
            items: loaded.map { section.items[$0] },
            selectedIndex: selected,
            sourceRowID: section.id.raw,
            sourceItemID: allIDs[indexPath.item],
            sourceIndexPath: indexPath,
            sourceIndexMap: section.kind == .grid ? [indexPath.item: selected] : nil,
            sourceItemIDs: loaded.map { allIDs[$0] }
        )
    }

    /// Number of entries either side of the tapped one that get mapped for the
    /// preview carousel. Mapping is per-entry network (a TMDB detail for
    /// anything not owned locally) and the tap awaits all of it, so mapping a
    /// long watchlist whole would stall the open and fire a request storm.
    /// ponytail: fixed window, make it paged from the carousel if anyone ever
    /// scrolls past the edge of one.
    private static let watchlistPreviewWindow = 12

    private func openWatchlistPreview(section: HomeSectionData, tappedIndex: Int, indexPath: IndexPath) async {
        let allEntries = section.watchlistItems
        guard allEntries.indices.contains(tappedIndex) else { return }
        let window = max(0, tappedIndex - Self.watchlistPreviewWindow)
            ..< min(allEntries.count, tappedIndex + Self.watchlistPreviewWindow + 1)
        let entries = Array(allEntries[window])
        let pairs = await buildWatchlistMediaItems(from: entries)
        guard !pairs.isEmpty else { return }

        let tapped = allEntries[tappedIndex]
        // Match on the originating watchlist entry id, which survives both itemID encodings and skipped
        // entries.
        let validIndex = pairs.firstIndex(where: { $0.sourceID == tapped.id }) ?? 0
        let mediaItems = pairs.map(\.item)
        let sourceItemIDs = pairs.map(\.sourceID)
        var sourceIndexMap: [Int: Int] = [:]
        for (previewIndex, pair) in pairs.enumerated() {
            // Indices are in SECTION coordinates (the tile the entry morphs
            // from), so they must be looked up in the full entry list, not in
            // the mapped window.
            if let sourceIndex = allEntries.firstIndex(where: { $0.id == pair.sourceID }) {
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

    /// Parallel GUID-index lookups with TMDB fallback. Returns `(sourceID, item)` pairs so callers match
    /// on the watchlist entry id.
    private func buildWatchlistMediaItems(from entries: [PlexWatchlistItem]) async -> [(sourceID: String, item: MediaItem)] {
        let serverURL = authManager.selectedServerURL ?? ""
        let token = authManager.selectedServerToken ?? ""
        let providerID = MediaProviderRegistry.shared.plexProvider?.id ?? "plex:\(serverURL)"

        // Resolve each entry to the owned library item so detail offers Play (#188). Warm: LibraryGUIDIndex
        // on any external guid. Cold (the bulk index loads ~20s after launch): PMS does not match external
        // guids on /library/all?guid=, but it does match the shared plex:// guid, so resolve that directly.
        // Warm path: in-memory index. Type-safe tmdb first (a movie and a show can share the same numeric
        // tmdb id), then imdb/tvdb guids, which are globally unique. The owned items arrive in one batch.
        var indexed: [Int: LibraryGUIDIndex.Entry] = [:]
        for (index, entry) in entries.enumerated() {
            if let tmdbId = entry.tmdbId,
               let match = await LibraryGUIDIndex.shared.lookup(tmdbId: tmdbId, type: entry.type == .movie ? .movie : .tv) {
                indexed[index] = match
                continue
            }
            for guid in entry.guids where !guid.hasPrefix("tmdb://") {
                if let match = await LibraryGUIDIndex.shared.lookup(guid: guid) {
                    indexed[index] = match
                    break
                }
            }
        }
        var lookups: [Int: PlexMetadata] = [:]
        if !indexed.isEmpty, !serverURL.isEmpty {
            let owned = await LibraryGUIDIndex.items(for: Array(indexed.values), serverURL: serverURL, authToken: token)
            for (index, entry) in indexed {
                lookups[index] = owned[entry.ratingKey]
            }
        }
        // Cold path, and any warm match the batch did not return.
        let cold = await withTaskGroup(of: (Int, PlexMetadata?).self) { group in
            for (index, entry) in entries.enumerated() where lookups[index] == nil {
                guard let plexGUID = entry.plexGUID, !serverURL.isEmpty else { continue }
                group.addTask {
                    (index, try? await PlexNetworkManager.shared.findByGuid(
                        serverURL: serverURL, authToken: token, guid: plexGUID))
                }
            }
            var out: [Int: PlexMetadata] = [:]
            for await (index, match) in group {
                if let match { out[index] = match }
            }
            return out
        }
        lookups.merge(cold) { warm, _ in warm }

        // The carousel renders artwork as-is, so add the TMDB logo to every item (withLogoIfMissing keeps
        // a real Plex logo) and the TMDB backdrop to un-owned ones. Network runs off the main actor.
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
                    grandparentArtwork: base.grandparentArtwork,
                    versionCount: base.versionCount,
                    editionTitle: base.editionTitle
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
        // Skip Preview (#416): open the carousel's own expanded detail directly. An
        // episode keeps its hero and Play, with the show's seasons below.
        if SettingsStore.bool("skipPreviewCarousel", default: false) {
            guard items.indices.contains(selectedIndex) else { return }
            let item = items[selectedIndex]
            if item.kind == .season { selectMediaItem(item) } else { presentStandaloneExpandedDetail(item) }
            return
        }
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
                self?.showPreviewTiles()
                if let sourceTarget {
                    self?.pendingPreviewRestore = sourceTarget
                }
                self?.applyPendingPreviewRestoreIfNeeded()
            }
        )
        carouselVC.onTeardown = { [weak self] in self?.showPreviewTiles() }
        // The row's tiles as they are now, for the exit after paging: shown
        // for the capture, hidden again under the still-opaque carousel.
        carouselVC.freshEntrySnapshots = { [weak self] target in
            guard let self, let path = target.flatMap(self.indexPath(for:)) else { return [] }
            // The row may have changed under the carousel: pair tiles to cards by ID.
            var indexMap = sourceIndexMap
            if let sourceItemIDs {
                let cardIndex = Dictionary(
                    sourceItemIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                indexMap = [:]
                for (row, id) in self.sourceItemIDs(for: self.sectionsSnapshot[path.section]).enumerated() {
                    indexMap?[row] = cardIndex[id]
                }
            }
            let hiddenRow = self.previewHiddenRowID
            self.showPreviewTiles()
            let fresh = self.previewEntrySnapshots(
                at: path, itemIndexMap: indexMap, afterScreenUpdates: true)
            self.previewHiddenRowID = hiddenRow
            self.applyPreviewTileHiding()
            return fresh
        }
        var topVC: UIViewController = self
        while let presented = topVC.presentedViewController { topVC = presented }
        // animated: false — the carousel's spring morph IS the
        // transition. Modal transitions would compose on top.
        topVC.present(carouselVC, animated: false) { [weak self, weak carouselVC] in
            self?.resetVisibleFocusAppearance(except: nil)
            // The flying cards are on screen now and stand in for the tiles.
            guard let self, carouselVC?.presentingViewController != nil, !entrySnapshots.isEmpty else { return }
            self.previewHiddenRowID = sourceRowID
            self.applyPreviewTileHiding()
        }
    }

    // MARK: - Tiles hidden under the preview carousel

    /// Row whose tiles are hidden while the carousel flies them (nil: none).
    private var previewHiddenRowID: String?

    /// Apply `previewHiddenRowID` to the realized shelf rows.
    private func applyPreviewTileHiding() {
        for case let row as ShelfRowCell in collectionView.visibleCells {
            let section = collectionView.indexPath(for: row)?.section ?? -1
            row.tilesHiddenForPreview = previewHiddenRowID != nil
                && sectionsSnapshot.indices.contains(section)
                && sectionsSnapshot[section].id.raw == previewHiddenRowID
        }
    }

    private func showPreviewTiles() {
        previewHiddenRowID = nil
        applyPreviewTileHiding()
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
        // The restore scroll may have realized the row afresh.
        applyPreviewTileHiding()
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
            // Let the dismissal's own focus restore finish first: a request
            // made while it is pending loses to the tile the carousel opened from.
            self.updateFocusIfNeeded()
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
                // Rest the row where focus will hold it, or the focus move
                // that follows scrolls it again (row 1 rests under the hero).
                let rowPath = IndexPath(item: 0, section: indexPath.section)
                if let restY = restingOffsetY(forSection: indexPath.section) {
                    offsetLink?.invalidate()
                    offsetLink = nil
                    collectionView.contentOffset.y = restY
                } else {
                    collectionView.scrollToItem(at: rowPath, at: .centeredVertically, animated: false)
                }
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
        itemIndexMap: [Int: Int]? = nil,
        afterScreenUpdates: Bool = false
    ) -> [PreviewEntrySnapshot] {
        guard indexPath.section < sectionsSnapshot.count else { return [] }
        if isShelfKind(sectionsSnapshot[indexPath.section].kind) {
            let rowPath = IndexPath(item: 0, section: indexPath.section)
            guard let row = collectionView.cellForItem(at: rowPath) as? ShelfRowCell else { return [] }
            return row.visibleEntrySnapshots(itemIndexMap: itemIndexMap, afterScreenUpdates: afterScreenUpdates)
        }
        guard let cell = collectionView.cellForItem(at: indexPath), let window = view.window else { return [] }
        let targetIndex: Int
        if let itemIndexMap {
            guard let mappedIndex = itemIndexMap[indexPath.item] else { return [] }
            targetIndex = mappedIndex
        } else {
            targetIndex = indexPath.item
        }
        return [PreviewEntrySnapshot.capture(
            cell, itemIndex: targetIndex, in: window, afterScreenUpdates: afterScreenUpdates)].compactMap { $0 }
    }

    private func sourceItemIDs(for section: HomeSectionData) -> [String] {
        switch section.kind {
        case .watchlist, .watchlistGrid:
            return section.watchlistItems.map(\.id)
        default:
            let isPlaylistGrid = if case .playlist = mode { section.kind == .grid } else { false }
            return Self.sourceItemIDs(section.items, rowID: section.id.raw, positional: isPlaylistGrid)
        }
    }

    /// Item ids, or the slot where an item has none. `positional` always uses the slot: a playlist
    /// can hold a title twice, and the preview must return focus to the copy it opened from.
    nonisolated static func sourceItemIDs(_ items: [MediaItem], rowID: String, positional: Bool) -> [String] {
        items.enumerated().map { index, item in
            positional || item.ref.itemID.isEmpty ? "\(rowID)-\(index)" : item.ref.itemID
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
            if let itemIndex = sourceItemIDs(for: section).firstIndex(of: target.itemID) {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        case .watchlist, .watchlistGrid:
            if let itemIndex = section.watchlistItems.firstIndex(where: { $0.id == target.itemID }) {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        }
        return nil
    }

    // MARK: - Scroll-on-focus

    /// Align the focused featured section with the viewport, including native
    /// featured rows that are not the page's first section.
    private func scrollHeroIntoView(sectionID: HomeSectionID) {
        guard let sectionIndex = sectionsSnapshot.firstIndex(where: { $0.id == sectionID }) else { return }
        let top = -collectionView.adjustedContentInset.top
        let targetY: CGFloat
        if sectionIndex > 0,
           let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: sectionIndex))?.frame {
            let bottom = max(top, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
            targetY = min(bottom, max(top, frame.minY - collectionView.adjustedContentInset.top))
        } else {
            targetY = top
        }
        guard collectionView.contentOffset.y != targetY else { return }
        animateContentOffset(toY: targetY)
    }

    /// Scroll a row to where it rests while it holds focus.
    private func scrollSectionToRest(sectionIndex: Int) {
        guard let target = restingOffsetY(forSection: sectionIndex),
              abs(collectionView.contentOffset.y - target) > 1 else { return }
        animateContentOffset(toY: target)
    }

    /// The offset a focused row rests at. Focus moves and the preview-dismiss
    /// restore both use it, so a restored row never shifts once focus lands.
    ///
    /// The first row under the hero collapses the hero to a fixed band: a
    /// slice of the hero's bottom (metadata, action row, dots) stays on screen,
    /// so the hero rests at the SAME offset whether row 1 is Continue Watching
    /// or a poster row (centring it instead moved the hero ~84pt between them).
    /// Deeper rows centre, like the SwiftUI version's `scrollTo(anchor: .center)`.
    private func restingOffsetY(forSection sectionIndex: Int) -> CGFloat? {
        guard sectionsSnapshot.indices.contains(sectionIndex) else { return nil }
        let target: CGFloat
        if let heroIndex = heroSectionIndex, sectionIndex == heroIndex + 1 {
            guard let heroAttrs = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: heroIndex))
            else { return nil }
            // Ends the showcase transition here: backdrop floor at meetY, row title at ~390, as Apple's.
            target = heroAttrs.frame.minY + Self.heroBackdropFloor - HeroBackdropView.meetY
        } else {
            guard let attrs = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: sectionIndex))
            else { return nil }
            target = attrs.frame.midY - collectionView.bounds.height / 2
        }
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        return max(-collectionView.adjustedContentInset.top, min(target, maxOffset))
    }

    /// Keep a grid cell's row on screen (library mode), scrolling only as far
    /// as the system's focus scroll would: the row stays 180 pt inside the
    /// edges. Measured from the in-flight target so rapid moves add up.
    private func scrollGridCellIntoView(at indexPath: IndexPath) {
        guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let from = offsetLink != nil ? offsetTargetY : collectionView.contentOffset.y
        let target = FocusScrollMotion.minimalOffset(revealing: attrs.frame, from: from,
                                                     height: collectionView.bounds.height)
        let top = -collectionView.adjustedContentInset.top
        let maxOffset = max(top, collectionView.contentSize.height - collectionView.bounds.height)
        let clamped = max(top, min(target, maxOffset))
        guard abs(from - clamped) > 1 else { return }
        animateContentOffset(toY: clamped)
    }

    /// Section of the focused item, nil outside this page. Read from the focused view, because shelf
    /// tiles live in a nested collection and never resolve to an index path.
    var focusedSectionForHandoff: Int? {
        guard let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
              focused.isDescendant(of: collectionView)
        else { return nil }
        return sectionIndex(forFocusedView: focused)
    }

    /// Scrolls a row fully into view and hands it focus; false if it cannot. The engine will not
    /// move to a row scrolled off the top, and two 492pt rows do not fit the 873pt Search viewport.
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

    /// Scrolls whatever is focused fully on screen. Driven from outside the focus delegate, since the
    /// outer `didUpdateFocusIn` does not reliably run for a tile inside a shelf row's nested collection.
    func revealFocusedRowIfNeeded() {
        guard let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
              focused.isDescendant(of: collectionView)
        else { return }
        // On Search the top row means the page's top, matching where the keyboard hand-off puts it;
        // a minimal reveal leaves it ~180pt higher, under the search chrome.
        if case .search = mode, sectionIndex(forFocusedView: focused) == 0 {
            animateToContentTop()
            return
        }
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

    // MARK: - Per-frame vertical scroll driver

    // `UIView.animate { setContentOffset }` only animates the PRESENTATION layer:
    // the model contentOffset jumps to the target immediately, so the collection
    // recycles cells based on the final offset and a row that lands off-screen has
    // its cells removed at once — it "pops" before finishing its slide-out (worse
    // here because the collection is clipsToBounds=false, so off-bounds cells are
    // visible). A CADisplayLink advancing the real offset per frame recycles cells
    // progressively, so rows scroll out smoothly.
    private var offsetLink: CADisplayLink?
    private var offsetTargetY: CGFloat = 0
    private var offsetVelocity: CGFloat = 0
    private var offsetLastTick: CFTimeInterval = 0

    /// Follows `targetY` with the system's focus-scroll model. A scroll already
    /// in flight is retargeted and keeps its speed, so rapid moves never restart.
    private func animateContentOffset(toY targetY: CGFloat) {
        offsetTargetY = targetY
        guard offsetLink == nil else { return }
        offsetVelocity = 0
        offsetLastTick = CACurrentMediaTime()
        // Weak proxy target: CADisplayLink retains its target, and a discarded instance with a live link
        // would leak with its observers still firing. The proxy invalidates once the VC dies.
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
        @objc func fastTick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.stepFastScroll(link)
        }
    }

    @objc fileprivate func stepOffset(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let step = FocusScrollMotion.follow(from: collectionView.contentOffset.y, to: offsetTargetY,
                                            velocity: offsetVelocity, dt: now - offsetLastTick,
                                            viewport: collectionView.bounds.height)
        offsetLastTick = now
        offsetVelocity = step.velocity
        collectionView.contentOffset = CGPoint(x: 0, y: step.y)
        if step.done {
            link.invalidate()
            offsetLink = nil
        }
    }

    private func releaseHeldArrow(_ presses: Set<UIPress>) {
        guard let heldArrow, presses.contains(where: { $0.type == heldArrow }) else { return }
        self.heldArrow = nil
        guard isOnSystemIndexBar else { return }
        stopFastScroll()
        landFocusOnCenterTile()
    }

    private func startFastScroll() {
        guard fastScrollLink == nil, heldArrow != nil, entryMove?.isMoving != true else { return }
        offsetLink?.invalidate()
        offsetLink = nil
        fastScrollStart = CACurrentMediaTime()
        fastScrollLastTick = fastScrollStart
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.fastTick(_:)))
        link.add(to: .main, forMode: .common)
        fastScrollLink = link
    }

    private func stopFastScroll() {
        fastScrollLink?.invalidate()
        fastScrollLink = nil
    }

    /// Ramps from a brisk row-a-time pace to about a screen every tenth of a
    /// second over ~2.5s of holding; clamps at either end of the content.
    @objc fileprivate func stepFastScroll(_ link: CADisplayLink) {
        guard let heldArrow else { stopFastScroll(); return }
        let now = CACurrentMediaTime()
        let dt = now - fastScrollLastTick
        fastScrollLastTick = now
        let velocity = min(9000.0, 1500.0 + 3000.0 * (now - fastScrollStart))
        let direction: CGFloat = heldArrow == .upArrow ? -1 : 1
        let insetTop = collectionView.adjustedContentInset.top
        let maxOffset = max(-insetTop, collectionView.contentSize.height - collectionView.bounds.height)
        let y = max(-insetTop, min(maxOffset, collectionView.contentOffset.y + direction * CGFloat(velocity * dt)))
        collectionView.contentOffset = CGPoint(x: 0, y: y)
        if y <= -insetTop || y >= maxOffset { stopFastScroll() }
    }

    /// Fast mode over: focus the grid tile nearest the screen centre.
    /// The visible grid tile nearest the viewport's centre.
    private func centerGridIndexPath() -> IndexPath? {
        guard let grid = gridSectionIndex else { return nil }
        collectionView.layoutIfNeeded()
        let centerY = collectionView.contentOffset.y + collectionView.bounds.height / 2
        return collectionView.indexPathsForVisibleItems
            .filter { $0.section == grid }
            .min { a, b in
                let ya = collectionView.layoutAttributesForItem(at: a)?.frame.midY ?? 0
                let yb = collectionView.layoutAttributesForItem(at: b)?.frame.midY ?? 0
                return abs(ya - centerY) < abs(yb - centerY)
            }
    }

    private func landFocusOnCenterTile() {
        stopFastScroll()
        // Move mode: the index bar hands focus back to the held tile, never the centre one.
        if let entryMove, entryMove.isMoving {
            isOnSystemIndexBar = false
            pendingGridFocusItem = entryMove.index
            focusPendingGridSlot()
            return
        }
        guard let nearest = centerGridIndexPath(), let cell = collectionView.cellForItem(at: nearest),
              let system = UIFocusSystem.focusSystem(for: collectionView) else { return }
        isOnSystemIndexBar = false
        system.requestFocusUpdate(to: cell)
        system.updateFocusIfNeeded()
    }

    // MARK: - UIFocusEnvironment override

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Collection page with page 0 in flight: the grid is hidden, so the
        // anchor is the only target inside this modal. Without it focus stays
        // on the library tile underneath, where the library's staged Menu back
        // would swallow Menu and arrows / Select would drive the hidden page.
        if isDrillInPage, case .loading = pageZero {
            return [collectionFocusAnchor]
        }
        // Strip idle return / letter stepping: land on the jumped-to slot.
        if wantsPendingGridFocus {
            wantsPendingGridFocus = false
            if let item = pendingGridFocusItem, let gridSection = gridSectionIndex,
               let cell = collectionView.cellForItem(at: IndexPath(item: item, section: gridSection)) {
                return [cell]
            }
        }
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
        // The Select that dropped a moved tile must not also open it.
        if let entryMove, entryMove.swallowsNextSelect { entryMove.swallowsNextSelect = false; return }
        handleTap(at: indexPath)
    }

    /// After a letter jump, Left off the alphabet bar lands on the slot the
    /// jump revealed, not on the tile the collection remembers from before
    /// the jump (which would drag the grid straight back).
    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        guard let item = pendingGridFocusItem,
              let gridSection = sectionsSnapshot.firstIndex(where: { $0.kind == .grid })
        else { return nil }
        let path = IndexPath(item: item, section: gridSection)
        return collectionView.cellForItem(at: path) != nil ? path : nil
    }

    /// Shelf rows are containers — focus dives through to their tiles.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        guard indexPath.section < sectionsSnapshot.count else { return true }
        let kind = sectionsSnapshot[indexPath.section].kind
        // Prompt and state cells take focus only when they hold a button, and redirect into it: a collection
        // offers its cells as focus items, so an unfocusable cell's buttons are never reached. Only on the
        // way in, or Left from its own button bounces back and never reaches the shell's edge catcher.
        if kind == .searchPrompt || kind == .searchState,
           let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
           let cell = collectionView.cellForItem(at: indexPath), focused.isDescendant(of: cell) {
            return false
        }
        if kind == .searchPrompt { return !recentSearchItems.isEmpty }
        if kind == .searchState { return currentSearchState.hasFocusableAction }
        return !isShelfKind(kind)
    }

    /// Blocks a Left move that would escape to the sidebar while cells to the left in the row are
    /// scrolled off and out of the focus chain; scrolls to and focuses `item - 1` instead.
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
             .watchlistGrid, .searchPrompt, .searchState:
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
        // A row coming back on screen follows the carousel's current state.
        (cell as? ShelfRowCell)?.tilesHiddenForPreview =
            previewHiddenRowID != nil && section.id.raw == previewHiddenRowID
        switch section.kind {
        case .hero, .recommendationsLoading, .recommendationsError, .sortHeader,
             .searchPrompt, .searchState, .searchGrid, .watchlistGrid:
            return  // No pagination for these (the watchlist is fetched whole)
        case .continueWatching, .recentlyAdded, .recommendations, .watchlist, .discoverList:
            return  // Shelf rows paginate from their own willDisplay (shelfWillDisplay)
        case .grid:
            // Sparse grid: fetch the page this slot lives in, plus a
            // look-ahead either side so a held Down/Up does not reach blank
            // slots before their page lands (12 = the old tail threshold).
            loadGridPage(containing: indexPath.item)
            loadGridPage(containing: indexPath.item + 12)
            loadGridPage(containing: indexPath.item - 12)
        }
    }

    /// Select long-press on a library-grid tile → the tile action menu.
    /// Shelf-row tiles have their own recognizer (ShelfRowCell); this one
    /// only serves `.grid` sections, whose tiles are outer-collection cells.
    @objc private func handleGridLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, entryMove?.isMoving != true else { return }
        guard let indexPath = TileLongPress.focusedCell(in: collectionView),
              indexPath.section < sectionsSnapshot.count else { return }
        // Skeleton placeholder doesn't get a menu.
        if let itemID = dataSource.itemIdentifier(for: indexPath),
           itemID.itemID == HomeItemID.skeletonSentinel {
            return
        }
        let section = sectionsSnapshot[indexPath.section]
        if case .searchPrompt = section.kind {
            guard presentedViewController == nil,
                  let recent = (collectionView.cellForItem(at: indexPath) as? SearchRecentsCell)?.focusedRecent
            else { return }
            let remove = TileMenuAction(title: "Remove from Recently Searched", systemImage: "xmark") { [weak self] in
                self?.removeRecentSearchItem(recent.item)
            }
            present(TileMenuPopupViewController(sections: [[remove]], sourceFrame: recent.frame), animated: false)
            return
        }
        // Watchlist tiles are Discover entries, not library items: they get the
        // row's own menu (More Info + Remove from Watchlist), because the
        // library menu's actions all need a server ratingKey.
        if case .watchlistGrid = section.kind {
            presentWatchlistTileMenu(sectionID: section.id, itemIndex: indexPath.item)
            return
        }
        guard case .grid = section.kind, let item = section.items[safe: indexPath.item],
              !item.isGridPlaceholder else { return }
        presentTileMenu(for: item, isContinueWatching: false, gridIndex: indexPath.item)
    }

    // MARK: - Tile menu builder

    nonisolated enum PinAction { case pin, unpin }

    /// What a collection tile's menu offers in a library: nil (no menu) when
    /// the library has no Home block to render into, or when Plex already
    /// promotes this collection to Home; otherwise Unpin if pinned, Pin if not.
    nonisolated static func collectionPinAction(isLibraryPinned: Bool,
                                                promotedChildrenKeys: Set<String>,
                                                childrenKey: String,
                                                isPinned: Bool) -> PinAction? {
        guard isLibraryPinned, !promotedChildrenKeys.contains(childrenKey) else { return nil }
        return isPinned ? .unpin : .pin
    }

    /// A collection tile's menu, in library mode only: Pin to / Unpin from
    /// Home, and Pin to / Unpin from Library. Select already opens the
    /// collection, so there is no Open action. A MediaItem carries no section
    /// id, so the library comes from `mode`.
    private func collectionTileMenuSections(for item: MediaItem) -> [[TileMenuAction]] {
        guard case .library(let key, _) = mode,
              !item.ref.itemID.isEmpty,
              let libraryUUID = dataStore.libraries.first(where: { $0.key == key })?.uuid
        else { return [] }
        let pin = HomeCollectionPins.Pin(ratingKey: item.ref.itemID, libraryUUID: libraryUUID, title: item.title)
        // Home: only when the library has a Home block and Plex does not
        // already promote this collection there.
        let homeAction = Self.collectionPinAction(
            isLibraryPinned: dataStore.librariesPinnedToHome.contains { $0.key == key },
            promotedChildrenKeys: dataStore.promotedHubKeys(forLibraryKey: key),
            childrenKey: pin.childrenKey,
            isPinned: HomeCollectionPins.isPinned(ratingKey: pin.ratingKey, libraryUUID: libraryUUID))
        // Library: always has a page to draw on; skipped when Plex already
        // shows this collection as a hub here.
        let libraryAction = Self.collectionPinAction(
            isLibraryPinned: true,
            promotedChildrenKeys: Set((dataStore.libraryHubs[key] ?? []).compactMap(\.key)),
            childrenKey: pin.childrenKey,
            isPinned: HomeCollectionPins.isPinned(ratingKey: pin.ratingKey, libraryUUID: libraryUUID, in: .library))

        func action(_ pinAction: PinAction?, _ destination: HomeCollectionPins.Destination,
                    _ name: String) -> TileMenuAction? {
            switch pinAction {
            case .pin:
                return TileMenuAction(title: "Pin to \(name)", systemImage: "pin") {
                    HomeCollectionPins.pin(pin, in: destination)
                }
            case .unpin:
                return TileMenuAction(title: "Unpin from \(name)", systemImage: "pin.slash", destructive: true) {
                    HomeCollectionPins.unpin(ratingKey: pin.ratingKey, libraryUUID: pin.libraryUUID, in: destination)
                }
            case nil:
                return nil
            }
        }
        let actions = [action(homeAction, .home, "Home"), action(libraryAction, .library, "Library")].compactMap { $0 }
        return actions.isEmpty ? [] : [actions]
    }

    /// Add to Playlist on a title tile; nil where the tile's server has no playlists.
    private func addToPlaylistAction(for item: MediaItem, tileFrame: CGRect?) -> TileMenuAction? {
        guard PlaylistMenus.canAdd(item, provider: MediaProviderRegistry.shared.provider(for: item.ref.providerID))
        else { return nil }
        return TileMenuAction(title: "Add to Playlist", systemImage: "text.badge.plus") { [weak self] in
            guard let self else { return }
            PlaylistMenus.presentAddToPlaylist(for: item, from: self, sourceFrame: tileFrame)
        }
    }

    /// A tile on the playlists grid: Play and Shuffle, then Rename (regular only) and Delete.
    private func playlistTileMenuSections(for item: MediaItem) -> [[TileMenuAction]] {
        guard let playlist = listedPlaylist(for: item) else { return [] }
        let actions = PlaylistMenus.playlistTileActions(isSmart: playlist.isSmart).map { action in
            switch action {
            case .play:
                TileMenuAction(title: "Play", systemImage: "play") { [weak self] in
                    self?.playPlaylist(playlist, shuffled: false)
                }
            case .shuffle:
                TileMenuAction(title: "Shuffle", systemImage: "shuffle") { [weak self] in
                    self?.playPlaylist(playlist, shuffled: true)
                }
            case .rename:
                TileMenuAction(title: "Rename", systemImage: "pencil") { [weak self] in
                    guard let self else { return }
                    PlaylistMenus.presentRename(playlist, from: self)
                }
            case .delete:
                TileMenuAction(title: "Delete", systemImage: "trash", destructive: true) { [weak self] in
                    guard let self else { return }
                    PlaylistMenus.confirmDelete(playlist, from: self)
                }
            }
        }
        return [Array(actions.prefix(2)), Array(actions.dropFirst(2))]
    }

    private func playPlaylist(_ playlist: MediaPlaylist, shuffled: Bool) {
        guard let provider = MediaProviderRegistry.shared.provider(for: playlist.item.ref.providerID) else { return }
        Task { @MainActor [weak self] in
            do {
                let entries = try await provider.playlistEntries(playlist.item.ref)
                self?.startPlaylist(entries, at: 0, shuffled: shuffled, title: playlist.item.title)
            } catch {
                guard let self else { return }
                PlaylistMenus.reportFailure(error, from: self)
            }
        }
    }

    /// The playlist page's entry rows, by grid position: a title can be in the list twice.
    private func playlistEntryActions(at index: Int, item: MediaItem) -> [TileMenuAction]? {
        guard case .playlist(let playlist) = mode, playlistEntries[safe: index]?.item.ref == item.ref else { return nil }
        return PlaylistMenus.entryActions(isSmart: playlist.isSmart).compactMap { action in
            switch action {
            case .playFromHere:
                TileMenuAction(title: "Play from Here", systemImage: "play") { [weak self] in
                    guard let self, playlistEntries[safe: index]?.item.ref == item.ref,
                          let queue = PlaylistMenus.playFromHereQueue(playlistEntries, at: index) else { return }
                    playQueue(queue)
                }
            case .move:
                TileMenuAction(title: "Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                    [weak self] in self?.beginEntryMove(at: index, item: item)
                }
            case .remove:
                TileMenuAction(title: "Remove from Playlist", systemImage: "minus.circle", destructive: true) {
                    [weak self] in self?.removePlaylistEntry(at: index, item: item, from: playlist)
                }
            }
        }
    }

    /// Optimistic: the tile goes at once. A refusal puts it back where it was and says why.
    private func removePlaylistEntry(at index: Int, item: MediaItem, from playlist: MediaPlaylist) {
        // The list can have reloaded since the menu opened: act only on the tile it was opened on.
        guard playlistEntries[safe: index]?.item.ref == item.ref,
              let provider = MediaProviderRegistry.shared.provider(for: playlist.item.ref.providerID) else { return }
        var remaining = playlistEntries
        let removed = remaining.remove(at: index)
        // A page-0 fetch already in flight holds the old list: the new generation discards it.
        gridGeneration += 1
        gridPagesRequested = [0]
        showPlaylistEntries(remaining)
        let generation = gridGeneration
        Task { @MainActor [weak self] in
            do {
                try await provider.removeFromPlaylist(playlist.item.ref, entryID: removed.entryID)
                // The refresh reloads the entries: Jellyfin drops every copy of a duplicate.
                NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            } catch {
                guard let self else { return }
                if gridGeneration == generation {
                    var restored = playlistEntries
                    restored.insert(removed, at: min(index, restored.count))
                    showPlaylistEntries(restored)
                } else {
                    reloadLoadedGridPages()
                }
                PlaylistMenus.reportFailure(error, from: self)
            }
        }
    }

    private func installEntryMove() {
        entryMove = GrabReorderController(
            view: collectionView, axis: .grid(columns: MediaRowMetrics.posterFullCount),
            count: { [weak self] in self?.playlistEntries.count ?? 0 },
            canMove: { _, _ in true },
            onStep: { [weak self] from, to in
                guard let self else { return }
                var entries = playlistEntries
                entries.insert(entries.remove(at: from), at: to)
                showPlaylistEntries(entries)
                // Slots are positional: the held entry is now in another cell, so focus follows it.
                pendingGridFocusItem = to
                focusPendingGridSlot()
                updateEntryMoveWiggle()
            },
            onDrop: { [weak self] original, final in self?.finishEntryMove(from: original, to: final) },
            onCancel: { [weak self] original in
                guard let self else { return }
                showPlaylistEntries(entriesBeforeMove)
                pendingGridFocusItem = original
                focusPendingGridSlot()
                updateEntryMoveWiggle()
                reloadIfHeldDuringMove()
            })
    }

    /// Move from the tile menu: that tile wiggles and the arrows carry it until Select or Menu.
    private func beginEntryMove(at index: Int, item: MediaItem) {
        guard let entryMove, !entryMove.isMoving, playlistEntries[safe: index]?.item.ref == item.ref else { return }
        entriesBeforeMove = playlistEntries
        // A load landing mid-move would reorder the grid under the held tile: drop it, reload after.
        gridGeneration += 1
        refreshAfterMove = true
        entryMove.begin(at: index)
        pendingGridFocusItem = index
        focusPendingGridSlot()
        updateEntryMoveWiggle()
    }

    /// A real drop posts its own refresh; a cancel or a no-op drop runs the one held back.
    private func reloadIfHeldDuringMove() {
        guard refreshAfterMove else { return }
        refreshAfterMove = false
        reloadLoadedGridPages()
    }

    private func updateEntryMoveWiggle() {
        guard let grid = gridSectionIndex else { return }
        let held = entryMove?.isMoving == true ? entryMove?.index : nil
        for path in collectionView.indexPathsForVisibleItems where path.section == grid {
            collectionView.cellForItem(at: path)?.contentView.setReorderWiggle(path.item == held)
        }
    }

    /// One move call on drop. The grid already shows the new order; a refusal puts the old one back.
    private func finishEntryMove(from original: Int, to final: Int) {
        updateEntryMoveWiggle()
        let before = entriesBeforeMove
        guard original != final, case .playlist(let playlist) = mode, let moved = before[safe: original],
              let provider = MediaProviderRegistry.shared.provider(for: playlist.item.ref.providerID) else {
            reloadIfHeldDuringMove()
            return
        }
        // A refresh held during the move still runs if the move fails.
        let heldRefresh = refreshAfterMove
        refreshAfterMove = false
        // A page-0 fetch already in flight holds the old order: the new generation discards it.
        gridGeneration += 1
        gridPagesRequested = [0]
        let generation = gridGeneration
        Task { @MainActor [weak self] in
            do {
                try await provider.movePlaylistEntry(playlist.item.ref, entryID: moved.entryID,
                                                     toIndex: final, in: before)
                NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            } catch {
                guard let self else { return }
                if gridGeneration == generation {
                    showPlaylistEntries(before)
                    if heldRefresh { reloadLoadedGridPages() }
                } else {
                    reloadLoadedGridPages()
                }
                PlaylistMenus.reportFailure(error, from: self)
            }
        }
    }

    /// Puts edited entries on the playlist page in place; slot ids are positional, so reconfigure.
    private func showPlaylistEntries(_ entries: [PlaylistEntry]) {
        playlistEntries = entries
        gridItems = entries.map(\.item)
        totalGridCount = entries.count
        applySnapshot(animated: false)
        reconfigureGridSlots(0..<gridItems.count)
        updateHomeState()
    }

    /// Episode-only, in the menu's first group. Go to Episode opens its season's
    /// page with the episode focused. Go to Show opens the show's own page,
    /// whose Watched button marks the whole show.
    private func goToEntries(for item: MediaItem) -> [TileMenuAction] {
        guard item.kind == .episode, item.grandparentRef?.itemID.isEmpty == false else { return [] }
        return [
            TileMenuAction(title: "Go to Episode", systemImage: "list.and.film") { [weak self] in
                self?.goToEpisode(item)
            },
            TileMenuAction(title: "Go to Show", systemImage: "tv") { [weak self] in
                self?.openShowDetail(of: item)
            },
        ]
    }

    /// The season page on the episode; the show page keyed to it when the season can't be read.
    private func goToEpisode(_ episode: MediaItem) {
        SeasonDetailViewController.open(focusing: episode, from: self) { [weak self] in
            self?.presentStandaloneExpandedDetail(episode)
        }
    }

    private func openShowDetail(of episode: MediaItem) {
        guard let showRef = episode.grandparentRef else { return }
        PreviewCarouselViewController.openShowDetail(showRef, from: self)
    }

    /// A merged Continue Watching card's menu: Mark as Watched and Remove reach
    /// every server's copy (#87), or the copy left behind brings the card back.
    private func tileMenuSections(for item: MediaItem,
                                  isContinueWatching: Bool,
                                  shelfLocation: (sectionID: HomeSectionID, itemIndex: Int)? = nil) -> [[TileMenuAction]] {
        let sections = singleServerTileMenuSections(for: item, isContinueWatching: isContinueWatching,
                                                    shelfLocation: shelfLocation)
        guard isContinueWatching, let others = mergedCWOthers[item.ref] else { return sections }
        return sections.map { group in
            group.map { action in
                switch action.title {
                case "Mark as Watched":
                    return TileMenuAction(title: action.title, systemImage: action.systemImage,
                                          destructive: action.destructive) {
                        action.handler()
                        Self.changeOnServer {
                            for copy in others {
                                try? await MediaProviderRegistry.shared.provider(for: copy.ref.providerID)?.markPlayed(copy.ref)
                            }
                        }
                    }
                case "Remove from Continue Watching":
                    return TileMenuAction(title: action.title, systemImage: action.systemImage,
                                          destructive: action.destructive) {
                        action.handler()
                        Self.changeOnServer { for copy in others { await Self.removeFromContinueWatching(copy) } }
                    }
                default:
                    return action
                }
            }
        }
    }

    /// Takes one server's copy out of its Continue Watching: Plex's own removal,
    /// elsewhere a cleared position (an episode moves to Next Up, so it stays).
    private static func removeFromContinueWatching(_ copy: MediaItem) async {
        let provider = MediaProviderRegistry.shared.provider(for: copy.ref.providerID)
        if let plex = provider as? PlexProvider {
            try? await PlexNetworkManager.shared.removeFromContinueWatching(
                serverURL: plex.serverURL, authToken: plex.authToken, ratingKey: copy.ref.itemID)
        } else if provider is SiloProvider {
            guard let dismissal = copy.dismissalAction() else { return }
            try? await provider?.dismiss(dismissal)
        } else if copy.kind != .episode {
            try? await provider?.updateProgress(copy.ref, position: 0)
        }
    }

    /// The canonical long-press menu for home rows and the library grid, one sub-array per divider group.
    /// CW rows swap the watched group for Remove from CW and Go to Show.
    private func singleServerTileMenuSections(for item: MediaItem,
                                              isContinueWatching: Bool,
                                              shelfLocation: (sectionID: HomeSectionID, itemIndex: Int)? = nil)
        -> [[TileMenuAction]] {
        // A collection opens its page on Select and has nothing to play or
        // mark. In a library its menu is Pin to Home or Unpin from Home.
        if item.kind == .collection { return collectionTileMenuSections(for: item) }
        if item.kind == .playlist { return playlistTileMenuSections(for: item) }
        // Read now: the frame is gone once the menu covers the tile.
        let tileFrame = focusedTileFrame()
        if !item.ref.isPlex {
            guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return [] }
            return Self.providerTileMenuSections(
                for: item, provider: provider, isContinueWatching: isContinueWatching,
                onWatchFromBeginning: { [weak self] in self?.playItem(item, fromBeginning: true) },
                onMoreInfo: { [weak self] in self?.selectMediaItem(item) },
                onGoToEpisode: { [weak self] in self?.goToEpisode(item) },
                onGoToShow: { [weak self] in self?.openShowDetail(of: item) },
                onPlayVersion: { [weak self] in self?.presentVersionPicker(for: item, from: tileFrame) },
                onAddToPlaylist: { [weak self] in
                    guard let self else { return }
                    PlaylistMenus.presentAddToPlaylist(for: item, from: self, sourceFrame: tileFrame)
                })
        }
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              !item.ref.itemID.isEmpty
        else { return [] }
        let ratingKey = item.ref.itemID

        let network = PlexNetworkManager.shared

        if isContinueWatching {
            // Same segmentation as the generic menu below: [Watch from
            // Beginning, More Info, Go to Episode,
            // Go to Show] | [watched state] |
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
            cwFirst += goToEntries(for: item)
            cwFirst += [addToPlaylistAction(for: item, tileFrame: tileFrame)].compactMap { $0 }
            if let version = Self.playVersionAction(for: item, handler: { [weak self] in
                self?.presentVersionPicker(for: item, from: tileFrame)
            }) {
                cwFirst.insert(version, at: 1)
            }

            let cwMiddle = [
                TileMenuAction(title: "Mark as Watched",
                               systemImage: "eye.fill") {
                    Self.changeOnServer {
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
                    Self.changeOnServer {
                        try await network.refreshMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                    }
                },
            ]

            return [cwFirst, cwMiddle, cwLast]
        }

        // Generic media-item menu (Recently Added, Recommendations):
        // [Watch from Beginning, More Info, Go to Episode, Go to Show] | [watched state] |
        // [Refresh Metadata].

        // Watch from Beginning starts playback at 0:00.
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

        first += goToEntries(for: item)
        first += [addToPlaylistAction(for: item, tileFrame: tileFrame)].compactMap { $0 }
        if let version = Self.playVersionAction(for: item, handler: { [weak self] in
            self?.presentVersionPicker(for: item, from: tileFrame)
        }) {
            first.insert(version, at: 1)
        }

        // Mark as Watched / Unwatched — conditional on view state.
        // isWatched mirrors the old `viewCount > 0`; watchProgress != nil
        // mirrors the in-progress branch.
        var middle: [TileMenuAction] = []
        let isWatched = item.isWatched
        if !isWatched || item.watchProgress != nil {
            middle.append(TileMenuAction(title: "Mark as Watched",
                                         systemImage: "eye.fill") {
                Self.changeOnServer {
                    try await network.markWatched(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            })
        }
        if isWatched {
            middle.append(TileMenuAction(title: "Mark as Unwatched",
                                         systemImage: "eye.slash.fill") {
                Self.changeOnServer {
                    try await network.markUnwatched(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            })
        }

        let last = [
            TileMenuAction(title: "Refresh Metadata",
                           systemImage: "arrow.clockwise") {
                Self.changeOnServer {
                    try await network.refreshMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
                }
            },
        ]

        return [first, middle, last]
    }

    /// "Play Version" for a movie or episode with more than one file.
    static func playVersionAction(for item: MediaItem, handler: (() -> Void)?) -> TileMenuAction? {
        guard let handler, (item.versionCount ?? 0) >= 2, item.kind == .movie || item.kind == .episode else {
            return nil
        }
        return TileMenuAction(title: "Play Version", systemImage: "square.stack", handler: handler)
    }

    /// Tile menu "Play Version": fetch the versions, then play the pick.
    private func presentVersionPicker(for item: MediaItem, from tileFrame: CGRect?) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
        Task { @MainActor [weak self] in
            guard let self, let detail = try? await provider.fullDetail(for: item.ref) else { return }
            VersionPicker.present(VersionPicker.versions(in: detail), from: self, sourceFrame: tileFrame) {
                [weak self] sourceID in self?.playItem(item, sourceID: sourceID)
            }
        }
    }

    /// The Plex tile menu for an item on another server: same entries and
    /// groups, every server call through the item's provider.
    /// [Watch from Beginning, More Info, Go to Episode, Go to Show] | [watched state,
    /// Remove from Continue Watching] | [Refresh Metadata].
    /// Remove is offered only where the server can do it: clearing an
    /// episode's position moves it to Next Up, still in Continue Watching.
    static func providerTileMenuSections(
        for item: MediaItem,
        provider: any MediaProvider,
        isContinueWatching: Bool,
        onWatchFromBeginning: @escaping () -> Void,
        onMoreInfo: @escaping () -> Void,
        onGoToEpisode: (() -> Void)? = nil,
        onGoToShow: (() -> Void)? = nil,
        onPlayVersion: (() -> Void)? = nil,
        onAddToPlaylist: (() -> Void)? = nil
    ) -> [[TileMenuAction]] {
        // Person identities are not catalog title IDs; even an unexpected caller
        // must not offer playback or send watched/watchlist/favorite mutations.
        guard item.kind != .person else { return [] }
        var savedActions: [TileMenuAction] = []
        if provider.supportsWatchlist {
            savedActions.append(TileMenuAction(title: "Toggle Watchlist", systemImage: "bookmark") {
                changeOnServer {
                    if await provider.isOnWatchlist(item.ref) { try await provider.removeFromWatchlist(item.ref) }
                    else { try await provider.addToWatchlist(item.ref) }
                }
            })
        }
        if provider.supportsFavorites, item.isAvailable != false {
            savedActions.append(TileMenuAction(title: "Toggle Favorite", systemImage: "heart") {
                changeOnServer {
                    let favorite = await provider.isFavorite(item.ref)
                    try await provider.setFavorite(item.ref, isFavorite: !favorite)
                }
            })
        }
        if item.isAvailable == false {
            return [[TileMenuAction(title: "More Info", systemImage: "info.circle", handler: onMoreInfo)], savedActions]
                .filter { !$0.isEmpty }
        }
        var first = [
            TileMenuAction(title: "Watch from Beginning", systemImage: "arrow.counterclockwise",
                           handler: onWatchFromBeginning),
            TileMenuAction(title: "More Info", systemImage: "info.circle", handler: onMoreInfo)
        ]
        if let version = playVersionAction(for: item, handler: onPlayVersion) { first.insert(version, at: 1) }
        // Unwired on the show's own page, where both lead back to it.
        if item.kind == .episode, item.grandparentRef?.itemID.isEmpty == false,
           let onGoToEpisode, let onGoToShow {
            first.append(TileMenuAction(title: "Go to Episode", systemImage: "list.and.film", handler: onGoToEpisode))
            first.append(TileMenuAction(title: "Go to Show", systemImage: "tv", handler: onGoToShow))
        }
        if let onAddToPlaylist, PlaylistMenus.canAdd(item, provider: provider) {
            first.append(TileMenuAction(title: "Add to Playlist", systemImage: "text.badge.plus",
                                        handler: onAddToPlaylist))
        }
        let ref = item.ref
        var middle: [TileMenuAction] = []
        if !item.isWatched || item.watchProgress != nil {
            middle.append(TileMenuAction(title: "Mark as Watched", systemImage: "eye.fill") {
                changeOnServer { try await provider.markPlayed(ref) }
            })
        }
        if item.isWatched {
            middle.append(TileMenuAction(title: "Mark as Unwatched", systemImage: "eye.slash.fill") {
                changeOnServer { try await provider.markUnplayed(ref) }
            })
        }
        if provider is SiloProvider {
            if let dismissal = item.dismissalAction() {
                let title = dismissal.rail == .nextUp ? "Remove from Next Up" : "Remove from Continue Watching"
                middle.append(TileMenuAction(title: title, systemImage: "trash", destructive: true) {
                    changeOnServer { try await provider.dismiss(dismissal) }
                })
            }
        } else if isContinueWatching, item.kind != .episode {
            middle.append(TileMenuAction(title: "Remove from Continue Watching", systemImage: "trash", destructive: true) {
                changeOnServer { try await provider.updateProgress(ref, position: 0) }
            })
        }
        let last = [TileMenuAction(title: "Refresh Metadata", systemImage: "arrow.clockwise") {
            changeOnServer { try await provider.refreshMetadata(ref) }
        }]
        return [first, savedActions, middle, last].filter { !$0.isEmpty }
    }

    /// Posts `.plexDataNeedsRefresh` after the server call, failed or not, so
    /// every surface repaints from server truth (CLAUDE.md "Watch State").
    private static func changeOnServer(_ change: @escaping () async throws -> Void) {
        Task { @MainActor in
            try? await change()
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
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
        if let row = nativeRows[sectionID] {
            await loadNativeHubPage(row, sectionID: sectionID)
            return
        }
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
                // Map the page to MediaItem, then dedupe by ref.itemID (the ratingKey).
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
            // No hasReachedEnd on error, so scrolling on retries.
            var freshState = paginationStates[sectionID] ?? state
            freshState.isLoadingMore = false
            paginationStates[sectionID] = freshState
            applySnapshot(animated: false)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        let shelfTop = Self.heroBackdropFloor
        backdropView.applyScrollOffset(offset, shelfTop: shelfTop)
        let showcase = HeroBackdropView.showcasePercentage(offset, shelfTop: shelfTop)
        for case let heroCell as HeroOverlayCell in collectionView.visibleCells {
            heroCell.overlay.applyShowcase(showcase)
        }
    }

    /// Centres the focused row vertically as focus moves.
    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        // The engine acts on an arrow BEFORE the press reaches the responder
        // chain, so by the time a press hand-off runs, any move it made has
        // already happened here. Recording it is the only way that hand-off can
        // tell "the engine moved me up a row" from "the engine declined and I
        // have not moved at all" — the two look identical from the press.
        if context.nextFocusedView !== context.previouslyFocusedView {
            engineMovedFocus = true
        }
        // Resolve the section that owns the newly-focused view.
        guard let nextSectionIndex = focusedSectionIndex(in: context) else {
            // The alphabet bar counts as the grid for chrome purposes: the
            // page stays below-top and the bar stays up while focus walks
            // its letters.
            if context.nextFocusedView?.isDescendant(of: alphabetBar) == true {
                // The collection's remembered path names the tile from before
                // the jump, off-screen now; armed, it makes Left off the strip
                // find nothing to enter and fall through to the sidebar. Off
                // while on the strip, back on once the grid has focus again.
                collectionView.remembersLastFocusedIndexPath = false
                scheduleStripIdleReturn()
                return
            }
            // tvOS's fast-scroll index bar: the one focusable thing inside
            // the collection that is not in a cell. Fast mode begins.
            if let next = context.nextFocusedView, next.isDescendant(of: collectionView),
               !sequence(first: next, next: { $0.superview }).contains(where: { $0 is UICollectionViewCell }) {
                isOnSystemIndexBar = true
                offsetLink?.invalidate()
                offsetLink = nil
                setAlphabetBarVisible(false)
                if heldArrow != nil { startFastScroll() }
                return
            }
            isOnSystemIndexBar = false
            stopFastScroll()
            stripIdleWork?.cancel()
            setAlphabetBarVisible(false)
            updateLeftEdgeGuide(for: nil)
            // Focus left the page (sidebar, modal). Chrome must be back
            // before the sidebar can be interacted with.
            postFocusBelowTop(false)
            // ...unless focus is inside the page and only the section lookup failed (a tile in a shelf row's
            // nested collection). Nothing else scrolls for us, so reveal it from its own frame.
            if let next = context.nextFocusedView, next.isDescendant(of: collectionView) {
                revealFocusedView(next)
            }
            return
        }
        postFocusBelowTop(nextSectionIndex > topSectionIndex)
        isOnSystemIndexBar = false
        stopFastScroll()
        // Kept AFTER focus leaves the page, so a press hand-off can still say
        // which row it came from. `focusedSectionForHandoff` is nil by then.
        lastFocusedSection = nextSectionIndex
        let kind: HomeSectionKind? = sectionsSnapshot.indices.contains(nextSectionIndex)
            ? sectionsSnapshot[nextSectionIndex].kind
            : nil
        // The Menu-back landed; stop routing focus to the top. A directional move clears it too, or the flag
        // could latch and yank focus on a later update. Armed only from inside the collection.
        if wantsTopFocus, nextSectionIndex == topSectionIndex || !context.focusHeading.isEmpty {
            wantsTopFocus = false
        }
        // Initial-hero routing ends once the hero has focus or the user moves within the page. Entries from
        // the sidebar don't count: on Discover they arrive before the hero exists.
        if needsInitialHeroFocus {
            let prevInside = context.previouslyFocusedView?.isDescendant(of: collectionView) == true
            // The loading placeholder parks focus but must not consume the
            // initial-hero routing — the real hero still needs it to land on
            // Play when content arrives.
            let heroHasContent = kind == .hero &&
                (!sectionsSnapshot[nextSectionIndex].heroItems.isEmpty || !sectionsSnapshot[nextSectionIndex].heroMediaItems.isEmpty)
            if heroHasContent || (prevInside && !context.focusHeading.isEmpty) {
                needsInitialHeroFocus = false
            }
        }
        setAlphabetBarVisible(kind == .grid)
        switch kind {
        case .hero:
            scrollHeroIntoView(sectionID: sectionsSnapshot[nextSectionIndex].id)
        case .grid:
            // Focus is in the grid, so any letter jump has been consumed.
            pendingGridFocusItem = nil
            stripIdleWork?.cancel()
            collectionView.remembersLastFocusedIndexPath = true
            if let slot = context.nextFocusedIndexPath?.item {
                alphabetBar.entryIndex = alphabetIndex?.entryIndex(containing: slot)
            }
            // Multi-row grid: centring the SECTION (its first item) would
            // pin the viewport to the grid's top — centre the focused
            // cell's own row instead. Grid cells are NOT orthogonal, so
            // `nextFocusedIndexPath` resolves at the collection level.
            if let indexPath = context.nextFocusedIndexPath {
                scrollGridCellIntoView(at: indexPath)
            }
        case .watchlistGrid:
            // Same multi-row reason as the library grid, none of its A–Z or
            // letter-jump bookkeeping. Falling through to `default` centred the
            // section's FIRST item, which pinned the page on row 1.
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
            scrollSectionToRest(sectionIndex: nextSectionIndex)
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
        case .continueWatching, .recentlyAdded, .watchlist, .watchlistGrid, .recommendations,
             .grid, .discoverList, .searchGrid:
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
        // Point the guide at the previous cell if it is on screen. Do not scroll the row to bring it in:
        // this runs on every focus update and keeps re-centering the row. Otherwise `shouldUpdateFocusIn`
        // handles the Left.
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
        // `nextFocusedIndexPath` is nil for the hero (its buttons live in a subview) and for shelf-row
        // tiles, so read the section from the focused view's enclosing cell. Without it, Up and Down
        // between rows would fail to centre, since nothing else scrolls the page.
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
    /// A Menu press below the top row snaps the page back to it. At the top row this declines, so the
    /// system reveals the sidebar, and `TVSidebarView.onExitCommand` returns to Home from there.
    func handleMenuBack() -> Bool {
        // Collection page mid blur-fade: asked before the library under it,
        // whose tile may still hold focus. Drop the press. Before the window
        // guard, because the page's view may not be in the window yet.
        if isDrillInPage, !hasMarkedFirstFrame { return true }
        guard isViewLoaded, let window = view.window, window.isKeyWindow else { return false }
        // Move mode: Menu puts the order back, but only while the held tile has focus.
        if let entryMove, entryMove.isMoving {
            guard let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
                  focused.isDescendant(of: collectionView) else { return false }
            entryMove.cancel()
            return true
        }
        // From the A–Z strip or the (hidden) fast-scroll bar, Menu goes back
        // to a tile, never out to the sidebar.
        if let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView {
            if focused.isDescendant(of: alphabetBar) {
                leaveStrip()
                return true
            }
            if isOnSystemIndexBar {
                landFocusOnCenterTile()
                return true
            }
        }
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

    /// Animates the page to its top on the shared focus-scroll curve, for the Search hand-off: it plays
    /// alongside the keyboard expanding. Safe to animate because focus is leaving the collection.
    func animateToContentTop() {
        let top = -collectionView.adjustedContentInset.top
        guard abs(collectionView.contentOffset.y - top) > 1 else { return }
        animateContentOffset(toY: top)
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

    /// Scrolls to the top row and marks it the preferred focus target without requesting an update, for
    /// a requester that contains focus (`SearchContainerViewController`).
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

    /// Snaps to the top row and focuses it. The jump is deliberate: animating loses to the engine, which
    /// re-resolves mid-flight onto a passing row. `playReturnToTopSlide` draws the visible scroll after.
    private func returnToTopRow() {
        let travel = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let before = collectionView.snapshotView(afterScreenUpdates: false)
        aimFocusAtTopRow()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        playReturnToTopSlide(from: before, travel: travel)
        // The hero's buttons may not be focusable until the next runloop turn; re-assert once they are.
        DispatchQueue.main.async { [weak self] in
            self?.nudgeInitialHeroFocusIfNeeded()
        }
    }

    /// Draws the trip back up as a quick scroll. The page has already jumped
    /// and focus has landed; this only slides the old picture down and the top
    /// in after it, on presentation layers, so neither layout nor focus moves.
    private func playReturnToTopSlide(from snapshot: UIView?, travel: CGFloat) {
        let distance = min(travel, collectionView.bounds.height)
        guard let snapshot, distance > 1, !UIAccessibility.isReduceMotionEnabled else { return }
        snapshot.frame = collectionView.frame
        view.insertSubview(snapshot, aboveSubview: collectionView)
        CATransaction.begin()
        // The snapshot can sit over the hero's buttons, which blocks focus
        // geometrically, so the hero nudge runs again once it is gone.
        CATransaction.setCompletionBlock { [weak self] in
            snapshot.removeFromSuperview()
            self?.nudgeInitialHeroFocusIfNeeded()
        }
        for (layer, from, to) in [(collectionView.layer, -distance, 0), (snapshot.layer, 0, distance)] {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = from
            slide.toValue = to
            slide.duration = 0.35
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)  // ease-out cubic
            layer.add(slide, forKey: "returnToTop")
        }
        snapshot.layer.transform = CATransform3DMakeTranslation(0, distance, 0)
        CATransaction.commit()
    }
}
