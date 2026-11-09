// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FolderListViewController.swift
//  Rivulet
//
//  One folder level (layout C): the preview at (80, clearance) 800 wide, the
//  list in the Music album's right column (x 960..1840), on plain black.
//

import UIKit
import Combine

@MainActor
final class FolderListViewController: UIViewController, UICollectionViewDelegate, SidebarTabReselecting {
    private nonisolated enum Item: Hashable, Sendable {
        case entry(MediaItemRef)
        case failure
    }

    private static let columnX: CGFloat = 960
    private static let margin = MusicMetrics.margin
    private static let detailDelay: Duration = .milliseconds(150)

    var onOpenFolder: ((MediaItemRef, String) -> Void)?

    private let libraryTitle: String
    private let folderTitle: String?
    private let listing: FolderListing
    private let viewMenu: (() -> UIMenu?)?
    /// The library the header's Shuffle plays; nil shows no Shuffle.
    private let shuffleLibrary: (() -> MediaLibrary?)?
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let preview = FolderPreviewView()
    private let emptyLabel = MusicChrome.label(size: 31, weight: .regular, color: UIColor(white: 1, alpha: 0.6))
    private let spinner = UIActivityIndicatorView(style: .large)
    /// Holds focus while there are no rows, so Menu still reaches the stack.
    private let anchor = PreviewFocusAnchorView()

    private var focusedRef: MediaItemRef?
    private var pendingTopFocus = false
    private var previewTask: Task<Void, Never>?
    private var sources: [MediaItemRef: MediaSource] = [:]
    private var observers = Set<AnyCancellable>()

