// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicBrowseViewController.swift
//  Rivulet
//
//  The Music library's content pane: one collection view for every sidebar
//  destination. Four 320pt columns at x 440 / 800 / 1160 / 1520 under a header
//  at y 60, or the Songs list. Sorting and filtering are the server's, so they
//  hold across every page. Measured from Apple Music on tvOS 26.
//

import UIKit
import Combine

@MainActor
final class MusicBrowseViewController: UIViewController, UICollectionViewDelegate, SidebarTabReselecting {
    private nonisolated enum Item: Hashable, Sendable {
        case header
        case entry(MediaItemRef)
    }

    private enum Entry {
        case album(MusicAlbum)
        case artist(MusicArtist)
        case playlist(MusicPlaylist)
        case track(MusicTrack)

        var ref: MediaItemRef {
            switch self {
            case .album(let album): album.ref
            case .artist(let artist): artist.ref
            case .playlist(let playlist): playlist.ref
            case .track(let track): track.ref
            }
        }
    }

    private let libraryKey: String
    private let libraryTitle: String
    private let providerID: String?
    private var destination: MusicLibraryDestination = .recentlyAdded
    private var entries: [Entry] = []
    private var seen = Set<MediaItemRef>()
    /// The server's count for the header; nil while the first page loads.
    private var total: Int?
    private var nextPage: Page?
    private var isLoadingPage = false
    /// Bumped on every swap, so a page that returns late is dropped.
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()

    /// Kept per category for the session. Every genre sorts as Albums.
    private var sorts: [MusicLibraryDestination: MusicSort] = [:]
    private var favoritesOnly = Set<MusicLibraryDestination>()

    /// The shell's one-shot-aim collection: toggling `remembersLastFocusedIndexPath` does not
    /// drop a remembered path, so a fresh list aims its entry instead (`aimEntry`).
    private lazy var collectionView = SidebarCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let playButton = MusicChrome.pill(title: String(localized: "Play"), symbol: "play.fill")
    private let shuffleButton = MusicChrome.pill(title: String(localized: "Shuffle"), symbol: "shuffle")
    private let filterButton = MusicChrome.pill(title: nil, symbol: "line.3.horizontal.decrease")
    private let sortButton = MusicChrome.pill(title: nil, symbol: "arrow.up.arrow.down")
    private lazy var failureView = MusicChrome.failureView { [weak self] in self?.reload() }

    /// The provider and this library as it knows it; nil until the registry has one.
    /// No `providerID` is the signed-in Plex server, whose id can change mid-session.
    var source: (provider: any MusicProvider, library: MediaLibrary)? {
        let registry = MusicProviderRegistry.shared
        let provider = if let providerID { registry.provider(for: providerID) } else { registry.primaryProvider }
        guard let provider else { return nil }
        return (provider, MediaLibrary(id: libraryKey, providerID: provider.id, title: libraryTitle, kind: .music))
    }

