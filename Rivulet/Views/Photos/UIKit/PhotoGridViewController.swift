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
final class PhotoGridViewController: UIViewController {
    private enum Section: Int, CaseIterable { case folders, media }
    private static let headerKind = "PhotoGridHeader"
    /// Photos keep the Normal grid: their cells size themselves once, and the controller outlives a
    /// Display Size change in its tab, so following the setting would leave stale tiles.
    private static let columns = DisplaySize.normal.posterColumns

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

        listing.onChange = { [weak self] in self?.apply($0) }
        listing.loadFirst()
    }

    private func makeLayout() -> UICollectionViewLayout {
        let tile = MediaRowMetrics.square(columns: Self.columns)
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
            kind = .error(message: "This library could not be loaded.")
        } else {
            kind = .empty(message: "No photos here.")
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
        return [stateView.isHidden ? collectionView : stateView]
    }

    // MARK: - Viewer

    private func openViewer(at index: Int) {
        let viewer = PhotoViewerViewController(listing: listing, index: index)
        viewer.onClose = { [weak self] index in
            guard let self else { return }
            // The grid may have grown under the viewer; the cell has to exist to take focus.
            let path = IndexPath(item: index, section: Section.media.rawValue)
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
        header.label.text = title
        return header
    }
}

// MARK: - UICollectionViewDelegate

extension PhotoGridViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let item = item(at: indexPath)
        if item.kind == .folder { onOpenFolder?(item) } else { openViewer(at: indexPath.item) }
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

/// The page title, clear of the shell's pill, on the content margin.
private final class PhotoGridHeaderView: UICollectionReusableView {
    static let height = ShellPillMetrics.contentClearance + 90
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 48, weight: .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MediaRowMetrics.rowLeading),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MediaRowMetrics.rowTrailing),
            label.topAnchor.constraint(equalTo: topAnchor, constant: ShellPillMetrics.contentClearance)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
