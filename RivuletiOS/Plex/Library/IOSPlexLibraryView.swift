// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// What the Library tab's list has selected; the split view shows it beside the list,
/// or pushes it at compact width.
enum IOSLibrarySelection: Hashable {
    case downloads
    case favorites
    case library(MediaLibrary)
    case playlists(providerID: String)
}

/// Library tab: the list as a split view's sidebar, so a regular-width iPhone (iPhone Duo
/// open, Plus and Max in landscape) shows it beside the library. Compact collapses to a stack.
struct IOSPlexLibrarySplitView: View {
    @Binding var selection: IOSLibrarySelection?
    @Binding var column: NavigationSplitViewColumn
    @Binding var path: NavigationPath
    @EnvironmentObject private var browse: IOSBrowseStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            // A pick in the list starts the detail column over. A selection set from outside
            // (the sidebar's library tab folding in at compact width) keeps its pushed pages.
            IOSPlexLibrariesView(selection: Binding(get: { selection }, set: { picked in
                if picked != selection { path = NavigationPath() }
                selection = picked
            }))
        } detail: {
            NavigationStack(path: $path) {
                // A new selection is a new page: library grids keep their items in view state.
                detail.id(selection).iosPlexDestinations()
            }
        }
        // Side by side, the detail column is never left empty.
        .onChange(of: [sizeClass == .regular, browse.libraries.isEmpty], initial: true) {
            if sizeClass == .regular, selection == nil, let first = browse.libraries.first {
                selection = .library(first)
            }
        }
        // Narrowed with a library beside the list: it stays in front, the list one step back.
        .onChange(of: sizeClass) { was, now in
            if was == .regular, now != .regular, selection != nil { column = .detail }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .downloads: IOSDownloadsView()
        case .favorites: IOSFavoritesView()
        case .library(let library): IOSPlexLibraryView(library: library)
        case .playlists(let providerID): IOSPlexPlaylistsView(providerID: providerID)
        case nil: ContentUnavailableView("Choose a Library", systemImage: "rectangle.stack")
        }
    }
}

/// The Library tab's list: Downloads, then the server's movie and TV libraries.
/// Downloads stays reachable signed out or with the server unreachable.
struct IOSPlexLibrariesView: View {
    @Binding var selection: IOSLibrarySelection?
    @EnvironmentObject private var browse: IOSBrowseStore
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @AppStorage(IOSLibrarySettingsView.showPlaylistsKey) private var showPlaylists = true
    @AppStorage("showFavoritesTab") private var showFavorites = false