    init(libraryKey: String, libraryTitle: String, providerID: String?) {
        self.libraryKey = libraryKey
        self.libraryTitle = libraryTitle
        self.providerID = providerID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        // A focused first-column tile grows past the pane's left edge.
        collectionView.clipsToBounds = false
        collectionView.contentInsetAdjustmentBehavior = .never
        // The pane is one focus target from the sidebar, so Right lands on a tile, not the header.
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.delegate = self
        collectionView.addGestureRecognizer(
            TileLongPress.makeRecognizer(target: self, action: #selector(handleLongPress(_:))))
        view.addSubview(collectionView)
        configureDataSource()

        view.addSubview(failureView)

        playButton.addAction(UIAction { [weak self] _ in self?.playAll(shuffled: false) }, for: .primaryActionTriggered)
        shuffleButton.addAction(UIAction { [weak self] _ in self?.playAll(shuffled: true) }, for: .primaryActionTriggered)
        filterButton.showsMenuAsPrimaryAction = true
        sortButton.showsMenuAsPrimaryAction = true

        // The Songs list marks the playing row and favorites, as the playlist page does.
        let queue = MusicQueue.shared
        Publishers.Merge3(queue.$currentTrack.map { _ in () }, queue.$playbackState.map { _ in () },
                          queue.$favoriteOverrides.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueChanged() }
            .store(in: &observers)

        // For the long-press menus' "Add to Playlist" row.
        Task { await MusicMenus.loadPlaylists() }
    }

    // A page opened from a tile covers it; clear any lockup left looking focused.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MusicLockupCell.resetStaleFocus(in: collectionView)
    }

    // Left for another tab, not covered by a Music page: a Play still fetching its tracks
    // must not open Now Playing over where the user went.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentedViewController == nil { MusicMenus.cancelPendingPlay() }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [collectionView] }

    func reselectSidebarTab() {
        aimEntry()
        SidebarReselection.returnToTop(in: collectionView, focusing: collectionView.preferredFocusIndexPath)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let inside = context.nextFocusedView?.isDescendant(of: collectionView) == true
        // tvOS's fast-scroll index bar is the one focusable thing in the collection that is not in a cell.
        let onCell = context.nextFocusedView.map { view in
            sequence(first: view, next: { $0.superview }).contains { $0 is UICollectionViewCell }
        } ?? false
        isFastScrolling = inside && !onCell
        guard inside else {
            // Left from a header button: forget it, so the pane is entered at a tile again.
            if let previous = context.previouslyFocusedView,
               sequence(first: previous, next: { $0.superview }).contains(where: { $0 is MusicHeaderCell }) {
                aimEntry()
            }
            return
        }
        // The lockup that held focus gets no unfocus event when focus leaves the whole collection.
        if context.previouslyFocusedView?.isDescendant(of: collectionView) != true {
            MusicLockupCell.resetStaleFocus(in: collectionView)
        }
        // Under the index bar the remembered path would name a tile far off screen, so it is off
        // until a cell has focus.
        collectionView.remembersLastFocusedIndexPath = onCell
    }

    /// True while the index bar holds focus. Tiles flying past start no artwork load, or the ones
    /// on screen at the end wait behind hundreds; they load when focus is back on a cell.
    private var isFastScrolling = false {
        didSet {
            guard oldValue, !isFastScrolling else { return }
            // After the focus update: no snapshot is applied inside one.
            DispatchQueue.main.async { [weak self] in self?.reconfigureVisible() }
        }
    }

    private func artwork(_ url: URL?) -> URL? { isFastScrolling ? nil : url }

    /// A fresh list is entered at its top-left item, or at its header while it has none, whatever
    /// path the collection remembers: a remembered path with no cell leaves focus on the collection.
    private func aimEntry() {
        let target = entries.isEmpty ? (hasHeader ? IndexPath(item: 0, section: 0) : nil)
                                     : IndexPath(item: 0, section: 1)
        collectionView.preferredFocusIndexPath = target
        // Nothing to land on (Recently Added, still empty): the pane must not take focus at all.
        collectionView.remembersLastFocusedIndexPath = target != nil
    }

    /// The entry under focus, when focus is on a tile or a row.
    private var focusedRef: MediaItemRef? {
        guard let indexPath = TileLongPress.focusedCell(in: collectionView), indexPath.section == 1,
              entries.indices.contains(indexPath.item) else { return nil }
        return entries[indexPath.item].ref
    }

    private var focusIsInCollection: Bool {
        (UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView)?.isDescendant(of: collectionView) == true
    }

    // MARK: - Destination

    /// Swaps the pane. The old tiles go at once; the fetch waits out a sweep down the sidebar.
    func show(_ destination: MusicLibraryDestination) {
        loadViewIfNeeded()
        self.destination = destination
        reload()
    }

    /// Nothing here is cached per destination, so a swap, a sort and a filter all start over.
    func reload() {
        generation += 1
        loadTask?.cancel()
        entries = []
        seen = []
        total = nil
        nextPage = nil
        isLoadingPage = false
        failureView.isHidden = true
        refreshMenus()
        collectionView.collectionViewLayout.invalidateLayout()
        applySnapshot()
        // Not while Sort or Filter holds focus: an aim left set there would pull focus off it later.
        if !focusIsInCollection { aimEntry() }
        collectionView.contentOffset = .zero

        let generation = generation
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.loadPage(Page(offset: 0, limit: Self.pageSize), generation: generation)
        }
    }

    /// An account change: the same list refetched under the user, so scroll and focus stay put.
    func refresh() {
        Task { await MusicMenus.loadPlaylists() }
        // Past a thousand rows one request for them all is megabytes: start over instead.
        guard source != nil, !entries.isEmpty, entries.count <= 1000 else { return reload() }
        generation += 1
        loadTask?.cancel()
        // Set here, not in the task: a tile appearing meanwhile must not start a page of the old list.
        isLoadingPage = true
        let generation = generation, count = entries.count
        loadTask = Task { [weak self] in
            await self?.loadPage(Page(offset: 0, limit: max(Self.pageSize, count)), generation: generation,
                                 replacing: true)
        }
    }

