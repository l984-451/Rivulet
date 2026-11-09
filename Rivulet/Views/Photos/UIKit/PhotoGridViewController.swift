// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoGridViewController.swift
//  Rivulet
//
//  One level of a photo library: its folders, then its photos and clips, six
//  across on the app's content grid. Serves the library root and every folder.
//

import UIKit

@MainActor
final class PhotoGridViewController: UIViewController, SidebarTabReselecting {
    private enum Section: Int, CaseIterable { case folders, media }
    private static let headerKind = "PhotoGridHeader"
    private static let columns = MediaRowMetrics.posterFullCount

    var onOpenFolder: ((PhotoItem) -> Void)?

    private let listing: PhotoListing
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let stateView = HomeStateView()
    /// Holds focus while the first page loads, so Menu still reaches this tab.
    private let loadingAnchor = PreviewFocusAnchorView()
    /// Where focus goes when it next enters the grid: the last tile focused,
    /// or the photo the viewer closed on.
    private var focusTarget: IndexPath?
    private var postedBelowTop = false
    private let slideshowButton = MusicChrome.pill(title: String(localized: "Slideshow"), symbol: "play.fill")
    private let shuffleButton = MusicChrome.pill(title: String(localized: "Shuffle"), symbol: "shuffle")
    private let sortButton = MusicChrome.pill(title: nil, symbol: "arrow.up.arrow.down")
    private let showButton = MusicChrome.pill(title: nil, symbol: "line.3.horizontal.decrease")
    /// The menu button a Sort or Show choice came from, where focus returns once the grid reloads.
    private var returnToButton: UIButton?
    /// A shuffled listing loading its first page, opened in the viewer when it arrives.
    private var pendingShuffle: PhotoListing?

