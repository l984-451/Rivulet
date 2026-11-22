// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelSidebarView.swift
//  Rivulet
//
//  The Live TV player's channel list, swiped in from the left over the
//  picture: every channel by group (`LiveChannelSections`), each with what is
//  on now, opened on the one playing. A collection view, so an IPTV lineup of
//  thousands builds only the rows on screen.
//

import UIKit

final class LiveChannelSidebarView: UIView {

    enum Metrics {
        static let width: CGFloat = 660
        static let inset: CGFloat = 40
        static let radius: CGFloat = 40
        static let rowHeight: CGFloat = 104
        static let headerHeight: CGFloat = 64
        static let contentInset: CGFloat = 20
    }

    private nonisolated struct Item: Hashable, Sendable {
        let section: Int
        let channelId: String
    }

    /// Select on a row: the channel to play.
    var onSelect: ((UnifiedChannel) -> Void)?
    /// Left (click or swipe) asks to close; Menu goes through the player's funnel.
    var onClose: (() -> Void)?

    private let sections: [LiveChannelSections.Section]
    private let currentChannelId: String?
    private let programProvider: @MainActor (UnifiedChannel) -> UnifiedProgram?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var closeSwipe: DirectionalInputBinding?
    private var didScrollToCurrent = false

    init(sections: [LiveChannelSections.Section],
         currentChannelId: String?,
         programProvider: @escaping @MainActor (UnifiedChannel) -> UnifiedProgram?) {
        self.sections = sections
        self.currentChannelId = currentChannelId
        self.programProvider = programProvider
        super.init(frame: .zero)

        let glass = makePaneGlass(cornerRadius: Metrics.radius)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = true
        collectionView.layer.cornerRadius = Metrics.radius
        collectionView.layer.cornerCurve = .continuous
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.contentInset = UIEdgeInsets(top: Metrics.contentInset, left: 0,
                                                   bottom: Metrics.contentInset, right: 0)
        collectionView.delegate = self
        configureDataSource()

        [glass, collectionView].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                $0.topAnchor.constraint(equalTo: topAnchor),
                $0.bottomAnchor.constraint(equalTo: bottomAnchor),
                $0.leadingAnchor.constraint(equalTo: leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        // The swipe twin of the Left click below: a one-column list has no
        // Left move of its own, so the swipe is never the focus engine's.
        closeSwipe = DirectionalInputBinding(
            gatedSwipesOn: self, directions: [.left],
            shouldHandle: { _ in true },
            onSwipe: { [weak self] _ in self?.onClose?() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var currentIndexPath: IndexPath? {
        guard let currentChannelId else { return nil }
        for (index, section) in sections.enumerated() {
            if let row = section.channels.firstIndex(where: { $0.id == currentChannelId }) {
                return IndexPath(item: row, section: index)
            }
        }
        return nil
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            let row = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                             heightDimension: .absolute(Metrics.rowHeight))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: row,
                                                         subitems: [NSCollectionLayoutItem(layoutSize: row)])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 4
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Metrics.contentInset,
                                                            bottom: 16, trailing: Metrics.contentInset)
            if self?.sections[safe: index]?.title != nil {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                       heightDimension: .absolute(Metrics.headerHeight)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                section.boundarySupplementaryItems = [header]
            }
            return section
        }
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<LiveChannelSidebarCell, Item> { [weak self] cell, _, item in
            guard let self, let channel = self.sections[safe: item.section]?.channels
                .first(where: { $0.id == item.channelId }) else { return }
            cell.configure(channel: channel, program: self.programProvider(channel),
                           isCurrent: channel.id == self.currentChannelId)
        }
        let header = UICollectionView.SupplementaryRegistration<LiveChannelSidebarHeader>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            view.label.text = self?.sections[safe: indexPath.section]?.title
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, item in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        for (index, section) in sections.enumerated() {
            snapshot.appendSections([index])
            snapshot.appendItems(section.channels.map { Item(section: index, channelId: $0.id) })
        }
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    /// Opens on the playing channel, placed before the first frame so the
    /// preferred focus below names a cell that exists.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didScrollToCurrent, collectionView.bounds.height > 0 else { return }
        didScrollToCurrent = true
        collectionView.layoutIfNeeded()
        if let currentIndexPath {
            collectionView.scrollToItem(at: currentIndexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let currentIndexPath, let cell = collectionView.cellForItem(at: currentIndexPath) { return [cell] }
        return [collectionView]
    }

    /// The programme on each visible row, as the guide's clock rolls over.
    func refreshPrograms() {
        var snapshot = dataSource.snapshot()
        let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        guard !visible.isEmpty else { return }
        snapshot.reconfigureItems(visible)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Reaches here only when the focus engine had no Left move to make.
        if presses.contains(where: { $0.type == .leftArrow }) {
            onClose?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

extension LiveChannelSidebarView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              let channel = sections[safe: item.section]?.channels.first(where: { $0.id == item.channelId })
        else { return }
        onSelect?(channel)
    }
}

// MARK: - Header

private final class LiveChannelSidebarHeader: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 25, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.6)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Row

/// One channel: logo, "504 · Fox Footy", the programme on now and how far
/// through it the broadcast is. The playing channel carries a speaker glyph.
private final class LiveChannelSidebarCell: UICollectionViewCell {

    private let plate = UIView()
    private let logo = UIImageView()
    private let channelLine = UILabel()
    private let programLine = UILabel()
    private let playingGlyph = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    private let track = UIView()
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint?
    private var isCurrent = false
    private var logoURL: URL?
    private var imageTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.layer.cornerRadius = 20
        plate.layer.cornerCurve = .continuous
        plate.layer.borderWidth = 1

        logo.contentMode = .scaleAspectFit
        logo.clipsToBounds = true
        logo.layer.cornerRadius = 10
        logo.layer.cornerCurve = .continuous
        logo.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        channelLine.font = .systemFont(ofSize: 21, weight: .medium)
        channelLine.textColor = UIColor.white.withAlphaComponent(0.6)
        programLine.font = .systemFont(ofSize: 27, weight: .semibold)
        programLine.textColor = .white
        playingGlyph.tintColor = .white
        playingGlyph.contentMode = .scaleAspectFit
        playingGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

        track.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        track.layer.cornerRadius = 2
        fill.backgroundColor = .white
        fill.layer.cornerRadius = 2
        track.addSubview(fill)

        [plate, logo, channelLine, programLine, playingGlyph, track].forEach {
            contentView.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        fill.translatesAutoresizingMaskIntoConstraints = false
        let fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        self.fillWidth = fillWidth
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: contentView.topAnchor),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            logo.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            logo.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 120),
            logo.heightAnchor.constraint(equalToConstant: 68),

            channelLine.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 20),
            channelLine.trailingAnchor.constraint(lessThanOrEqualTo: playingGlyph.leadingAnchor, constant: -12),
            channelLine.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            programLine.leadingAnchor.constraint(equalTo: channelLine.leadingAnchor),
            programLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            programLine.topAnchor.constraint(equalTo: channelLine.bottomAnchor, constant: 2),

