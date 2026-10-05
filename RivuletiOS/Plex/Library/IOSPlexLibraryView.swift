// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Library tab root: the server's movie and TV libraries.
struct IOSPlexLibrariesView: View {
    @EnvironmentObject private var plex: IOSPlexSession

    var body: some View {
        Group {
            if !plex.isConfigured {
                IOSPlexConnectView()
            } else if plex.libraries.isEmpty {
                ScrollView {
                    Group {
                        if plex.isLoadingContent {
                            ProgressView()
                        } else if let error = plex.contentError {
                            IOSPlexErrorView(title: "Couldn't Load Libraries", message: error) { await plex.refresh() }
                        } else {
                            ContentUnavailableView("No Libraries", systemImage: "film.stack")
                        }
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await plex.refresh() }
            } else {
                List(plex.libraries) { library in
                    NavigationLink(value: library) {
                        Label(library.title, systemImage: library.icon)
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
}

/// One library as a paged poster grid with Sort and Filter menus.
struct IOSPlexLibraryView: View {
    let library: PlexLibrary
    /// Only a tab root shows the avatar; a grid pushed from the Library list does not.
    var showsAccount = false
    @EnvironmentObject private var plex: IOSPlexSession
    @AppStorage private var sortRaw: String
    @State private var unwatchedOnly = false
    @State private var items: [PlexMetadata] = []
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?
    /// Query and watch-state revision the grid holds, so a reappearing view
    /// keeps its data and scroll position instead of reloading.
    @State private var loadedKey: String?

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
    private var queryKey: String { "\(sortRaw)|\(unwatchedOnly)|\(plex.watchStateRevision)" }

    var body: some View {
        Group {
            if items.isEmpty, let error {
                IOSPlexErrorView(title: "Couldn't Load Library", message: error) { await reload() }
            } else if items.isEmpty, !isLoading, loadedKey != nil {
                ScrollView {
                    ContentUnavailableView(
                        unwatchedOnly ? "Nothing Unwatched" : "No Items",
                        systemImage: library.icon
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await reload() }
            } else {
                ScrollView {
                    IOSPlexPosterGrid(items: items, loadMore: loadMore)
                    if isLoading { ProgressView().padding() }
                }
                .refreshable { await reload() }
            }
        }
        .navigationTitle(library.title)
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
        .task(id: queryKey) {
            guard loadedKey != queryKey else { return }
            await reload()
        }
    }

    /// Refetches from the top. A watch-state change refetches every loaded
    /// page in one request so the grid repaints in place.
    private func reload() async {
        let key = queryKey
        let keepCount = loadedKey?.hasPrefix("\(sortRaw)|\(unwatchedOnly)|") == true ? items.count : 0
        if keepCount == 0 { items = [] }
        isLoading = true
        // A superseded load must not clear the flag while the newer one runs.
        defer { if key == queryKey { isLoading = false } }
        do {
            let page = try await plex.libraryPage(
                library, sort: sort, unwatchedOnly: unwatchedOnly,
                start: 0, size: max(Self.pageSize, keepCount)
            )
            guard key == queryKey else { return }
            items = page.items.uniqued()
            total = page.totalSize
            error = nil
            loadedKey = key
        } catch let error where isCancellationError(error) {
        } catch {
            guard key == queryKey else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadMore() {
        guard !isLoading, let total, items.count < total else { return }
        let key = queryKey
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let page = try? await plex.libraryPage(
                library, sort: sort, unwatchedOnly: unwatchedOnly, start: items.count, size: Self.pageSize
            ), key == queryKey else { return }
            items = (items + page.items).uniqued()
            // An empty page means the server's count overstated; stop paging.
            self.total = page.items.isEmpty ? items.count : page.totalSize
        }
    }
}
