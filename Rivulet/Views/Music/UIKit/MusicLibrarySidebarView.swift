// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicLibrarySidebarView.swift
//  Rivulet
//
//  The Music library's category list. No panel behind it: rows on an 80pt
//  pitch whose capsule spans x 40..370. Selection follows focus. Measured
//  from Apple Music on tvOS 26.
//

import UIKit

@MainActor
final class MusicLibrarySidebarView: UIView, UICollectionViewDelegate {
    static let width: CGFloat = 400

    /// Fixed sections, so a destination's index path never shifts when the
    /// Now Playing row comes or goes.
    private nonisolated enum Section: Int, Sendable { case nowPlaying, categories, genresHeader, genres }
    private nonisolated enum Row: Hashable, Sendable {
        case nowPlaying
        case destination(MusicLibraryDestination)
        case genresHeader
    }

    /// Focus moved to another destination row.
    var onSelect: ((MusicLibraryDestination) -> Void)?
    var onNowPlaying: (() -> Void)?
    private(set) var selected: MusicLibraryDestination = .recentlyAdded

    private var genres: [MusicGenre] = []
    private var showsNowPlaying = false
    private lazy var collectionView = SidebarCollectionView(frame: bounds, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!

    override init(frame: CGRect) {
        super.init(frame: frame)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        // The first row's capsule starts 7pt into its 80pt row, below the shell's collapsed pill.
        collectionView.contentInset = UIEdgeInsets(top: max(MusicMetrics.top, ShellPillMetrics.contentClearance) - 7, left: 0, bottom: 60, right: 0)
        // Entry from the grid resolves through the collection, which aims at the selected row.
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.delegate = self
        addSubview(collectionView)

        let row = rowRegistration, header = headerRegistration
        dataSource = UICollectionViewDiffableDataSource<Section, Row>(collectionView: collectionView) {
            collectionView, indexPath, item in
            item == .genresHeader
                ? collectionView.dequeueConfiguredReusableCell(using: header, for: indexPath, item: item)
                : collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
        }
        applySnapshot()
        aimAtSelected()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    func setGenres(_ genres: [MusicGenre]) {
        self.genres = genres
        // A genre the server no longer lists cannot stay selected.
        if case .genre(let genre) = selected, !genres.contains(genre) { select(.recentlyAdded) }
        applySnapshot()
    }

    func setNowPlayingVisible(_ visible: Bool) {
        guard visible != showsNowPlaying else { return }
        showsNowPlaying = visible
        // Leaving while it holds focus: point the engine at the selected row first.
        if !visible { aimAtSelected() }
        applySnapshot()
        if !visible { setNeedsFocusUpdate() }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.nowPlaying, .categories, .genresHeader, .genres])
        if showsNowPlaying { snapshot.appendItems([.nowPlaying], toSection: .nowPlaying) }
        snapshot.appendItems(MusicLibraryDestination.categories.map(Row.destination), toSection: .categories)
        if !genres.isEmpty {
            snapshot.appendItems([.genresHeader], toSection: .genresHeader)
            snapshot.appendItems(genres.map { .destination(.genre($0)) }, toSection: .genres)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { index, _ in
            // The header row holds the hairline and the "Genres" label between the two lists.
            let height: CGFloat = Section(rawValue: index) == .genresHeader ? 136 : 80
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            // Rows are exactly the capsule's width, x 40..370: the shell's edge catcher sits at
            // x 0..2 and a row over it would stop Left from reaching it.
            section.contentInsetsReference = .none
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 40, bottom: 0, trailing: 30)
            return section
        }
    }

    private lazy var rowRegistration = UICollectionView.CellRegistration<MusicSidebarRowCell, Row> {
        [unowned self] cell, _, row in
        switch row {
        case .nowPlaying: cell.configure(title: String(localized: "Now Playing"), symbol: "waveform")
        case .destination(let destination): cell.configure(title: destination.title, symbol: destination.symbol)
        case .genresHeader: break
        }
        cell.isSelectedRow = row == .destination(selected)
        cell.onFocused = { [weak self] in
            if case .destination(let destination) = row { self?.select(destination) }
        }
    }