    init(libraryTitle: String, folderTitle: String?, listing: FolderListing, viewMenu: (() -> UIMenu?)? = nil,
         shuffleLibrary: (() -> MediaLibrary?)? = nil) {
        self.libraryTitle = libraryTitle
        self.folderTitle = folderTitle
        self.listing = listing
        self.viewMenu = viewMenu
        self.shuffleLibrary = shuffleLibrary
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        preview.frame = CGRect(x: Self.margin, y: ShellPillMetrics.contentClearance, width: FolderPreviewView.width,
                               height: view.bounds.height - ShellPillMetrics.contentClearance - 60)
        view.addSubview(preview)

        // The frame is the column plus the row platter's outset on each side.
        let outset = FolderRowCell.platterOutset
        collectionView.frame = CGRect(x: Self.columnX - outset, y: 0, width: columnWidth + outset * 2,
                                      height: view.bounds.height)
        collectionView.autoresizingMask = [.flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.bottom = 60
        collectionView.delegate = self
        collectionView.addGestureRecognizer(
            TileLongPress.makeRecognizer(target: self, action: #selector(handleLongPress(_:))))
        view.addSubview(collectionView)
        configureDataSource()

        let stateFrame = CGRect(x: Self.columnX, y: headerHeight, width: columnWidth, height: 90)
        emptyLabel.text = String(localized: "This folder is empty")
        emptyLabel.frame = stateFrame
        spinner.center = CGPoint(x: stateFrame.midX, y: stateFrame.midY)
        anchor.frame = stateFrame
        [emptyLabel, spinner, anchor].forEach(view.addSubview)

        listing.onChange = { [weak self] in self?.apply($0) }
        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.listing.refresh() }
            .store(in: &observers)

        applySnapshot()
        listing.loadFirst()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        anchor.isHidden ? [collectionView] : [anchor]
    }

    private var columnWidth: CGFloat { view.bounds.width - Self.columnX - Self.margin }

    // MARK: - Collection

    private var headerHeight: CGFloat { FolderHeaderView.height(hasBreadcrumb: folderTitle != nil) }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [unowned self] _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .absolute(FolderRowCell.height))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            let outset = FolderRowCell.platterOutset
            // Insets are from the collection's edges; the default reference adds the tvOS safe area.
            section.contentInsetsReference = .none
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: outset, bottom: 0, trailing: outset)
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                   heightDimension: .absolute(headerHeight)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
            return section
        }
    }

    private lazy var rowRegistration = UICollectionView.CellRegistration<FolderRowCell, Item> {
        [unowned self] cell, _, item in
        switch item {
        case .entry(let ref):
            guard let entry = entry(ref) else { return }
            cell.configure(title: entry.title, detail: FolderRowDetail.text(for: entry))
        case .failure:
            cell.configure(title: String(localized: "Couldn't load this folder"), detail: "")
        }
    }

    private lazy var headerRegistration = UICollectionView.SupplementaryRegistration<FolderHeaderView>(
        elementKind: UICollectionView.elementKindSectionHeader) { [unowned self] header, _, _ in
        // At the library root the library's own title is the heading, with nothing above it.
        header.configure(breadcrumb: folderTitle == nil ? nil : libraryTitle, title: folderTitle ?? libraryTitle,
                         viewMenu: viewMenu,
                         onShuffle: shuffleLibrary?().map { library in { [weak self] in
                             guard let self else { return }
                             ShufflePlayback.shuffle(library, from: self)
                         } })
    }

    private func configureDataSource() {
        let row = rowRegistration, header = headerRegistration
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func entry(_ ref: MediaItemRef) -> FolderEntry? {
        listing.entries.first { $0.id == ref }
    }

    private func entry(at indexPath: IndexPath) -> FolderEntry? {
        guard case .entry(let ref) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return entry(ref)
    }

    private func applySnapshot(reconfigure: [Item] = []) {
        let old = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(listing.entries.map { .entry($0.id) })
        if listing.error != nil { snapshot.appendItems([.failure]) }
        let kept = Set(snapshot.itemIdentifiers).intersection(old)
        snapshot.reconfigureItems(reconfigure.filter(kept.contains))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func apply(_ change: FolderListing.Change) {
        let hadNoRows = !anchor.isHidden
        if case .reloaded = change {
            applySnapshot(reconfigure: dataSource.snapshot().itemIdentifiers)
        } else {
            applySnapshot()
        }
        let empty = listing.entries.isEmpty && listing.error == nil
        spinner.isHidden = !(empty && listing.isLoading)
        if empty && listing.isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
        emptyLabel.isHidden = !(empty && !listing.isLoading)
        anchor.isHidden = !empty
        if hadNoRows, anchor.isHidden {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            NotificationCenter.default.post(name: .contentBecameFocusable, object: nil)
        }
        if let focusedRef, let entry = entry(focusedRef) { showPreview(entry) }
        if focusedRef == nil, let first = listing.entries.first { showPreview(first) }
    }

    // Back from a deeper level, focus goes to the row that opened it; otherwise the
    // first row, never the header's buttons. Only if the cell exists now.
    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        let path = focusedRef.flatMap { dataSource.indexPath(for: .entry($0)) } ?? IndexPath(item: 0, section: 0)
        return collectionView.cellForItem(at: path) != nil ? path : nil
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let path = context.nextFocusedIndexPath, let entry = entry(at: path) else { return }
        focusedRef = entry.id
        showPreview(entry)
    }

    func reselectSidebarTab() {
        focusedRef = listing.entries.first?.id
        SidebarReselection.returnToTop(in: collectionView, focusing: IndexPath(item: 0, section: 0))
    }

    /// Scrolls back to the first row and focuses it. False when it already holds focus.
    func returnToTop() -> Bool {
        guard let first = listing.entries.first, focusedRef != first.id else { return false }
        focusedRef = first.id
        let top = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
        guard collectionView.contentOffset.y > top.y else { focusFirstRow(); return true }
        pendingTopFocus = true
        collectionView.setContentOffset(top, animated: true)
        return true
    }

    // The first row's cell exists only once the scroll lands.
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard pendingTopFocus else { return }
        pendingTopFocus = false
        focusFirstRow()
    }

    private func focusFirstRow() {
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    // Paging is keyed on display, not focus: after a fast scroll the engine stops issuing focus moves.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // Not after a failure: the error row itself is near the end, and showing it must not retry.
        if listing.error == nil, indexPath.item >= listing.entries.count - 10 { listing.loadMore() }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .entry = dataSource.itemIdentifier(for: indexPath) else {
            listing.loadMore()
            return
        }
        guard let entry = entry(at: indexPath) else { return }
        switch entry.content {
        case .folder(let ref, _): onOpenFolder?(ref, entry.title)
        case .video(let item): play(item, fromBeginning: false)
        case .photo(let photo): openPhoto(photo)
        }
    }

    // MARK: - Preview

    /// Shows `entry` in one crossfade once its still and file details are in, so
    /// nothing in the column arrives on its own. Until then the last preview stays.
    private func showPreview(_ entry: FolderEntry) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            if case .video(let item) = entry.content, sources[item.ref] == nil {
                try? await Task.sleep(for: Self.detailDelay)
                guard !Task.isCancelled else { return }
                if let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
                   let first = try? await provider.fullDetail(for: item.ref).mediaSources.first {
                    sources[item.ref] = first
                }
            }
            let content = previewContent(entry)
            guard content != preview.content else { return }
            let image = await Self.image(content.still)
            guard !Task.isCancelled else { return }
            UIView.transition(with: preview, duration: 0.2, options: .transitionCrossDissolve) {
                self.preview.show(content, image: image)
            }
        }
    }

    private func previewContent(_ entry: FolderEntry) -> FolderPreviewView.Content {
        var content = FolderPreviewView.Content(title: entry.title)
        switch entry.content {
        case .folder(_, let childCount):
            content.lines = [childCount.map(Self.itemCount)].compactMap { $0 }
        case .video(let item):
            content.glyph = "film"
            content.still = item.artwork.thumbnail ?? item.artwork.backdrop ?? item.artwork.poster
            let source = sources[item.ref]
            let format = source.map { ($0.qualityBadges() + [$0.container?.uppercased()].compactMap { $0 }).joined(separator: " · ") }
            content.lines = [
                [item.runtime.map { FolderRowDetail.length($0) }, format].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " · "),
                item.isInProgress ? item.runtime.map { String(localized: "\(FolderRowDetail.length($0 - item.userState.viewOffset)) left") }
                    : (item.isWatched ? String(localized: "Watched") : nil)
            ].compactMap { $0 }.filter { !$0.isEmpty }
            content.progress = item.watchProgress.flatMap { $0 > 0 && $0 < 1 ? $0 : nil }
            content.path = source?.fileName
        case .photo(let photo):
            content.glyph = "photo"
            content.still = photo.thumbnail
        }
        return content
    }

    private static func image(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return await ImageCacheManager.shared.image(for: url, quality: .thumb)
    }

    private static func itemCount(_ count: Int) -> String { String(localized: "\(count) items") }

    // MARK: - Actions

    private func play(_ item: MediaItem, fromBeginning: Bool) {
        ProviderPlayer.play(item, fromBeginning: fromBeginning, from: self) { [weak self] in
            self?.refresh(item.ref)
        }
    }

    /// Re-reads one video after the player closes, so its row and preview show the new progress.
    private func refresh(_ ref: MediaItemRef) {
        guard let provider = MediaProviderRegistry.shared.provider(for: ref.providerID) else { return }
        Task { [weak self] in
            guard let detail = try? await provider.fullDetail(for: ref), let self else { return }
            listing.replace(detail.item)
            applySnapshot(reconfigure: [.entry(ref)])
            if focusedRef == ref, let entry = entry(ref) { showPreview(entry) }
        }
    }

    /// Opens the viewer on `photo`, paging through the folder's photos.
    private func openPhoto(_ photo: PhotoItem) {
        let source = listing.source
        let photos = PhotoListing(folder: listing.folder) {
            guard let (provider, library) = source(), let photoProvider = provider as? any PhotoProvider else { return nil }
            return (photoProvider, library)
        }
        Task { [weak self] in
            await photos.loadFirst()?.value
            guard let self, presentedViewController == nil else { return }
            if let index = photos.media.firstIndex(where: { $0.ref == photo.ref }) {
                present(PhotoViewerViewController(listing: photos, index: index), animated: true)
                return
            }
            // Not in the photo listing: show just this photo rather than the wrong one.
            guard let (_, library) = source() else { return }
            let single = PhotoListing(folder: nil) { (FixedPhotoProvider(items: [photo]), library) }
            await single.loadFirst()?.value
            guard presentedViewController == nil, !single.media.isEmpty else { return }
            present(PhotoViewerViewController(listing: single, index: 0), animated: true)
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, presentedViewController == nil,
              let path = TileLongPress.focusedCell(in: collectionView),
              let entry = entry(at: path), case .video(let item) = entry.content,
              let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
              let cell = collectionView.cellForItem(at: path) else { return }
        let ref = item.ref
        var marks: [TileMenuAction] = []
        if !item.isWatched || item.watchProgress != nil {
            marks.append(TileMenuAction(title: "Mark as Watched", systemImage: "eye.fill") {
                Self.changeOnServer { try await provider.markPlayed(ref) }
            })
        }
        if item.isWatched {
            marks.append(TileMenuAction(title: "Mark as Unwatched", systemImage: "eye.slash.fill") {
                Self.changeOnServer { try await provider.markUnplayed(ref) }
            })
        }
        let tileFrame = cell.convert(cell.bounds, to: nil)
        var first = [TileMenuAction(title: "Play from Beginning", systemImage: "arrow.counterclockwise") {
            [weak self] in self?.play(item, fromBeginning: true)
        }]
        if PlaylistMenus.canAdd(item, provider: provider, isVideoFile: true) {
            first.append(TileMenuAction(title: "Add to Playlist", systemImage: "text.badge.plus") { [weak self] in
                guard let self else { return }
                PlaylistMenus.presentAddToPlaylist(for: item, from: self, sourceFrame: tileFrame)
            })
        }
        present(TileMenuPopupViewController(sections: [first, marks], sourceFrame: tileFrame), animated: false)
    }

    /// Posts `.plexDataNeedsRefresh` after the server call, failed or not, so the page repaints from the server.
    private static func changeOnServer(_ change: @escaping () async throws -> Void) {
        Task { @MainActor in
            try? await change()
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
        }
    }
}