    private var sort: MusicSort {
        if destination == .recentlyAdded { return .recentlyAdded }
        return sorts[sortKey] ?? .title
    }

    private var sortKey: MusicLibraryDestination {
        if case .genre = destination { return .albums }
        return destination
    }

    private var filter: MusicFilter {
        var filter = MusicFilter(favoritesOnly: favoritesOnly.contains(destination))
        if case .genre(let genre) = destination { filter.genreID = genre.id }
        return filter
    }

    // MARK: - Data

    private static let pageSize = 200

    private func loadPage(_ page: Page, generation: Int, replacing: Bool = false, attempt: Int = 0) async {
        guard generation == self.generation else { return }
        isLoadingPage = true
        let result = try? await fetch(page)
        guard generation == self.generation, !Task.isCancelled else { return }
        isLoadingPage = false
        guard let result else {
            // A failed refresh starts over: the old account's list must not stay up.
            if replacing {
                reload()
            } else if entries.isEmpty {
                showFailure()
            } else if attempt < 3 {
                // The last tiles may all be on screen already, so no tile would ask again.
                isLoadingPage = true
                try? await Task.sleep(for: .seconds(3))
                await loadPage(page, generation: generation, attempt: attempt + 1)
            }
            // After that `nextPage` is kept, so the next tile to appear asks.
            return
        }
        let focused = replacing ? focusedRef : nil
        let oldCount = entries.count
        if replacing { (entries, seen) = ([], []) }
        total = result.total
        // A refresh asks for every loaded row at once; the pages after it are the usual size.
        nextPage = result.next.map { Page(offset: $0.offset, limit: Self.pageSize) }
        // The same item twice would crash the data source.
        entries += result.entries.filter { seen.insert($0.ref).inserted }
        // The account's list may lack the focused tile, or end before the remembered one.
        let lost = focused.map { !seen.contains($0) } ?? (entries.count < oldCount && !focusIsInCollection)
        if lost {
            collectionView.contentOffset = .zero
            aimEntry()
        }
        applySnapshot()
        // The first page: an entry that was aimed at the empty list's header now goes to a tile.
        if page.offset == 0, !replacing, !focusIsInCollection { aimEntry() }
    }

    /// Below the header only: anything larger would cover its buttons. With no header the card
    /// spans the pane, so Right from any sidebar row meets its guide and reaches Try Again.
    private func showFailure() {
        failureView.frame = view.bounds.inset(by: UIEdgeInsets(top: hasHeader ? Self.gridTop : 0, left: Self.leading,
                                                               bottom: 0, right: MusicMetrics.margin))
        failureView.isHidden = false
    }

    private func fetch(_ page: Page) async throws -> (entries: [Entry], total: Int, next: Page?) {
        guard let source else { throw MediaProviderError.unreachable }
        let (provider, library) = source
        switch destination {
        case .playlists:
            let playlists = try await provider.playlists(in: library, sort: sort)
            return (playlists.map(Entry.playlist), playlists.count, nil)
        case .artists:
            let result = try await provider.artists(in: library, sort: sort, filter: filter, page: page)
            return (result.items.map(Entry.artist), result.total, result.nextPage)
        case .songs:
            let result = try await provider.tracks(in: library, sort: sort, filter: filter, page: page)
            return (result.items.map(Entry.track), result.total, result.nextPage)
        case .recentlyAdded, .albums, .genre:
            let result = try await provider.albums(in: library, sort: sort, filter: filter, page: page)
            return (result.items.map(Entry.album), result.total, result.nextPage)
        }
    }

    // MARK: - Collection

    /// The pane starts at x 400; its content at x 440.
    private static let leading: CGFloat = 40
    /// First grid row, 121 below the header's top.
    private static let gridTop: CGFloat = 181

