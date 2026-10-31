// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// What the Library tab's list has selected; the split view shows it beside the list,
/// or pushes it at compact width.
enum IOSLibrarySelection: Hashable {
    case downloads
    case library(PlexLibrary)
    case playlists(serverID: String?)
}

/// Library tab: the list as a split view's sidebar, so a regular-width iPhone (iPhone Duo
/// open, Plus and Max in landscape) shows it beside the library. Compact collapses to a stack.
struct IOSPlexLibrarySplitView: View {
    @Binding var selection: IOSLibrarySelection?
    @Binding var column: NavigationSplitViewColumn
    @Binding var path: NavigationPath
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            IOSPlexLibrariesView(selection: $selection)
        } detail: {
            NavigationStack(path: $path) {
                // A new selection is a new page: library grids keep their items in view state.
                detail.id(selection).iosPlexDestinations()
            }
        }
        .onChange(of: selection) { path = NavigationPath() }
        // Side by side, the detail column is never left empty.
        .onChange(of: [sizeClass == .regular, plex.libraries.isEmpty], initial: true) {
            if sizeClass == .regular, selection == nil, let first = plex.libraries.first {
                selection = .library(first)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .downloads: IOSDownloadsView()
        case .library(let library): IOSPlexLibraryView(library: library)
        case .playlists(let serverID): IOSPlexPlaylistsView(serverID: serverID)
        case nil: ContentUnavailableView("Choose a Library", systemImage: "rectangle.stack")
        }
    }
}

/// The Library tab's list: Downloads, then the server's movie and TV libraries.
/// Downloads stays reachable signed out or with the server unreachable.
struct IOSPlexLibrariesView: View {
    @Binding var selection: IOSLibrarySelection?
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @AppStorage(IOSLibrarySettingsView.showPlaylistsKey) private var showPlaylists = true

    var body: some View {
        Group {
            if !plex.isConfigured, downloads.visibleRecords.isEmpty {
                IOSPlexConnectView()
            } else {
                List(selection: $selection) {
                    Section {
                        NavigationLink(value: IOSLibrarySelection.downloads) {
                            Label("Downloads", systemImage: "arrow.down.circle")
                        }
                    }
                    if !plex.isConfigured {
                        IOSPlexConnectView().listRowBackground(Color.clear)
                    } else if plex.libraries.isEmpty {
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
                                if showPlaylists, !plex.playlists(serverID: group.serverID).isEmpty {
                                    NavigationLink(value: IOSLibrarySelection.playlists(serverID: group.serverID)) {
                                        Label("Playlists", systemImage: "list.and.film")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await plex.refresh() }
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            IOSAccountToolbarItem()
        }
    }

    private var serverGroups: [(id: String, serverID: String?, name: String?, libraries: [PlexLibrary])] {
        let names = plex.otherServerNames
        let ids = plex.libraries.reduce(into: [String?]()) { if !$0.contains($1.serverID) { $0.append($1.serverID) } }
        return ids.map { id in
            (id ?? "", id, ids.count > 1 ? id.flatMap { names[$0] } ?? plex.auth.savedServerName : nil,
             plex.libraries.filter { $0.serverID == id })
        }
    }

    @ViewBuilder
    private var status: some View {
        if plex.isLoadingContent {
            ProgressView().padding()
        } else if let error = plex.contentError {
            IOSPlexErrorView(title: "Couldn't Load Libraries", message: error) { await plex.refresh() }
        } else {
            ContentUnavailableView("No Libraries", systemImage: "film.stack")
        }
    }
}

/// One library as a paged poster grid with Sort and Filter menus.
struct IOSPlexLibraryView: View {
    let library: PlexLibrary
    /// Only a tab root shows the avatar; a grid pushed from the Library list does not.
    var showsAccount = false
    @EnvironmentObject private var plex: IOSPlexSession
    @AppStorage private var sortRaw: String
    @State private var unwatchedOnly = false
    /// Every item's place, filled page by page as the grid scrolls, so the
    /// scroll length is the library's from the first page.
    @State private var slots = PagedSlots<PlexMetadata>(pageSize: Self.pageSize)
    @State private var error: String?
    /// Query and watch-state revision the grid holds, so a reappearing view
    /// keeps its data and scroll position instead of reloading.
    @State private var loadedQuery: String?
    @State private var loadedRevision: Int?
    @State private var isFetchingFirstPage = false

    private static let pageSize = 90
    private static let sorts: [(LibrarySortOption, String)] = [
        (.titleAsc, "Title"),
        (.addedAtDesc, "Date Added"),
        (.releaseDateDesc, "Release Date"),
        (.ratingDesc, "Rating")
    ]

    init(library: PlexLibrary, showsAccount: Bool = false) {
        self.library = library
        self.showsAccount = showsAccount
        _sortRaw = AppStorage(wrappedValue: LibrarySortOption.titleAsc.rawValue, "iosLibrarySort.\(library.key)")
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
        .navigationTitle(plex.displayTitle(library.title, serverID: library.serverID))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortRaw) {
                        ForEach(Self.sorts, id: \.0) { Text($0.1).tag($0.0.rawValue) }
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
            if showsAccount { IOSAccountToolbarItem() }
        }
        .task(id: "\(queryKey)|\(plex.watchStateRevision)") {
            // Nothing claimed and nothing shown: a first page that was cancelled when the view left.
            if loadedQuery != queryKey || (slots.slots.isEmpty && slots.claimedPages.isEmpty) {
                await restart()
            } else if loadedRevision != plex.watchStateRevision {
                await refetchLoaded()
            }
        }
    }

    /// Starts the query over from an empty grid.
    private func restart() async {
        slots = PagedSlots(pageSize: Self.pageSize)
        error = nil
        loadedQuery = queryKey
        loadedRevision = plex.watchStateRevision
        isFetchingFirstPage = true
        defer { isFetchingFirstPage = false }
        slots.claim(0)
        await fetch(0)
    }

    /// Refetches every page fetched so far, in place: a watch-state change or pull to refresh.
    private func refetchLoaded() async {
        loadedRevision = plex.watchStateRevision
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
            let page = try await plex.libraryPage(
                library, sort: sort, unwatchedOnly: unwatchedOnly, start: start, size: Self.pageSize
            )
            guard query == queryKey else { return }
            slots.fill(page.items, at: start, total: page.totalSize)
            error = nil
        } catch {
            // A newer query has its own slots; only this query's claim is released.
            guard query == queryKey else { return }
            slots.release(start)
            if !isCancellationError(error), slots.slots.isEmpty { self.error = error.localizedDescription }
        }
    }
}
