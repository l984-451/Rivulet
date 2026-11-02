// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicAlbumViewController.swift
//  Rivulet
//
//  The album page and the playlist page: one template, two sources. Artwork
//  800x800 pinned at (80, 60); the right column (x 960..1840) scrolls a header
//  cell, the track rows (under "Disc N" headings on a multi-disc album) and
//  the song count. Measured from Apple Music on tvOS 26.
//

import UIKit
import Combine

@MainActor
final class MusicAlbumViewController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    private enum Source {
        case album(MusicAlbum)
        case playlist(MusicPlaylist)
    }

    /// Rows are identified by position: a playlist may hold a track twice.
    private nonisolated enum Item: Hashable, Sendable {
        case header
        case track(Int)
    }

    private let source: Source
    private var tracks: [MusicTrack] = []
    /// One per "Disc N" heading; empty on a playlist and on a single-disc album.
    private var discRuns: [(disc: Int, tracks: Range<Int>)] = []
    /// Playlists page in; nil once the last page is loaded (and for albums).
    private var nextPage: Page?
    private var isLoadingPage = false
    /// The item list's own count. The playlist row's goes stale on a smart playlist.
    private var playlistTotal: Int?
    private var observers = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?

    private let artwork = UIImageView()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let playButton = MusicChrome.pill(title: String(localized: "Play"), symbol: "play.fill")
    private let shuffleButton = MusicChrome.pill(title: String(localized: "Shuffle"), symbol: "shuffle")
    private let moreButton = MusicChrome.pill(title: nil, symbol: "ellipsis")
    private lazy var failureView = MusicChrome.failureView { [weak self] in self?.loadTracks() }

    private var rowStyle: MusicTrackRowCell.Style {
        if case .album = source { return .numbered }
        return .thumbnail
    }

    private var provider: (any MusicProvider)? {
        switch source {
        case .album(let album): return MusicProviderRegistry.shared.provider(for: album.ref)
        case .playlist(let playlist): return MusicProviderRegistry.shared.provider(for: playlist.ref)
        }
    }

    init(album: MusicAlbum) {
        source = .album(album)
        super.init(nibName: nil, bundle: nil)
    }

    init(playlist: MusicPlaylist) {
        source = .playlist(playlist)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        let background = MusicChrome.background()
        background.frame = view.bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(background)

        artwork.frame = CGRect(x: MusicMetrics.margin, y: MusicMetrics.top, width: 800, height: 800)
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 30
        artwork.layer.cornerCurve = .continuous
        artwork.image = MusicChrome.placeholder(side: 800)
        view.addSubview(artwork)
        let artworkURL: URL?
        switch source {
        case .album(let album): artworkURL = album.artwork.poster
        case .playlist(let playlist): artworkURL = playlist.artworkURL
        }
        MusicChrome.loadArtwork(artworkURL, quality: .full) { [weak self] image in
            if let image { self?.artwork.image = image }
        }

        // The frame is the column plus the row platter's outset on each side.
        let outset = MusicTrackRowCell.platterOutset
        collectionView.frame = CGRect(x: 960 - outset, y: 0,
                                      width: view.bounds.width - 960 - MusicMetrics.margin + outset * 2,
                                      height: view.bounds.height)
        collectionView.autoresizingMask = [.flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delegate = self
        collectionView.addGestureRecognizer(
            TileLongPress.makeRecognizer(target: self, action: #selector(handleLongPress(_:))))
        view.addSubview(collectionView)
        configureDataSource()

        // Exactly the rows' area: anything larger would cover the header's buttons.
        failureView.frame = CGRect(x: 960, y: headerHeight, width: columnWidth,
                                   height: view.bounds.height - headerHeight)
        view.addSubview(failureView)

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(dismissSelf))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuTap.delegate = self
        view.addGestureRecognizer(menuTap)

        // Playing row, favorite stars, and the menu's "Play After" subtitle follow the queue.
        let queue = MusicQueue.shared
        Publishers.Merge4(queue.$currentTrack.map { _ in () }, queue.$playbackState.map { _ in () },
                          queue.$favoriteOverrides.map { _ in () }, queue.$queue.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueChanged() }
            .store(in: &observers)

        playButton.addAction(UIAction { [weak self] _ in self?.play(shuffled: false) }, for: .primaryActionTriggered)
        shuffleButton.addAction(UIAction { [weak self] _ in self?.play(shuffled: true) }, for: .primaryActionTriggered)
        moreButton.showsMenuAsPrimaryAction = true
        refreshMenu()

        applySnapshot()
        loadTracks()
        menuTask = Task { [weak self] in
            await MusicMenus.loadPlaylists()
            self?.refreshMenu()
        }
    }

    // The queue can change while another page covers this one, and the menu names its last track.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshMenu()
    }

    // Closed, not covered: a load or a Play still in flight must not act on a page that is gone.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed else { return }
        loadTask?.cancel()
        menuTask?.cancel()
        MusicMenus.cancelPendingPlay()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [collectionView] }

    @objc private func dismissSelf() { dismiss(animated: true) }

    // A press a presented menu or popup declines must not close the page behind it.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        presentedViewController == nil
    }

    // MARK: - Collection

    private var headerLayout: MusicHeaderCell.Layout { rowStyle == .numbered ? .album : .playlist }
    private var columnWidth: CGFloat { view.bounds.width - 960 - MusicMetrics.margin }

    private var headerHeight: CGFloat {
        let title: String
        switch source {
        case .album(let album): title = album.title
        case .playlist(let playlist): title = playlist.title
        }
        return headerLayout.height + MusicHeaderCell.titleOverflow(title, width: columnWidth)
    }

    /// Apple's footer line sits 56 under the last row. The 60 under it is the page's bottom margin.
    private static let footerTop: CGFloat = 56
    private static let footerHeight = footerTop + ceil(UIFont.systemFont(ofSize: 29).lineHeight) + 60
    /// A disc heading takes one album row. Apple's paddings were not read: INFERRED.
    private static let discHeaderHeight: CGFloat = 90

    /// Section 0 is the header; each section after it is a run of tracks (one, or one per disc).
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [unowned self] section, _ in
            let size = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(section == 0 ? headerHeight : rowStyle.height))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let layoutSection = NSCollectionLayoutSection(group: group)
            let outset = MusicTrackRowCell.platterOutset
            // Insets are from the collection's edges; the default reference adds the tvOS safe area.
            layoutSection.contentInsetsReference = .none
            layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: outset, bottom: 0, trailing: outset)
            func addLabel(_ kind: String, height: CGFloat, _ alignment: NSRectAlignment) {
                layoutSection.boundarySupplementaryItems.append(NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                    elementKind: kind, alignment: alignment))
            }
            if section > 0, !discRuns.isEmpty {
                addLabel(UICollectionView.elementKindSectionHeader, height: Self.discHeaderHeight, .top)
            }
            if section == max(discRuns.count, 1), !tracks.isEmpty {
                addLabel(UICollectionView.elementKindSectionFooter, height: Self.footerHeight, .bottom)
            }
            return layoutSection
        }
    }

    private lazy var headerRegistration = UICollectionView.CellRegistration<MusicHeaderCell, Item> {
        [unowned self] cell, _, _ in
        let buttons = [playButton, shuffleButton, moreButton]
        switch source {
        case .album(let album):
            let meta = [album.genres.first, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
            cell.configure(layout: .album, title: album.title, line2: album.artistName, line3: meta, buttons: buttons)
        case .playlist(let playlist):
            cell.configure(layout: .playlist, title: playlist.title, line2: playlist.isSmart ? String(localized: "Smart Playlist") : String(localized: "Playlist"),
                           line3: summary(of: playlist), buttons: buttons)
        }
    }

    private lazy var rowRegistration = UICollectionView.CellRegistration<MusicTrackRowCell, Item> {
        [unowned self] cell, indexPath, item in
        guard case .track(let index) = item, tracks.indices.contains(index) else { return }
        let track = tracks[index]
        let queue = MusicQueue.shared
        let isCurrent = queue.currentTrack?.ref == track.ref
        var artist = track.artistName
        var number: Int?
        if case .album(let album) = source {
            if artist == album.artistName { artist = nil }
            number = track.trackNumber ?? indexPath.item + 1
        }
        cell.configure(track: track, style: rowStyle, number: number, artist: artist,
                       isCurrent: isCurrent, isPlaying: queue.playbackState == .playing,
                       isFavorite: queue.isFavorite(track))
    }

    private lazy var discRegistration = UICollectionView.SupplementaryRegistration<MusicListLabelView>(
        elementKind: UICollectionView.elementKindSectionHeader) { [unowned self] view, _, indexPath in
        guard discRuns.indices.contains(indexPath.section - 1) else { return }
        let font = UIFont.systemFont(ofSize: 38, weight: .bold)
        view.configure(text: String(localized: "Disc \(discRuns[indexPath.section - 1].disc)"), font: font, color: .white,
                       top: (Self.discHeaderHeight - ceil(font.lineHeight)) / 2)
    }

    private lazy var footerRegistration = UICollectionView.SupplementaryRegistration<MusicListLabelView>(
        elementKind: UICollectionView.elementKindSectionFooter) { [unowned self] view, _, _ in
        view.configure(text: footerText, font: .systemFont(ofSize: 29), color: MusicMetrics.tertiary,
                       top: Self.footerTop)
    }

    private func configureDataSource() {
        let header = headerRegistration, row = rowRegistration
        let disc = discRegistration, footer = footerRegistration
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(using: header, for: indexPath, item: item)
            case .track:
                return collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: kind == UICollectionView.elementKindSectionHeader ? disc : footer, for: indexPath)
        }
    }

    /// Apple's rule: disc headings only when every track has a disc number and the
    /// list holds at least two runs of them. A single-disc album gets none.
    static func discRuns(in tracks: [MusicTrack]) -> [(disc: Int, tracks: Range<Int>)] {
        var runs: [(disc: Int, tracks: Range<Int>)] = []
        for (index, track) in tracks.enumerated() {
            guard let disc = track.discNumber else { return [] }
            if let last = runs.last, last.disc == disc {
                runs[runs.count - 1].tracks = last.tracks.lowerBound..<index + 1
            } else {
                runs.append((disc, index..<index + 1))
            }
        }
        return runs.count >= 2 ? runs : []
    }

    /// The track a row shows: on a multi-disc album the rows are split across sections.
    private func trackIndex(at indexPath: IndexPath) -> Int? {
        guard case .track(let index) = dataSource.itemIdentifier(for: indexPath),
              tracks.indices.contains(index) else { return nil }
        return index
    }

    // The header is in the first snapshot, before tracks load, so the page is never focusless.
    private func applySnapshot() {
        if case .album = source { discRuns = Self.discRuns(in: tracks) }
        let runs = discRuns.isEmpty ? [tracks.indices] : discRuns.map(\.tracks)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections(Array(0...runs.count))
        snapshot.appendItems([.header], toSection: 0)
        // A playlist's song count arrives with its first page.
        snapshot.reconfigureItems([.header])
        for (index, run) in runs.enumerated() {
            snapshot.appendItems(run.map(Item.track), toSection: index + 1)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func queueChanged() {
        var snapshot = dataSource.snapshot()
        let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        snapshot.reconfigureItems(visible.filter { $0 != .header })
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshMenu()
    }

    // The header cell is a container: focus goes through it to its buttons.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { true }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let index = trackIndex(at: indexPath) else { return }
        play(startingAt: index)
    }

    // Paging is keyed on display, not focus: after a fast scroll the engine stops issuing focus moves.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        if let index = trackIndex(at: indexPath), index >= tracks.count - 12 { loadNextPage() }
    }

    // MARK: - Data

    private func loadTracks() {
        failureView.isHidden = true
        switch source {
        case .album(let album):
            loadTask = Task { [weak self, provider] in
                let loaded = try? await provider?.tracks(for: album.ref)
                guard let self, !Task.isCancelled else { return }
                guard let loaded else { failureView.isHidden = false; return }
                tracks = loaded
                applySnapshot()
            }
        case .playlist:
            nextPage = Page(offset: 0, limit: 200)
            loadNextPage()
        }
    }

    private func loadNextPage() {
        guard case .playlist(let playlist) = source, let page = nextPage, !isLoadingPage else { return }
        isLoadingPage = true
        loadTask = Task { [weak self, provider] in
            var result = try? await provider?.tracks(inPlaylist: playlist.ref, page: page)
            // A later page: the last rows may all be on screen already, so no row would ask again.
            for _ in 0..<3 where result == nil && page.offset > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                result = try? await provider?.tracks(inPlaylist: playlist.ref, page: page)
            }
            guard let self, !Task.isCancelled else { return }
            isLoadingPage = false
            // After that `nextPage` is kept, so the next row to appear asks.
            guard let result else { failureView.isHidden = !tracks.isEmpty; return }
            playlistTotal = result.total
            nextPage = result.nextPage
            tracks += result.items
            applySnapshot()
        }
    }

    /// Play, Shuffle and a row tap. A playlist still paging in plays from the server's
    /// list, not from the pages scrolled into view.
    private func play(shuffled: Bool = false, startingAt index: Int = 0) {
        guard case .playlist(let playlist) = source, nextPage != nil else {
            let loaded = tracks
            return MusicMenus.play({ loaded }, shuffled: shuffled, startingAt: index)
        }
        // Longer than a queue holds: Shuffle draws a random window, a row tap one that starts at the row.
        let count = playlistTotal ?? playlist.trackCount
        let offset = shuffled ? MusicMenus.shuffleOffset(count: count) : (count > MusicMenus.playlistCap ? index : 0)
        MusicMenus.play({ try await MusicMenus.playlistTracks(playlist, from: offset) },
                        shuffled: shuffled, startingAt: index - offset)
    }

    private func summary(of playlist: MusicPlaylist) -> String {
        let count = playlistTotal ?? playlist.trackCount
        let songs = String(localized: "\(count) songs")
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = playlist.duration >= 3600 ? [.hour, .minute] : [.minute]
        // The duration is from the same row as the stale count: shown only while the two agree.
        guard count == playlist.trackCount, playlist.duration >= 60,
              let length = formatter.string(from: playlist.duration) else { return songs }
        return "\(songs) · \(length)"
    }

    /// The line under the list. An album's length is the sum of its tracks, as Apple's is.
    private var footerText: String {
        switch source {
        case .album:
            return MusicChrome.songSummary(count: tracks.count, duration: tracks.reduce(0) { $0 + $1.duration })
        case .playlist(let playlist):
            let count = playlistTotal ?? playlist.trackCount
            // As in the header: the playlist row's duration is good only while its count is.
            return MusicChrome.songSummary(count: count, duration: count == playlist.trackCount ? playlist.duration : nil)
        }
    }

    // MARK: - Menus

    private func navigate(_ request: MusicNavigationRequest) {
        MusicPresenter.show(request, from: self)
    }

    // Reassigning the menu while it is open would close it under the user.
    private func refreshMenu() {
        guard presentedViewController?.isBeingDismissed ?? true else { return }
        switch source {
        case .album(let album):
            moreButton.menu = MusicMenus.uiMenu(MusicMenus.album(album) { [weak self] in self?.navigate($0) })
        case .playlist(let playlist):
            moreButton.menu = MusicMenus.uiMenu(MusicMenus.playlist(playlist))
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let indexPath = TileLongPress.focusedCell(in: collectionView),
              let index = trackIndex(at: indexPath),
              let cell = collectionView.cellForItem(at: indexPath) else { return }
        let items = MusicMenus.track(tracks[index], screen: rowStyle == .numbered ? .album : .playlist) {
            [weak self] in self?.navigate($0)
        }
        MusicMenus.presentPopup(items, from: self, sourceFrame: cell.convert(cell.bounds, to: nil))
    }
}