            playingGlyph.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            playingGlyph.centerYAnchor.constraint(equalTo: channelLine.centerYAnchor),

            track.leadingAnchor.constraint(equalTo: channelLine.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            track.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])
        applyFocus(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        logo.image = nil
        logoURL = nil
    }

    func configure(channel: UnifiedChannel, program: UnifiedProgram?, isCurrent: Bool) {
        self.isCurrent = isCurrent
        channelLine.text = [channel.channelNumber.map(String.init), channel.name]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        programLine.text = program?.title ?? String(localized: "No guide data")
        programLine.textColor = program == nil ? UIColor.white.withAlphaComponent(0.6) : .white
        playingGlyph.isHidden = !isCurrent

        if let program, program.endTime > program.startTime {
            let total = program.endTime.timeIntervalSince(program.startTime)
            let fraction = min(max(Date().timeIntervalSince(program.startTime) / total, 0), 1)
            track.isHidden = false
            fillWidth?.isActive = false
            fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: CGFloat(max(fraction, 0.001)))
            fillWidth?.isActive = true
        } else {
            track.isHidden = true
        }

        loadLogo(channel.logoURL)
        applyFocus(isFocused)
    }

    private func loadLogo(_ url: URL?) {
        guard url != logoURL else { return }
        imageTask?.cancel()
        logoURL = url
        logo.image = nil
        guard let url else { return }
        imageTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled, self.logoURL == url else { return }
            self.logo.image = image?.legibleChannelLogo
        }
    }

    private func applyFocus(_ focused: Bool) {
        plate.backgroundColor = UIColor.white.withAlphaComponent(focused ? 0.18 : (isCurrent ? 0.08 : 0))
        plate.layer.borderColor = UIColor.white.withAlphaComponent(focused ? 0.25 : (isCurrent ? 0.08 : 0)).cgColor
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.applyFocus(focused) }
    }
}