    init(title: String, listing: PhotoListing) {
        self.listing = listing
        super.init(nibName: nil, bundle: nil)
        self.title = title
        // Back from the viewer, focus goes to the photo it closed on, not the one that opened it.
        restoresFocusAfterTransition = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.bottom = MediaRowMetrics.rowLeading
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        collectionView.register(PhotoGridHeaderView.self, forSupplementaryViewOfKind: Self.headerKind,
                                withReuseIdentifier: Self.headerKind)
        view.addSubview(collectionView)

        stateView.frame = view.bounds
        stateView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stateView.onAction = { [weak self] in self?.listing.loadFirst() }
        view.addSubview(stateView)
        view.addSubview(loadingAnchor)

        slideshowButton.addAction(UIAction { [weak self] _ in self?.startSlideshow() }, for: .primaryActionTriggered)
        shuffleButton.addAction(UIAction { [weak self] _ in self?.startShuffle() }, for: .primaryActionTriggered)
        sortButton.showsMenuAsPrimaryAction = true
        showButton.showsMenuAsPrimaryAction = true
        refreshMenus()

        let playPause = UITapGestureRecognizer(target: self, action: #selector(playPausePressed))
        playPause.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        collectionView.addGestureRecognizer(playPause)

        listing.onChange = { [weak self] in self?.apply($0) }
        listing.loadFirst()
    }

    /// Back from a folder: that folder's Sort or Show may have changed the library's.
    func syncSavedQuery() {
        guard let library = listing.source()?.library else { return }
        let saved = PhotoPreferences.query(for: library)
        var merged = listing.query
        (merged.sort, merged.ascending, merged.show) = (saved.sort, saved.ascending, saved.show)
        listing.query = merged
        refreshMenus()
    }

    private func makeLayout() -> UICollectionViewLayout {
        let tile = MediaRowMetrics.music
        return UICollectionViewCompositionalLayout { index, _ in
            let size = PhotoCell.size(for: index == Section.folders.rawValue ? .folder : .photo)
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .absolute(size.width), heightDimension: .absolute(size.height)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                   heightDimension: .absolute(size.height)),
                subitems: [item])
            group.interItemSpacing = .fixed(tile.gap)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = tile.gap
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: tile.leading, bottom: 0,
                                                            trailing: tile.leading)
            section.contentInsetsReference = .none
            section.supplementariesFollowContentInsets = false
            if index == Section.folders.rawValue {
                // The page title, scrolling away with the content.
                section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                       heightDimension: .absolute(PhotoGridHeaderView.height)),
                    elementKind: Self.headerKind, alignment: .top)]
            }
            return section
        }
    }

    // MARK: - Data

    private func apply(_ change: PhotoListing.Change) {
        let wasEmpty = collectionView.numberOfItems(inSection: 0) + collectionView.numberOfItems(inSection: 1) == 0
        switch change {
        case .reloaded:
            focusTarget = nil
            collectionView.reloadData()
        case .appended(let folders, let media):
            if wasEmpty {
                collectionView.reloadData()
            } else {
                collectionView.performBatchUpdates {
                    collectionView.insertItems(at: folders.map { IndexPath(item: $0, section: Section.folders.rawValue) }
                                               + media.map { IndexPath(item: $0, section: Section.media.rawValue) })
                }
            }
        case .failed:
            break   // a later page: the grid stays, and the next scroll to the end asks again
        }
        updateState()
        // The saved query may only now be applied, once the source knew its library.
        if wasEmpty { refreshMenus() }
        if wasEmpty, !isEmpty {
            setNeedsFocusUpdate()
            NotificationCenter.default.post(name: .contentBecameFocusable, object: nil)
        }
    }

    private var isEmpty: Bool { listing.folders.isEmpty && listing.media.isEmpty }

    private func updateState() {
        let kind: HomeStateView.Kind?
        if !isEmpty {
            kind = nil
        } else if listing.isLoading {
            kind = .loading
        } else if listing.error != nil {
            kind = .error(message: String(localized: "This library could not be loaded."))
        } else {
            kind = .empty(message: String(localized: "No photos here."))
        }
        if let kind { stateView.configure(kind: kind) }
        stateView.isHidden = kind == nil
        collectionView.isHidden = kind != nil
        loadingAnchor.isHidden = !listing.isLoading || !isEmpty
    }

    private func item(at indexPath: IndexPath) -> PhotoItem {
        indexPath.section == Section.folders.rawValue ? listing.folders[indexPath.item] : listing.media[indexPath.item]
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if !loadingAnchor.isHidden { return [loadingAnchor] }
        if stateView.isHidden, let returnToButton, returnToButton.window != nil { return [returnToButton] }
        return [stateView.isHidden ? collectionView : stateView]
    }

    func reselectSidebarTab() {
        let section = listing.folders.isEmpty ? Section.media.rawValue : Section.folders.rawValue
        focusTarget = IndexPath(item: 0, section: section)
        SidebarReselection.returnToTop(in: collectionView, focusing: focusTarget)
    }

    // MARK: - Header

    private func refreshMenus() {
        let query = listing.query
        let sorts = listing.source()?.provider.photoSorts ?? [query.sort]
        let sortGroup = sorts.map { sort in
            UIAction(title: Self.title(sort), state: sort == query.sort ? .on : .off) { [weak self] _ in
                self?.change(from: self?.sortButton) { $0.sort = sort; $0.ascending = sort == .name }
            }
        }
        let directions: [(String, Bool)] = query.sort == .name
            ? [(String(localized: "A to Z"), true), (String(localized: "Z to A"), false)]
            : [(String(localized: "Newest First"), false), (String(localized: "Oldest First"), true)]
        let directionGroup = directions.map { title, ascending in
            UIAction(title: title, state: ascending == query.ascending ? .on : .off) { [weak self] _ in
                self?.change(from: self?.sortButton) { $0.ascending = ascending }
            }
        }
        sortButton.menu = UIMenu(children: [UIMenu(options: .displayInline, children: sortGroup),
                                            UIMenu(options: .displayInline, children: directionGroup)])
        let shows: [(String, PhotoQuery.Show)] = [(String(localized: "All"), .all),
                                                 (String(localized: "Photos"), .photos),
                                                 (String(localized: "Videos"), .videos)]
        showButton.menu = UIMenu(children: shows.map { title, show in
            UIAction(title: title, state: show == query.show ? .on : .off) { [weak self] _ in
                self?.change(from: self?.showButton) { $0.show = show }
            }
        })
    }

    private static func title(_ sort: PhotoQuery.Sort) -> String {
        switch sort {
        case .dateTaken: String(localized: "Date Taken")
        case .dateAdded: String(localized: "Date Added")
        case .name: String(localized: "Name")
        }
    }

    /// Saves the library's Sort and Show, and reloads the grid on them.
    private func change(from button: UIButton?, _ edit: (inout PhotoQuery) -> Void) {
        var query = listing.query
        edit(&query)
        guard query != listing.query else { return }
        if let library = listing.source()?.library { PhotoPreferences.setQuery(query, for: library) }
        returnToButton = button
        listing.query = query
        refreshMenus()
    }

    private func startSlideshow() {
        guard !listing.media.isEmpty else { return }
        openViewer(listing: listing, at: 0, running: true)
    }

    /// The same folder in a random order, in the viewer; the grid keeps its own.
    private func startShuffle() {
        guard pendingShuffle == nil else { return }
        var query = listing.query
        query.shuffled = true
        let shuffle = PhotoListing(folder: listing.folder, query: query, source: listing.source)
        shuffle.onChange = { [weak self, weak shuffle] change in
            guard let self, let shuffle, shuffle === pendingShuffle else { return }
            switch change {
            case .reloaded: break
            case .appended where !shuffle.media.isEmpty:
                pendingShuffle = nil
                shuffle.onChange = nil
                openViewer(listing: shuffle, at: 0, running: true)
            case .appended where shuffle.hasMore: shuffle.loadMore()
            case .appended, .failed: pendingShuffle = nil
            }
        }
        pendingShuffle = shuffle
        shuffle.loadFirst()
    }

    @objc private func playPausePressed() {
        guard let cell = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UICollectionViewCell,
              let path = collectionView.indexPath(for: cell), path.section == Section.media.rawValue else { return }
        openViewer(listing: listing, at: path.item, running: true)
    }

    // MARK: - Viewer

    private func openViewer(listing shown: PhotoListing, at index: Int, running: Bool = false) {
        let viewer = PhotoViewerViewController(listing: shown, index: index, startsSlideshow: running)
        viewer.onClose = { [weak self, shown] index in
            guard let self, shown.media.indices.contains(index) else { return }
            // A shuffled viewer's order is its own: find the photo in the grid.
            let ref = shown.media[index].ref
            guard let item = listing.media.firstIndex(where: { $0.ref == ref }) else { return }
            // The grid may have grown under the viewer; the cell has to exist to take focus.
            let path = IndexPath(item: item, section: Section.media.rawValue)
            focusTarget = path
            collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        viewer.onDismissed = { [weak self] in
            self?.collectionView.setNeedsFocusUpdate()
            self?.collectionView.updateFocusIfNeeded()
        }
        present(viewer, animated: true)
    }
}