// MARK: - Header

/// The library name over the folder name, clear of the shell's pill, with
/// optional Shuffle and View buttons on the trailing edge.
private final class FolderHeaderView: UICollectionReusableView {
    private static let breadcrumbFont = UIFont.systemFont(ofSize: 29, weight: .regular)
    private static let titleFont = UIFont.systemFont(ofSize: 48, weight: .bold)
    private static let bottomGap: CGFloat = 24

    static func height(hasBreadcrumb: Bool) -> CGFloat {
        ShellPillMetrics.contentClearance + (hasBreadcrumb ? ceil(breadcrumbFont.lineHeight) : 0)
            + ceil(titleFont.lineHeight) + bottomGap
    }

    private let breadcrumb = UILabel()
    private let title = UILabel()
    private let viewButton = SortButton()
    private let shuffleButton = SortButton()
    private var viewMenu: (() -> UIMenu?)?
    private var onShuffle: (() -> Void)?
    private lazy var viewCenterY = viewButton.centerYAnchor.constraint(equalTo: topAnchor)
    /// Shuffle's trailing edge: beside View while it shows, else the header's edge. Swapped in configure.
    private lazy var shuffleBesideView = shuffleButton.trailingAnchor.constraint(equalTo: viewButton.leadingAnchor,
                                                                                 constant: -16)
    private lazy var shuffleAtEdge = shuffleButton.trailingAnchor.constraint(equalTo: trailingAnchor)