    private var hasHeader: Bool { destination != .recentlyAdded }
    private var tileLines: Int { destination == .artists || destination == .playlists ? 1 : 2 }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [unowned self] index, _ in
            let rows = destination == .songs
            let section: NSCollectionLayoutSection
            if index == 0 || rows {
                // A song row centres its 90pt thumbnail in 110, so its header ends 10 higher.
                let height = index == 0 ? Self.gridTop - (rows ? 10 : 0) : MusicTrackRowCell.Style.thumbnail.height
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height))
                section = NSCollectionLayoutSection(group: .vertical(layoutSize: size,
                                                                     subitems: [NSCollectionLayoutItem(layoutSize: size)]))
            } else {
                section = MusicLockupCell.gridSection(lines: tileLines)
            }
            // Insets are from the collection's edges; the default reference adds the tvOS safe area.
            section.contentInsetsReference = .none
            section.contentInsets = NSDirectionalEdgeInsets(
                top: index == 1 && !hasHeader ? MusicMetrics.top : 0, leading: Self.leading,
                bottom: index == 1 ? 60 : 0, trailing: MusicMetrics.margin)
            return section
        }
    }

    private lazy var headerRegistration = UICollectionView.CellRegistration<MusicHeaderCell, Item> {
        [unowned self] cell, _, _ in
        var buttons: [UIButton] = []
        switch destination {
        case .recentlyAdded: break
        // Plex cannot rate a playlist, so there is nothing for a Favorites filter to match.
        case .playlists: buttons = [sortButton]
        case .genre: buttons = [playButton, shuffleButton, sortButton]
        case .artists, .albums, .songs: buttons = [playButton, shuffleButton, filterButton, sortButton]
        }
        cell.configure(layout: .browse, title: destination.title, line2: countText, buttons: buttons)
    }

    private var countText: String? {
        guard let total else { return nil }
        return switch destination {
        case .playlists: String(localized: "\(total) playlists")
        case .artists: String(localized: "\(total) artists")
        case .songs: String(localized: "\(total) songs")
        case .recentlyAdded, .albums, .genre: String(localized: "\(total) albums")
        }
    }

    private lazy var lockupRegistration = UICollectionView.CellRegistration<MusicLockupCell, Item> {
        [unowned self] cell, indexPath, _ in
        guard entries.indices.contains(indexPath.item) else { return }
        switch entries[indexPath.item] {
        case .album(let album):
            cell.configure(title: album.title, subtitle: album.artistName, artworkURL: artwork(album.artwork.poster),
                           shape: .square)
        case .artist(let artist):
            cell.configure(title: artist.name, subtitle: nil, artworkURL: artwork(artist.artwork.poster),
                           shape: .circle)
        case .playlist(let playlist):
            cell.configure(title: playlist.title, subtitle: nil, artworkURL: artwork(playlist.artworkURL),
                           shape: .square)
        case .track:
            break
        }
    }

    private lazy var rowRegistration = UICollectionView.CellRegistration<MusicTrackRowCell, Item> {
        [unowned self] cell, indexPath, _ in
        guard entries.indices.contains(indexPath.item), case .track(let track) = entries[indexPath.item] else { return }
        let queue = MusicQueue.shared
        let isCurrent = queue.currentTrack?.ref == track.ref
        cell.configure(track: track, style: .thumbnail, number: nil, artist: track.artistName,
                       isCurrent: isCurrent, isPlaying: queue.playbackState == .playing,
                       isFavorite: queue.isFavorite(track), loadsArtwork: !isFastScrolling)
    }

    private func configureDataSource() {
        let header = headerRegistration, lockup = lockupRegistration, row = rowRegistration
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) {
            [unowned self] collectionView, indexPath, item in
            if item == .header {
                return collectionView.dequeueConfiguredReusableCell(using: header, for: indexPath, item: item)
            }
            return destination == .songs
                ? collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
                : collectionView.dequeueConfiguredReusableCell(using: lockup, for: indexPath, item: item)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0, 1])
        if hasHeader {
            snapshot.appendItems([.header], toSection: 0)
            snapshot.reconfigureItems([.header])
        }
        snapshot.appendItems(entries.map { .entry($0.ref) }, toSection: 1)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func queueChanged() {
        if destination == .songs { reconfigureVisible() }
    }

    private func reconfigureVisible() {
        var snapshot = dataSource.snapshot()
        let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        snapshot.reconfigureItems(visible.filter { $0 != .header })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // The header cell is a container: focus goes through it to its buttons.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { true }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.section == 1, entries.indices.contains(indexPath.item) else { return }
        switch entries[indexPath.item] {
        case .album(let album): MusicPresenter.showAlbum(album, from: self)
        case .artist(let artist): MusicPresenter.showArtist(artist, from: self)
        case .playlist(let playlist): MusicPresenter.showPlaylist(playlist, from: self)
        // The queue is the server's list from this row on, not the pages scrolled into view.
        case .track: MusicMenus.play(tracks(sort: sort, from: indexPath.item))
        }
    }

    // Paging is keyed on display, not focus: after a fast scroll the engine stops issuing focus moves.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard indexPath.section == 1, indexPath.item >= entries.count - 12, !isLoadingPage,
              let page = nextPage else { return }
        isLoadingPage = true
        let generation = generation
        loadTask = Task { [weak self] in await self?.loadPage(page, generation: generation) }
    }

    // MARK: - Play

    // ponytail: one request of at most 2000 tracks feeds the queue, so Play on a larger
    // library plays its first 2000 in the shown order. Page the queue itself if that matters.
    private func tracks(sort: MusicSort, from offset: Int = 0) -> MusicMenus.TrackSource {
        var filter = filter
        // Favorites narrows albums and artists by their own rating; only Songs filters tracks by it.
        if destination != .songs { filter.favoritesOnly = false }
        return { [source] in
            guard let source else { throw MediaProviderError.unreachable }
            return try await source.provider.tracks(in: source.library, sort: sort, filter: filter,
                                                    page: Page(offset: offset, limit: MusicMenus.playlistCap)).items
        }
    }

    /// Header Play follows the order on screen; Shuffle asks the server for a random draw.
    private func playAll(shuffled: Bool) {
        // Favorite albums or artists: a track query cannot say that, so play what is listed.
        if destination != .songs, favoritesOnly.contains(destination) {
            let listed = entries
            return MusicMenus.play({ [source] in
                var tracks: [MusicTrack] = []
                for entry in listed where tracks.count < MusicMenus.playlistCap {
                    switch entry {
                    case .album(let album): tracks += try await source?.provider.tracks(for: album.ref) ?? []
                    case .artist(let artist): tracks += try await source?.provider.allTracks(for: artist.ref) ?? []
                    case .playlist, .track: break
                    }
                }
                return tracks
            }, shuffled: shuffled)
        }
        // The same order for tracks: albums by title means tracks by album, artists by name by artist,
        // and a list by date added plays each album whole, not track by track date.
        let trackSort: MusicSort = switch (destination, sort) {
        case (.songs, _): sort
        case (.artists, .title): .artist
        case (.artists, .recentlyAdded): .artistRecentlyAdded
        case (_, .title): .album
        case (_, .recentlyAdded): .albumRecentlyAdded
        default: sort
        }
        MusicMenus.play(tracks(sort: shuffled ? .random : trackSort), shuffled: shuffled)
    }

    // MARK: - Menus

    /// Apple's tvOS 26 menus are not documented: these are the maintainer's rows per category.
    private var sortOptions: [(title: String, sort: MusicSort)] {
        switch destination {
        case .recentlyAdded: []
        case .playlists: [(String(localized: "Title"), .title), (String(localized: "Recently Added"), .recentlyAdded)]
        case .artists: [(String(localized: "Name"), .title), (String(localized: "Recently Added"), .recentlyAdded)]
        case .albums, .genre: [(String(localized: "Title"), .title), (String(localized: "Artist"), .artist),
                               (String(localized: "Year"), .year), (String(localized: "Recently Added"), .recentlyAdded)]
        case .songs: [(String(localized: "Title"), .title), (String(localized: "Artist"), .artist),
                      (String(localized: "Album"), .album), (String(localized: "Recently Added"), .recentlyAdded)]
        }
    }

    private func refreshMenus() {
        let sort = sort, key = sortKey, destination = destination
        sortButton.menu = UIMenu(children: sortOptions.map { option in
            UIAction(title: option.title, state: option.sort == sort ? .on : .off) { [weak self] _ in
                self?.sorts[key] = option.sort
                self?.reload()
            }
        })
        let favorites = favoritesOnly.contains(destination)
        filterButton.menu = UIMenu(children: [(String(localized: "All"), false), (String(localized: "Favorites"), true)].map { title, value in
            UIAction(title: title, state: value == favorites ? .on : .off) { [weak self] _ in
                if value { self?.favoritesOnly.insert(destination) } else { self?.favoritesOnly.remove(destination) }
                self?.reload()
            }
        })
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let indexPath = TileLongPress.focusedCell(in: collectionView), indexPath.section == 1,
              entries.indices.contains(indexPath.item),
              let cell = collectionView.cellForItem(at: indexPath) else { return }
        let navigate: (MusicNavigationRequest) -> Void = { [weak self] in MusicPresenter.show($0, from: self) }
        let items = switch entries[indexPath.item] {
        case .album(let album): MusicMenus.album(album, navigate: navigate)
        case .artist(let artist): MusicMenus.artist(artist)
        case .playlist(let playlist): MusicMenus.playlist(playlist)
        case .track(let track): MusicMenus.track(track, screen: .songs, navigate: navigate)
        }
        MusicMenus.presentPopup(items, from: self, sourceFrame: cell.convert(cell.bounds, to: nil))
    }
}