    var body: some View {
        Group {
            if !browse.hasServers, downloads.visibleRecords.isEmpty {
                IOSPlexConnectView()
            } else {
                List(selection: $selection) {
                    Section {
                        NavigationLink(value: IOSLibrarySelection.downloads) {
                            Label("Downloads", systemImage: "arrow.down.circle")
                        }
                        // The tvOS sidebar's Favorites page, off until Account > Home turns it on.
                        if showFavorites, browse.offersFavorites {
                            NavigationLink(value: IOSLibrarySelection.favorites) {
                                Label("Favorites", systemImage: "heart")
                            }
                        }
                    }
                    if !browse.hasServers {
                        IOSPlexConnectView().listRowBackground(Color.clear)
                    } else if videoLibraries.isEmpty {
                        status.frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    } else {
                        // One section per server, under its name once there are several.
                        ForEach(serverGroups, id: \.id) { group in
                            Section(group.name ?? "") {
                                ForEach(group.libraries) { library in
                                    NavigationLink(value: IOSLibrarySelection.library(library)) {
                                        Label(library.title, systemImage: library.icon)
                                    }
                                }
                                if showPlaylists, !browse.playlists(providerID: group.providerID).isEmpty {
                                    NavigationLink(value: IOSLibrarySelection.playlists(providerID: group.providerID)) {
                                        Label("Playlists", systemImage: "list.and.film")
                                    }
                                }
                            }
                        }
                        // A server that failed is named in its own section; the others still list.
                        ForEach(browse.failedServers) { failure in
                            Section { IOSServerFailureBanner(failure: failure).listRowInsets(EdgeInsets()) }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await browse.refresh() }
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            IOSAccountToolbarItem()
        }
    }

    private var videoLibraries: [MediaLibrary] { browse.libraries }

    /// One section per server, under its name once there are several.
    private var serverGroups: [(id: String, providerID: String, name: String?, libraries: [MediaLibrary])] {
        let ids = videoLibraries.reduce(into: [String]()) { if !$0.contains($1.providerID) { $0.append($1.providerID) } }
        return ids.map { id in
            (id, id, ids.count > 1 ? browse.labels.badge(providerID: id) : nil, videoLibraries.filter { $0.providerID == id })
        }
    }

    @ViewBuilder
    private var status: some View {
        if browse.isLoadingContent {
            ProgressView().padding()
        } else if let error = browse.contentError ?? browse.failedServers.first?.message {
            IOSPlexErrorView(title: "Couldn't Load Libraries", message: error) { await browse.refresh() }
        } else {
            ContentUnavailableView("No Libraries", systemImage: "film.stack")
        }
    }
}

/// One library: Recommended (its own rows under a hero, like Home) or Browse (every title).
/// The page is remembered per library.
struct IOSPlexLibraryView: View {
    let library: MediaLibrary
    /// Only a tab root shows the avatar; a library pushed from the Library list does not.
    var showsAccount = false
    @EnvironmentObject private var browse: IOSBrowseStore
    @AppStorage private var pageRaw: String
    /// Same key as the tvOS library hero setting.
    @AppStorage("showLibraryHero") private var showHero = true
    @State private var rows: [MediaHub] = []

    enum Page: String, CaseIterable {
        case recommended, browse

        var title: String {
            switch self {
            case .recommended: String(localized: "Recommended")
            case .browse: String(localized: "Browse")
            }
        }
    }

    init(library: MediaLibrary, showsAccount: Bool = false) {
        self.library = library
        self.showsAccount = showsAccount
        _pageRaw = AppStorage(wrappedValue: Page.recommended.rawValue, "iosLibraryPage.\(library.settingKey)")
    }

    private var page: Page { Page(rawValue: pageRaw) ?? .recommended }
    private var heroItems: [MediaItem] { page == .recommended && showHero ? HomeHero.libraryItems(rows) : [] }

    var body: some View {
        let heroItems = heroItems
        Group {
            switch page {
            case .recommended: IOSPlexLibraryRecommendedView(library: library, rows: $rows, heroItems: heroItems)
            case .browse: IOSPlexLibraryBrowseView(library: library)
            }
        }
        .iosPlexHeroChrome(hero: !heroItems.isEmpty, title: browse.labels.title(library.title, providerID: library.providerID))
        .toolbar {
            // A pill beside Back naming the page; it opens the other.
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Page", selection: $pageRaw) {
                        ForEach(Page.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(page.title)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .fontWeight(.semibold)
                }
                .accessibilityLabel(Text("Page, \(page.title)"))
            }
            if showsAccount { IOSAccountToolbarItem() }
        }
    }
}

/// Recommended: the library's own rows from its server. They live in the parent,
/// so switching pages and back keeps them.
private struct IOSPlexLibraryRecommendedView: View {
    let library: MediaLibrary
    @Binding var rows: [MediaHub]
    let heroItems: [MediaItem]
    @EnvironmentObject private var browse: IOSBrowseStore
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedRevision: Int?

    var body: some View {
        Group {
            if !rows.isEmpty {
                IOSPlexHeroFeed(rows: rows, heroItems: heroItems) { await reload() }
            } else {
                ScrollView {
                    placeholder.containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await reload() }
            }
        }
        .task(id: browse.watchStateRevision) {
            guard loadedRevision != browse.watchStateRevision else { return }
            await reload()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let error {
            IOSPlexErrorView(title: "Couldn't Load Recommended", message: error, offersDownloads: true) { await reload() }
        } else if isLoading || loadedRevision == nil {
            ProgressView()
        } else {
            ContentUnavailableView("Nothing Recommended", systemImage: library.icon,
                                   description: Text("Switch to Browse to see every title."))
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let provider = browse.provider(for: library.providerID) else { throw MediaProviderError.unreachable }
            rows = try await HomeFeed.libraryRows(provider, library)
            error = nil
            loadedRevision = browse.watchStateRevision
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Browse: the whole library as a paged poster grid with Sort and Filter menus.
private struct IOSPlexLibraryBrowseView: View {
    let library: MediaLibrary
    @EnvironmentObject private var browse: IOSBrowseStore
    @Environment(\.plexActions) private var actions
    @AppStorage private var sortRaw: String
    @State private var unwatchedOnly = false
    /// Every item's place, filled page by page as the grid scrolls, so the
    /// scroll length is the library's from the first page.
    @State private var slots = PagedSlots<MediaItem>(pageSize: Self.pageSize)
    @State private var error: String?
    /// Query and watch-state revision the grid holds, so a reappearing view
    /// keeps its data and scroll position instead of reloading.
    @State private var loadedQuery: String?
    @State private var loadedRevision: Int?
    @State private var isFetchingFirstPage = false

    private static let pageSize = 90
    private static let sorts: [(LibrarySortOption, String)] = [
        (.titleAsc, String(localized: "Title")),
        (.addedAtDesc, String(localized: "Date Added")),
        (.releaseDateDesc, String(localized: "Release Date")),
        (.ratingDesc, String(localized: "Rating"))
    ]

    init(library: MediaLibrary) {
        self.library = library
        _sortRaw = AppStorage(wrappedValue: LibrarySortOption.titleAsc.rawValue, "iosLibrarySort.\(library.settingKey)")
    }

    /// The sorts the library page offers, in its order: all of them on Plex, else what the server can apply.
    private var sorts: [(LibrarySortOption, String)] {
        let provider = browse.provider(for: library.providerID)
        let offered = IOSLibrarySorts.menu(
            offered: provider?.sortOptions(for: library.kind) ?? LibrarySortOption.expressible(for: library.kind),
            isPlex: provider?.kind == .plex)
        return Self.sorts.filter { offered.contains($0.0) }
    }

    private var sort: LibrarySortOption { LibrarySortOption(rawValue: sortRaw) ?? .titleAsc }
    private var queryKey: String { "\(sortRaw)|\(unwatchedOnly)" }

    var body: some View {
        Group {
            if slots.slots.isEmpty, let error {
                IOSPlexErrorView(title: "Couldn't Load Library", message: error, offersDownloads: true) { await restart() }
            } else if slots.slots.isEmpty, !slots.claimedPages.isEmpty, !isFetchingFirstPage {
                ScrollView {
                    ContentUnavailableView(
                        unwatchedOnly ? "Nothing Unwatched" : "No Items",
                        systemImage: library.icon
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await restart() }
            } else if slots.slots.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    IOSPlexPosterGrid(slots: slots.slots, slotAppeared: slotAppeared)
                }
                .refreshable { await refetchLoaded() }
            }
        }
        .toolbar {
            // Shuffle follows the Unwatched filter.
            if library.canShuffle {
                ToolbarItem(placement: .topBarTrailing) {
                    if actions.preparingID == IOSPlexActions.shuffleID(providerID: library.providerID, itemID: library.id) {
                        ProgressView()
                    } else {
                        Button("Shuffle", systemImage: "shuffle") { actions.shuffleLibrary(library, unwatchedOnly) }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortRaw) {
                        ForEach(sorts, id: \.0) { Text($0.1).tag($0.0.rawValue) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $unwatchedOnly) {
                        Text("All").tag(false)
                        Text("Unwatched").tag(true)
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease")
                }
                .tint(unwatchedOnly ? .accentColor : nil)
            }
        }
        .task(id: "\(queryKey)|\(browse.watchStateRevision)") {
            // Nothing claimed and nothing shown: a first page that was cancelled when the view left.
            if loadedQuery != queryKey || (slots.slots.isEmpty && slots.claimedPages.isEmpty) {
                await restart()
            } else if loadedRevision != browse.watchStateRevision {
                await refetchLoaded()
            }
        }
    }

    /// Starts the query over from an empty grid.
    private func restart() async {
        slots = PagedSlots(pageSize: Self.pageSize)
        error = nil
        loadedQuery = queryKey
        loadedRevision = browse.watchStateRevision
        isFetchingFirstPage = true
        defer { isFetchingFirstPage = false }
        slots.claim(0)
        await fetch(0)
    }

    /// Refetches every page fetched so far, in place: a watch-state change or pull to refresh.
    private func refetchLoaded() async {
        loadedRevision = browse.watchStateRevision
        for start in slots.claimedPages { await fetch(start) }
    }

    /// Fetches the page under a tile that just appeared, and the one after it
    /// once the tile is halfway into its page, so scrolling rarely meets a placeholder.
    private func slotAppeared(_ index: Int) {
        for target in [index, index + Self.pageSize / 2] where target < slots.slots.count {
            guard let start = slots.unclaimedPage(containing: target) else { continue }
            slots.claim(start)
            Task { await fetch(start) }
        }
    }

    private func fetch(_ start: Int) async {
        let query = queryKey
        do {
            guard let provider = browse.provider(for: library.providerID) else { throw MediaProviderError.unreachable }
            let page = try await provider.items(
                in: library, sort: sort.seamSort, unwatchedOnly: unwatchedOnly, page: Page(offset: start, limit: Self.pageSize)
            )
            guard query == queryKey else { return }
            slots.fill(page.items, at: start, total: page.total)
            error = nil
        } catch {
            // A newer query has its own slots; only this query's claim is released.
            guard query == queryKey else { return }
            slots.release(start)
            if !isCancellationError(error), slots.slots.isEmpty { self.error = error.localizedDescription }
        }
    }
}
