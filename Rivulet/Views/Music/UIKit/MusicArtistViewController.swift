// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicArtistViewController.swift
//  Rivulet
//
//  The artist page. Apple has no reference for it, so the layout is inferred
//  from the library grammar: name and album count over Play / Shuffle / More,
//  a five-column grid of album lockups, then the About text.
//

import UIKit
import Combine

@MainActor
final class MusicArtistViewController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    private nonisolated enum Section: Int, Sendable { case header, albums, about }
    private nonisolated enum Item: Hashable, Sendable {
        case header
        case album(MediaItemRef)
        case about
    }

    private let artist: MusicArtist
    /// Handed in by "Go to Artist", which had to fetch it to learn who the artist is.
    private let preloaded: MusicArtistDetail?
    private var albums: [MusicAlbum] = []
    private var bio: String?
    private var loadTask: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let playButton = MusicChrome.pill(title: String(localized: "Play"), symbol: "play.fill")
    private let shuffleButton = MusicChrome.pill(title: String(localized: "Shuffle"), symbol: "shuffle")
    private let moreButton = MusicChrome.pill(title: nil, symbol: "ellipsis")
    private lazy var failureView = MusicChrome.failureView { [weak self] in self?.load() }

    private var provider: (any MusicProvider)? {
        MusicProviderRegistry.shared.provider(for: artist.ref)
    }

    init(artist: MusicArtist, detail: MusicArtistDetail? = nil) {
        self.artist = artist
        preloaded = detail
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

        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delegate = self
        collectionView.addGestureRecognizer(
            TileLongPress.makeRecognizer(target: self, action: #selector(handleLongPress(_:))))
        view.addSubview(collectionView)
        configureDataSource()

        // Below the header only: anything larger would cover its buttons.
        failureView.frame = view.bounds.inset(by: UIEdgeInsets(top: Self.headerHeight, left: 0, bottom: 0, right: 0))
        view.addSubview(failureView)

        playButton.addAction(UIAction { [weak self] _ in self?.playAll(shuffled: false) }, for: .primaryActionTriggered)
        shuffleButton.addAction(UIAction { [weak self] _ in self?.playAll(shuffled: true) }, for: .primaryActionTriggered)
        moreButton.showsMenuAsPrimaryAction = true
        refreshMenu()
        // The menu's "Play After" row names the queue's last track.
        let queue = MusicQueue.shared
        Publishers.Merge(queue.$queue.map { _ in () }, queue.$currentTrack.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshMenu() }
            .store(in: &observers)

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(dismissSelf))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuTap.delegate = self
        view.addGestureRecognizer(menuTap)

        if let preloaded { show(preloaded) } else { applySnapshot() }
        load()
    }

    /// One request pair gives the albums and the bio. The playlists are for the tiles' long-press menu.
    private func load() {
        failureView.isHidden = true
        loadTask = Task { [weak self, provider, artist, preloaded] in
            if preloaded == nil {
                let detail = try? await provider?.artistDetail(for: artist.ref)
                guard let self, !Task.isCancelled else { return }
                guard let detail else { failureView.isHidden = false; return }
                show(detail)
            }
            await MusicMenus.loadPlaylists()
        }
    }

    private func show(_ detail: MusicArtistDetail) {
        albums = detail.albums.sorted { ($0.sortTitle ?? $0.title) < ($1.sortTitle ?? $1.title) }
        bio = detail.bio?.isEmpty == false ? detail.bio : nil
        applySnapshot()
    }

    // The queue can change while another page covers this one.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshMenu()
    }

    // Reassigning the menu while it is open would close it under the user.
    private func refreshMenu() {
        guard presentedViewController?.isBeingDismissed ?? true else { return }
        moreButton.menu = MusicMenus.uiMenu(MusicMenus.artist(artist))
    }

    // A page opened from a tile covers it; clear any lockup left looking focused.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MusicLockupCell.resetStaleFocus(in: collectionView)
    }

    // Closed, not covered: a load or a Play still in flight must not act on a page that is gone.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed else { return }
        loadTask?.cancel()
        MusicMenus.cancelPendingPlay()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [collectionView] }

    @objc private func dismissSelf() { dismiss(animated: true) }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        presentedViewController == nil
    }

    // The lockup that held focus gets no unfocus event when focus leaves the
    // whole collection, so sweep when focus comes back in.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let wasInside = context.previouslyFocusedView?.isDescendant(of: collectionView) == true
        let isInside = context.nextFocusedView?.isDescendant(of: collectionView) == true
        if !wasInside && isInside { MusicLockupCell.resetStaleFocus(in: collectionView) }
    }

    // MARK: - Collection

    private static let headerHeight: CGFloat = 216

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { index, _ in
            let margin = MusicMetrics.margin
            switch Section(rawValue: index) {
            case .albums:
                let section = MusicLockupCell.gridSection(lines: 2)
                section.contentInsetsReference = .none
                section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 40, trailing: margin)
                return section
            default:
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                  heightDimension: .absolute(index == 0 ? Self.headerHeight : 230))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: size,
                                                             subitems: [NSCollectionLayoutItem(layoutSize: size)])
                let section = NSCollectionLayoutSection(group: group)
                section.contentInsetsReference = .none
                section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: index == 0 ? 0 : 60,
                                                                trailing: margin)
                return section
            }
        }
    }

    private lazy var headerRegistration = UICollectionView.CellRegistration<MusicHeaderCell, Item> {
        [unowned self] cell, _, _ in
        let count = albums.isEmpty ? nil : String(localized: "\(albums.count) albums")
        cell.configure(layout: .grid, title: artist.name, line2: count, buttons: [playButton, shuffleButton, moreButton])
    }

    private lazy var albumRegistration = UICollectionView.CellRegistration<MusicLockupCell, Item> {
        [unowned self] cell, indexPath, _ in
        guard albums.indices.contains(indexPath.item) else { return }
        let album = albums[indexPath.item]
        cell.configure(title: album.title, subtitle: album.year.map(String.init),
                       artworkURL: album.artwork.poster, shape: .square)
    }

    private lazy var aboutRegistration = UICollectionView.CellRegistration<MusicAboutCell, Item> {
        [unowned self] cell, _, _ in
        cell.configure(text: bio ?? "")
    }

    private func configureDataSource() {
        let header = headerRegistration, album = albumRegistration, about = aboutRegistration
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(using: header, for: indexPath, item: item)
            case .album:
                return collectionView.dequeueConfiguredReusableCell(using: album, for: indexPath, item: item)
            case .about:
                return collectionView.dequeueConfiguredReusableCell(using: about, for: indexPath, item: item)
            }
        }
    }

    // The header is in the first snapshot, so the page is never focusless.
    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.header, .albums, .about])
        snapshot.appendItems([.header], toSection: .header)
        snapshot.appendItems(albums.map { .album($0.ref) }, toSection: .albums)
        if bio != nil { snapshot.appendItems([.about], toSection: .about) }
        snapshot.reconfigureItems([.header])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // The header cell is a container: focus goes through it to its buttons.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { true }

    // First focus is Play. Without this the engine takes the top-left tile once the albums are in.
    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        IndexPath(item: 0, section: 0)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .album:
            guard albums.indices.contains(indexPath.item) else { return }
            MusicPresenter.showAlbum(albums[indexPath.item], from: self)
        case .about:
            // A popup, because a scrolling text view here would trap touch swipes.
            let content = InfoPopupContent.description(title: artist.name, subtitle: nil, body: bio)
            present(InfoPopupViewController(content: content, width: InfoPopupViewController.descriptionSize.width, height: InfoPopupViewController.descriptionSize.height, scrollable: true), animated: true)
        default:
            break
        }
    }

    // MARK: - Actions

    private func playAll(shuffled: Bool) {
        MusicMenus.play({ [provider, artist] in try await provider?.allTracks(for: artist.ref) ?? [] }, shuffled: shuffled)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let indexPath = TileLongPress.focusedCell(in: collectionView),
              case .album = dataSource.itemIdentifier(for: indexPath), albums.indices.contains(indexPath.item),
              let cell = collectionView.cellForItem(at: indexPath) else { return }
        let items = MusicMenus.album(albums[indexPath.item], showsArtist: false) { [weak self] in
            MusicPresenter.show($0, from: self)
        }
        MusicMenus.presentPopup(items, from: self, sourceFrame: cell.convert(cell.bounds, to: nil))
    }
}

// MARK: - About cell

/// The artist's biography, cut to a few lines. Select opens the full text.
@MainActor
final class MusicAboutCell: UICollectionViewCell {
    private let platter = MusicFocusPlatterView()
    private let heading = MusicChrome.label(size: 29, weight: .bold)
    private let body = MusicChrome.label(size: 25, weight: .regular, color: MusicMetrics.secondary, lines: 4)

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        heading.text = String(localized: "About")
        for view in [platter, heading, body] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        let outset = MusicTrackRowCell.platterOutset
        NSLayoutConstraint.activate([
            platter.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: -outset),
            platter.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: outset),
            platter.topAnchor.constraint(equalTo: contentView.topAnchor),
            platter.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            heading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            body.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 1200),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String) { body.text = text }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.platter.alpha = focused ? 1 : 0
            self.body.textColor = focused ? .white : MusicMetrics.secondary
        }
    }
}