// MARK: - UICollectionViewDataSource

extension PhotoGridViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int { Section.allCases.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        section == Section.folders.rawValue ? listing.folders.count : listing.media.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID,
                                                      for: indexPath) as! PhotoCell
        cell.configure(item(at: indexPath))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: Self.headerKind, for: indexPath) as! PhotoGridHeaderView
        header.configure(title: title, buttons: [slideshowButton, shuffleButton, sortButton, showButton])
        return header
    }
}

// MARK: - UICollectionViewDelegate

extension PhotoGridViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = item(at: indexPath)
        if item.kind == .folder { onOpenFolder?(item) } else { openViewer(listing: listing, at: indexPath.item) }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // Within five rows of the end, ask for the next page.
        if indexPath.section == Section.media.rawValue,
           indexPath.item >= listing.media.count - Self.columns * 5 {
            listing.loadMore()
        }
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        // Only a path whose cell exists right now can take focus.
        focusTarget.flatMap { collectionView.cellForItem(at: $0) == nil ? nil : $0 }
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        let next = context.nextFocusedIndexPath
        if let next { focusTarget = next }
        if next != nil || context.nextFocusedView === returnToButton { returnToButton = nil }
        if next == nil {
            for case let cell as PhotoCell in collectionView.visibleCells { cell.resetStaleFocusAppearance() }
        }
        // Below the top row the shell hides its pill; off the page it shows again.
        let firstSection = listing.folders.isEmpty ? Section.media.rawValue : Section.folders.rawValue
        let belowTop = next.map { $0.section != firstSection || $0.item >= Self.columns } ?? false
        if belowTop != postedBelowTop {
            postedBelowTop = belowTop
            NotificationCenter.default.post(name: .contentFocusBelowTopChanged, object: belowTop)
        }
    }
}

// MARK: - Header

/// The page title and its buttons, clear of the shell's pill, on the content margin.
private final class PhotoGridHeaderView: UICollectionReusableView {
    static let height = ShellPillMetrics.contentClearance + 58 + 30 + MusicMetrics.pillHeight + 50
    private let label = UILabel()
    private let row = UIStackView()
    /// Up from a tile right of the buttons lands on the first of them.
    private let upGuide = UIFocusGuide()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 48, weight: .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        row.axis = .horizontal
        row.spacing = 24
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addLayoutGuide(upGuide)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MediaRowMetrics.rowLeading),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MediaRowMetrics.rowTrailing),
            label.topAnchor.constraint(equalTo: topAnchor, constant: ShellPillMetrics.contentClearance),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MediaRowMetrics.rowLeading),
            row.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 30),
            upGuide.leadingAnchor.constraint(equalTo: row.trailingAnchor),
            upGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            upGuide.topAnchor.constraint(equalTo: row.topAnchor),
            upGuide.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The buttons belong to the grid; re-adding ones already here would drop their focus.
    func configure(title: String?, buttons: [UIButton]) {
        label.text = title
        if row.arrangedSubviews != buttons {
            row.arrangedSubviews.forEach { $0.removeFromSuperview() }
            buttons.forEach(row.addArrangedSubview)
        }
        upGuide.preferredFocusEnvironments = Array(buttons.prefix(1))
    }
}