    override init(frame: CGRect) {
        super.init(frame: frame)
        breadcrumb.font = Self.breadcrumbFont
        breadcrumb.textColor = UIColor(white: 1, alpha: 0.6)
        title.font = Self.titleFont
        title.textColor = .white
        [breadcrumb, title].forEach(addSubview)
        shuffleButton.configure(sortName: String(localized: "Shuffle"), symbol: "shuffle")
        shuffleButton.addAction(UIAction { [weak self] _ in self?.onShuffle?() }, for: .primaryActionTriggered)
        for button in [viewButton, shuffleButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        NSLayoutConstraint.activate([
            viewButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            viewCenterY,
            shuffleButton.centerYAnchor.constraint(equalTo: viewButton.centerYAnchor),
            shuffleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            shuffleAtEdge,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(breadcrumb text: String?, title titleText: String, viewMenu: (() -> UIMenu?)?,
                   onShuffle: (() -> Void)? = nil) {
        breadcrumb.text = text
        breadcrumb.isHidden = text == nil
        title.text = titleText
        self.viewMenu = viewMenu
        viewButton.configure(view: .folders, menu: viewMenu?())
        self.onShuffle = onShuffle
        shuffleButton.isHidden = onShuffle == nil
        // Deactivate before activate, so the two are never active together.
        let beside = !viewButton.isHidden
        NSLayoutConstraint.deactivate([beside ? shuffleAtEdge : shuffleBesideView])
        NSLayoutConstraint.activate([beside ? shuffleBesideView : shuffleAtEdge])
        setNeedsLayout()
    }

    // Fresh items on focus: Collections joins once the grid has loaded some.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === viewButton { viewButton.menu = viewMenu?() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The section's inset already puts x 0 on the column.
        var y = ShellPillMetrics.contentClearance
        if !breadcrumb.isHidden {
            breadcrumb.frame = CGRect(x: 0, y: y, width: bounds.width, height: ceil(Self.breadcrumbFont.lineHeight))
            y = breadcrumb.frame.maxY
        }
        // The title stops short of the leftmost visible button.
        let buttonsLeft = [shuffleButton, viewButton].filter { !$0.isHidden }.map(\.frame.minX).min()
        let titleWidth = buttonsLeft.map { $0 - 24 } ?? bounds.width
        title.frame = CGRect(x: 0, y: y, width: titleWidth, height: ceil(Self.titleFont.lineHeight))
        viewCenterY.constant = title.frame.midY
    }
}
