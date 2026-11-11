// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// One library: Recommended (its own rows), Browse (every title, with sort and filter) or
/// Folders (as on disk). The page is remembered per library. Parity source: RivuletiOS/Plex/Library/IOSPlexLibraryView.swift.
struct MacLibraryView: View {
    let library: MediaLibrary
    @EnvironmentObject private var browse: BrowseStore
    @AppStorage private var pageRaw: String
    /// Same key as the tvOS library hero setting.
    @AppStorage("showLibraryHero") private var showHero = true
    @State private var rows: [MediaHub] = []

    enum LibraryPage: String, CaseIterable {
        case recommended, browse, folders

        var title: LocalizedStringKey {
            switch self {
            case .recommended: "Recommended"
            case .browse: "Browse"
            case .folders: "Folders"
            }
        }
    }

    init(library: MediaLibrary) {
        self.library = library
        let initial: LibraryPage = library.browsesByFolder ? .folders : .recommended
        _pageRaw = AppStorage(wrappedValue: initial.rawValue, "macLibraryPage.\(library.settingKey)")
    }

    private var pages: [LibraryPage] {
        library.offersFolders(on: browse.provider(for: library.providerID)) ? LibraryPage.allCases : [.recommended, .browse]
    }

    var body: some View {
        Group {
            switch LibraryPage(rawValue: pageRaw).flatMap({ pages.contains($0) ? $0 : nil }) ?? .recommended {
            case .recommended:
                MacLibraryRecommendedView(library: library, rows: $rows, heroItems: showHero ? HomeHero.libraryItems(rows) : [])
            case .browse: MacLibraryBrowseView(library: library)
            case .folders: MacFolderListView(library: library)
            }
        }
        .navigationTitle(browse.labels.title(library.title, providerID: library.providerID))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $pageRaw) {
                    ForEach(pages, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: pages.count > 2 ? 300 : 220)
            }
        }
    }
}

/// Recommended: the library's own rows from its server. They live in the parent,
/// so switching pages and back keeps them.
private struct MacLibraryRecommendedView: View {
    let library: MediaLibrary
    @Binding var rows: [MediaHub]
    let heroItems: [MediaItem]
    @EnvironmentObject private var browse: BrowseStore
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedRevision: Int?

    var body: some View {
        Group {
            if !rows.isEmpty {
                MacHeroFeed(rows: rows, heroItems: heroItems, banners: [])
                    .safeAreaPadding(.top, heroItems.isEmpty ? 20 : 0)
            } else if let error {
                MacErrorView(title: "Couldn't Load Recommended", message: error) { await reload() }
            } else if isLoading || loadedRevision == nil {
                ProgressView()
            } else {
                ContentUnavailableView("Nothing Recommended", systemImage: library.icon,
                                       description: Text("Switch to Browse to see every title."))
            }
        }
        .macPageRefresh { Task { await reload() } }
        .task(id: browse.watchStateRevision) {
            guard loadedRevision != browse.watchStateRevision else { return }
            await reload()
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
private struct MacLibraryBrowseView: View {
    let library: MediaLibrary
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.macActions) private var actions
    @AppStorage private var sortRaw: String
    @State private var filter = LibraryFilter.none
    @State private var filterOptions = LibraryFilterOptions()
    /// Every item's place, filled page by page as the grid scrolls, so the scroll length is the library's from the first page.
    @State private var slots = PagedSlots<MediaItem>(pageSize: Self.pageSize)
    @State private var error: String?
    /// Query and watch-state revision the grid holds, so a reappearing view keeps its data.
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
        _sortRaw = AppStorage(wrappedValue: LibrarySortOption.titleAsc.rawValue, "macLibrarySort.\(library.settingKey)")
    }

    /// All sorts on Plex, else what the server can apply.
    private var sorts: [(LibrarySortOption, String)] {
        let provider = browse.provider(for: library.providerID)
        let offered = IOSLibrarySorts.menu(
            offered: provider?.sortOptions(for: library.kind) ?? LibrarySortOption.expressible(for: library.kind),
            isPlex: provider?.kind == .plex)
        return Self.sorts.filter { offered.contains($0.0) }
    }

    private var sort: LibrarySortOption { LibrarySortOption(rawValue: sortRaw) ?? .titleAsc }
    private var queryKey: String { "\(sortRaw)|\(filter)" }
    private var unwatchedOnly: Bool { filter.unwatchedOnly }
    /// Genre and Decade apply to movie and TV libraries only.
    private var offersGenreAndDecade: Bool { library.kind == .movies || library.kind == .shows }
    private var genreSelection: Binding<String> {
        Binding(get: { filter.genre?.id ?? "" },
                set: { id in filter.genre = filterOptions.genres.first { $0.id == id } })
    }
    private var decadeSelection: Binding<Int> {
        Binding(get: { filter.decade ?? 0 }, set: { filter.decade = $0 == 0 ? nil : $0 })
    }

    var body: some View {
        Group {
            if slots.slots.isEmpty, let error {
                MacErrorView(title: "Couldn't Load Library", message: error) { await restart() }
            } else if slots.slots.isEmpty, !slots.claimedPages.isEmpty, !isFetchingFirstPage {
                ContentUnavailableView(unwatchedOnly ? "Nothing Unwatched" : "No Items", systemImage: library.icon)
            } else if slots.slots.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    MacPosterGrid(slots: slots.slots, slotAppeared: slotAppeared).padding(.vertical, 20)
                }
            }
        }
        .toolbar {
            // Shuffle follows the Unwatched filter.
            if library.canShuffle {
                ToolbarItem {
                    if actions.preparingID == MacActions.shuffleID(providerID: library.providerID, itemID: library.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Shuffle", systemImage: "shuffle") { actions.shuffleLibrary(library, unwatchedOnly) }
                            .keyboardShortcut("s", modifiers: [.command, .shift])
                    }
                }
            }
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $sortRaw) {
                        ForEach(sorts, id: \.0) { Text($0.1).tag($0.0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $filter.unwatchedOnly) {
                        Text("All").tag(false)
                        Text("Unwatched").tag(true)
                    }
                    .pickerStyle(.inline)
                    if offersGenreAndDecade {
                        if !filterOptions.genres.isEmpty {
                            Picker("Genre", selection: genreSelection) {
                                Text("All").tag("")
                                ForEach(filterOptions.genres, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                            }
                        }
                        if !filterOptions.decades.isEmpty {
                            Picker("Decade", selection: decadeSelection) {
                                Text("All").tag(0)
                                ForEach(filterOptions.decades, id: \.self) { Text(verbatim: LibraryFilter.decadeTitle($0)).tag($0) }
                            }
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill"
                                                                 : "line.3.horizontal.decrease")
                }
            }
        }
        .macPageRefresh { Task { await refetchLoaded() } }
        .task(id: library.id) {
            guard offersGenreAndDecade, let provider = browse.provider(for: library.providerID) else { return }
            filterOptions = (try? await provider.filterOptions(in: library)) ?? LibraryFilterOptions()
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

    /// Refetches every page fetched so far, in place.
    private func refetchLoaded() async {
        loadedRevision = browse.watchStateRevision
        for start in slots.claimedPages { await fetch(start) }
    }

    /// Fetches the page under a tile that just appeared, and the next once the tile is halfway in.
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
                in: library, sort: sort.seamSort, filter: filter, page: Page(offset: start, limit: Self.pageSize)
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