    private lazy var headerRegistration = UICollectionView.CellRegistration<MusicSidebarGenresHeaderCell, Row> { _, _, _ in }

    // MARK: - Selection and focus

    /// Selection follows focus: the browse pane swaps as focus walks the rows.
    private func select(_ destination: MusicLibraryDestination) {
        guard destination != selected else { return }
        let previous = selected
        selected = destination
        for target in [previous, destination] {
            guard let indexPath = dataSource.indexPath(for: .destination(target)) else { continue }
            (collectionView.cellForItem(at: indexPath) as? MusicSidebarRowCell)?.isSelectedRow = target == destination
        }
        onSelect?(destination)
    }

    private func aimAtSelected() {
        collectionView.preferredFocusIndexPath = dataSource.indexPath(for: .destination(selected))
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [collectionView] }

    // Focus that left comes back to the selected row, even if the Now Playing row held it last.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView?.isDescendant(of: collectionView) != true { aimAtSelected() }
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .genresHeader
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if dataSource.itemIdentifier(for: indexPath) == .nowPlaying { onNowPlaying?() }
    }
}

// MARK: - Row cell

/// Idle: no background. Selected: a translucent 330x66 capsule. Focused: a
/// near-white capsule 4pt larger on each side, with dark content.
@MainActor
final class MusicSidebarRowCell: UICollectionViewCell {
    var onFocused: (() -> Void)?
    var isSelectedRow = false {
        didSet { applyAppearance() }
    }

    private let capsule = UIView()
    private let glyph = UIImageView()
    private let label = MusicChrome.label(size: 29, weight: .medium)
    private var showsFocus = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        capsule.layer.shadowColor = UIColor.black.cgColor
        capsule.layer.shadowRadius = 14
        capsule.layer.shadowOffset = CGSize(width: 0, height: 10)
        capsule.layer.shadowOpacity = 0
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 27, weight: .semibold)
        [capsule, glyph, label].forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, symbol: String?) {
        label.text = title
        glyph.image = symbol.flatMap { UIImage(systemName: $0) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let size = showsFocus ? CGSize(width: bounds.width + 8, height: 74) : CGSize(width: bounds.width, height: 66)
        capsule.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                               width: size.width, height: size.height)
        capsule.layer.cornerRadius = size.height / 2
        capsule.layer.shadowPath = UIBezierPath(roundedRect: capsule.bounds, cornerRadius: size.height / 2).cgPath
        // Screen x: glyph centred on 81, label ink from 123; genre rows have no glyph and start at 61.
        glyph.frame = CGRect(x: 21, y: 0, width: 40, height: bounds.height)
        let labelX: CGFloat = glyph.image == nil ? 20 : 82
        label.frame = CGRect(x: labelX, y: 0, width: bounds.width - labelX - 20, height: bounds.height)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.showsFocus = focused
            self.applyAppearance()
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        if focused { onFocused?() }
    }

    // The label keeps one weight in every state, as Apple's does.
    private func applyAppearance() {
        capsule.backgroundColor = showsFocus ? UIColor(white: 0.93, alpha: 1)
            : (isSelectedRow ? UIColor(white: 1, alpha: 0.12) : .clear)
        capsule.layer.shadowOpacity = showsFocus ? 0.3 : 0
        let content = showsFocus ? UIColor(white: 0.12, alpha: 1) : UIColor.white
        glyph.tintColor = content
        label.textColor = content
    }
}

// MARK: - Genres header

/// The hairline under the categories and the grey "Genres" label. Never focusable.
@MainActor
final class MusicSidebarGenresHeaderCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let divider = UIView(frame: CGRect(x: 0, y: 33, width: bounds.width, height: 1))
        divider.autoresizingMask = [.flexibleWidth]
        divider.backgroundColor = UIColor(white: 1, alpha: 0.12)
        let label = MusicChrome.label(size: 25, weight: .medium, color: MusicMetrics.secondary)
        label.text = String(localized: "Genres")
        label.frame = CGRect(x: 20, y: 96, width: bounds.width - 40, height: 32)
        label.autoresizingMask = [.flexibleWidth]
        [divider, label].forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
