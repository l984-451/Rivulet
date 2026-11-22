// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelSidebarView.swift
//  Rivulet
//
//  The Live TV player's channel list, swiped in from the left over the
//  picture: every channel by group (`LiveChannelSections`), each with what is
//  on now, opened on the one playing. A column browser, as in Music: Left
//  brings in the groups (moving through them jumps the list), Right brings in
//  the focused channel's schedule. The focused row also says what is next.
//  Collection views, so an IPTV lineup of thousands builds only the rows on
//  screen.
//

import UIKit

final class LiveChannelSidebarView: UIView {

    enum Metrics {
        /// The channel column, and the whole panel while no other column is up.
        static let width: CGFloat = 660
        static let groupsWidth: CGFloat = 320
        static let scheduleWidth: CGFloat = 440
        static let inset: CGFloat = 40
        static let radius: CGFloat = 40
        static let rowHeight: CGFloat = 104
        static let rowSpacing: CGFloat = 4
        /// What the focused row grows by to say what is next.
        static let nextLineHeight: CGFloat = 34
        static let groupRowHeight: CGFloat = 66
        /// One line of text; the programme on now fits its progress bar under it.
        static let scheduleRowHeight: CGFloat = 58
        static let headerHeight: CGFloat = 64
        static let contentInset: CGFloat = 20
        /// Concentric with the panel: rows sit `contentInset` inside it.
        static let rowRadius: CGFloat = radius - contentInset
        /// Room kept between a focused row and the list's top or bottom edge.
        static let focusMargin: CGFloat = 24
        /// How many programmes the schedule lists, the one on now included.
        static let scheduleLength = 12
    }

    private nonisolated struct Item: Hashable, Sendable {
        let section: Int
        let channelId: String
    }

    /// Select on a row: the channel to play.
    var onSelect: ((UnifiedChannel) -> Void)?
    /// Select on a programme in the schedule, with its frame in the window.
    var onProgramSelected: ((UnifiedProgram, UnifiedChannel, CGRect) -> Void)?
    /// Left from the groups (or from the channels of a lineup without groups)
    /// asks to close; Menu goes through the player's funnel (`handleMenu`).
    var onClose: (() -> Void)?

    private let sections: [LiveChannelSections.Section]
    private let currentChannelId: String?
    private let programProvider: @MainActor (UnifiedChannel) -> UnifiedProgram?
    /// Every programme the guide holds for a channel.
    private let guideProvider: @MainActor (UnifiedChannel) -> [UnifiedProgram]

    private var channels: UICollectionView!
    private var groups: UICollectionView!
    private var schedule: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var groupsDataSource: UICollectionViewDiffableDataSource<Int, Int>!
    private var scheduleDataSource: UICollectionViewDiffableDataSource<Int, Int>!
    private var focusScroll: NativeFocusScrollCoordinator!
    private let groupsDivider = UIView()
    private let scheduleColumn = UIView()
    private let scheduleTitle = UILabel()
    private var widthConstraint: NSLayoutConstraint!
    private var channelsLeading: NSLayoutConstraint!

    /// Hands Right from a group to that group's entry row instead of the row beside it.
    private let groupsExit = UIFocusGuide()
    /// Right from a channel into its schedule, onto the programme on now.
    private let scheduleEntry = UIFocusGuide()
    /// Left from the schedule back to the channel it belongs to.
    private let scheduleExit = UIFocusGuide()
    private var swipes: DirectionalInputBinding?

    private var didScrollToCurrent = false
    private var showsGroups = false
    private var showsSchedule = false
    /// Where Right or Select from the focused group lands.
    private var groupEntry: IndexPath?
    /// The channel the schedule column lists, and what it lists.
    private var scheduleChannel: IndexPath?
    private var schedulePrograms: [UnifiedProgram] = []
    /// The focused row, grown to say what is next. nil when it has nothing next.
    private var expandedRow: IndexPath?
    /// A one-shot target for the next focus update.
    private weak var focusRedirect: UIView?

    /// One section is the whole lineup with no group to move between.
    private var hasGroups: Bool { sections.count > 1 }

    init(sections: [LiveChannelSections.Section],
         currentChannelId: String?,
         programProvider: @escaping @MainActor (UnifiedChannel) -> UnifiedProgram?,
         guideProvider: @escaping @MainActor (UnifiedChannel) -> [UnifiedProgram]) {
        self.sections = sections
        self.currentChannelId = currentChannelId
        self.programProvider = programProvider
        self.guideProvider = guideProvider
        super.init(frame: .zero)
        // The panel clips every column to one rounded box.
        layer.cornerRadius = Metrics.radius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let glass = makePaneGlass(cornerRadius: Metrics.radius)
        channels = makeCollectionView(layout: makeChannelsLayout())
        focusScroll = NativeFocusScrollCoordinator(scrollView: channels)
        configureChannelsDataSource()
        groups = makeCollectionView(layout: Self.listLayout(rowHeight: Metrics.groupRowHeight))
        configureGroupsDataSource()
        schedule = makeCollectionView(layout: Self.listLayout(rowHeight: Metrics.scheduleRowHeight))
        configureScheduleDataSource()

        groupsDivider.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        scheduleTitle.font = .systemFont(ofSize: 25, weight: .semibold)
        scheduleTitle.textColor = UIColor.white.withAlphaComponent(0.6)
        let scheduleDivider = UIView()
        scheduleDivider.backgroundColor = groupsDivider.backgroundColor
        [scheduleDivider, scheduleTitle, schedule].forEach {
            scheduleColumn.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        // Away until asked for: hidden, so neither focusable nor in the focus
        // engine's occlusion test.
        [groups, groupsDivider, scheduleColumn].forEach { $0.isHidden = true; $0.alpha = 0 }

        // The side columns sit below the channels: while the columns slide,
        // neither can cover a channel row and make it unfocusable.
        [glass, groups, groupsDivider, scheduleColumn, channels].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        widthConstraint = widthAnchor.constraint(equalToConstant: Metrics.width)
        channelsLeading = channels.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            widthConstraint,
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),

            groups.topAnchor.constraint(equalTo: topAnchor),
            groups.bottomAnchor.constraint(equalTo: bottomAnchor),
            groups.leadingAnchor.constraint(equalTo: leadingAnchor),
            groups.widthAnchor.constraint(equalToConstant: Metrics.groupsWidth),
            groupsDivider.leadingAnchor.constraint(equalTo: groups.trailingAnchor),
            groupsDivider.widthAnchor.constraint(equalToConstant: 1),
            groupsDivider.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.radius),
            groupsDivider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.radius),

            channelsLeading,
            channels.topAnchor.constraint(equalTo: topAnchor),
            channels.bottomAnchor.constraint(equalTo: bottomAnchor),
            channels.widthAnchor.constraint(equalToConstant: Metrics.width),

            scheduleColumn.leadingAnchor.constraint(equalTo: channels.trailingAnchor),
            scheduleColumn.topAnchor.constraint(equalTo: topAnchor),
            scheduleColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            scheduleColumn.widthAnchor.constraint(equalToConstant: Metrics.scheduleWidth),
            scheduleDivider.leadingAnchor.constraint(equalTo: scheduleColumn.leadingAnchor),
            scheduleDivider.widthAnchor.constraint(equalToConstant: 1),
            scheduleDivider.topAnchor.constraint(equalTo: scheduleColumn.topAnchor, constant: Metrics.radius),
            scheduleDivider.bottomAnchor.constraint(equalTo: scheduleColumn.bottomAnchor, constant: -Metrics.radius),
            scheduleTitle.leadingAnchor.constraint(equalTo: scheduleColumn.leadingAnchor, constant: 2 * Metrics.contentInset),
            scheduleTitle.trailingAnchor.constraint(lessThanOrEqualTo: scheduleColumn.trailingAnchor,
                                                    constant: -2 * Metrics.contentInset),
            // Level with the channel list's group name and first row.
            scheduleTitle.bottomAnchor.constraint(equalTo: scheduleColumn.topAnchor,
                                                  constant: Metrics.contentInset + Metrics.headerHeight - 10),
            schedule.topAnchor.constraint(equalTo: scheduleColumn.topAnchor, constant: Metrics.headerHeight),
            schedule.bottomAnchor.constraint(equalTo: scheduleColumn.bottomAnchor),
            schedule.leadingAnchor.constraint(equalTo: scheduleColumn.leadingAnchor),
            schedule.trailingAnchor.constraint(equalTo: scheduleColumn.trailingAnchor),
        ])

        // Each guide sits in the gap between two columns, so a move across
        // the gap meets it before any row. Enabled only while focus is on the
        // side it leads away from.
        for (guide, anchor) in [(groupsExit, channels.leadingAnchor),
                                (scheduleEntry, channels.trailingAnchor),
                                (scheduleExit, scheduleColumn.leadingAnchor)] {
            addLayoutGuide(guide)
            guide.isEnabled = false
            NSLayoutConstraint.activate([
                guide.topAnchor.constraint(equalTo: topAnchor),
                guide.bottomAnchor.constraint(equalTo: bottomAnchor),
                guide.widthAnchor.constraint(equalToConstant: Metrics.contentInset),
                guide === scheduleEntry
                    ? guide.trailingAnchor.constraint(equalTo: anchor)
                    : guide.leadingAnchor.constraint(equalTo: anchor),
            ])
        }
        groupsExit.preferredFocusEnvironments = [channels]
        scheduleEntry.preferredFocusEnvironments = [schedule]

        // The swipe twins of Left and Right below, claimed only where the
        // focus engine has no move of its own to make.
        swipes = DirectionalInputBinding(
            gatedSwipesOn: self, directions: [.left, .right],
            shouldHandle: { [weak self] direction in
                guard let self else { return false }
                switch direction {
                case .left: return !self.focusIsIn(self.schedule)
                case .right: return self.focusIsIn(self.channels) && !self.showsSchedule
                default: return false
                }
            },
            onSwipe: { [weak self] direction in
                direction == .left ? self?.handleLeft() : self?.handleRight()
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeCollectionView(layout: UICollectionViewLayout) -> UICollectionView {
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.remembersLastFocusedIndexPath = false
        view.contentInset = UIEdgeInsets(top: Metrics.contentInset, left: 0, bottom: Metrics.contentInset, right: 0)
        view.delegate = self
        return view
    }

    private var currentIndexPath: IndexPath? {
        guard let currentChannelId else { return nil }
        for (index, section) in sections.enumerated() {
            if let row = section.channels.firstIndex(where: { $0.id == currentChannelId }) {
                return IndexPath(item: row, section: index)
            }
        }
        return nil
    }

    private func channel(at indexPath: IndexPath) -> UnifiedChannel? {
        sections[safe: indexPath.section]?.channels[safe: indexPath.item]
    }

    private func nextProgram(on channel: UnifiedChannel) -> UnifiedProgram? {
        LiveSchedule.next(in: guideProvider(channel), now: Date())
    }

    private func headerHeight(of section: Int) -> CGFloat {
        sections[safe: section]?.title == nil ? 0 : Metrics.headerHeight
    }

    private var focusedView: UIView? { UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView }

    private func focusIsIn(_ view: UIView) -> Bool { focusedView?.isDescendant(of: view) == true }

    /// The channel row holding focus, if one does.
    private var focusedChannelRow: IndexPath? {
        let focused = focusedView
        return channels.visibleCells.first { focused?.isDescendant(of: $0) == true }
            .flatMap { channels.indexPath(for: $0) }
    }

    // MARK: Layout

    private func makeChannelsLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, sectionEnvironment in
            guard let self, let channels = self.sections[safe: index]?.channels else { return nil }
            // Rows laid out by hand, so the focused one can grow by a line.
            let grown = self.expandedRow?.section == index ? self.expandedRow?.item : nil
            // The column less the section's side insets. The custom group's own
            // environment reports the whole column, so rows sized from it ran
            // 2 × contentInset past the right edge and were clipped there.
            let width = sectionEnvironment.container.effectiveContentSize.width - 2 * Metrics.contentInset
            let height = CGFloat(channels.count) * (Metrics.rowHeight + Metrics.rowSpacing) - Metrics.rowSpacing
                + (grown == nil ? 0 : Metrics.nextLineHeight)
            let group = NSCollectionLayoutGroup.custom(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                   heightDimension: .absolute(max(height, 1)))
            ) { _ in
                var y: CGFloat = 0
                return channels.indices.map { item in
                    let rowHeight = Metrics.rowHeight + (item == grown ? Metrics.nextLineHeight : 0)
                    defer { y += rowHeight + Metrics.rowSpacing }
                    return NSCollectionLayoutGroupCustomItem(frame: CGRect(x: 0, y: y, width: width, height: rowHeight))
                }
            }
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Metrics.contentInset,
                                                            bottom: 16, trailing: Metrics.contentInset)
            if self.sections[safe: index]?.title != nil {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                       heightDimension: .absolute(Metrics.headerHeight)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                // The group's name stays at the top while its channels scroll.
                header.pinToVisibleBounds = true
                header.zIndex = 2
                section.boundarySupplementaryItems = [header]
            }
            return section
        }
    }

    private static func listLayout(rowHeight: CGFloat) -> UICollectionViewCompositionalLayout {
        let row = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(rowHeight))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: row, subitems: [NSCollectionLayoutItem(layoutSize: row)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Metrics.rowSpacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Metrics.contentInset,
                                                        bottom: 0, trailing: Metrics.contentInset)
        return UICollectionViewCompositionalLayout(section: section)
    }

    // MARK: Data

    private func configureChannelsDataSource() {
        let cell = UICollectionView.CellRegistration<LiveChannelSidebarCell, Item> { [weak self] cell, indexPath, _ in
            guard let self, let channel = self.channel(at: indexPath) else { return }
            cell.configure(channel: channel, program: self.programProvider(channel),
                           next: self.nextProgram(on: channel), isCurrent: channel.id == self.currentChannelId)
        }
        let header = UICollectionView.SupplementaryRegistration<LiveChannelSidebarHeader>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            view.label.text = self?.sections[safe: indexPath.section]?.title
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: channels) { view, indexPath, item in
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

    private func configureGroupsDataSource() {
        let cell = UICollectionView.CellRegistration<LiveChannelGroupCell, Int> { [weak self] cell, _, section in
            guard let self, let group = self.sections[safe: section] else { return }
            cell.configure(title: group.title ?? "", count: group.channels.count,
                           isPlaying: self.currentIndexPath?.section == section)
        }
        groupsDataSource = UICollectionViewDiffableDataSource(collectionView: groups) { view, indexPath, section in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: section)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(hasGroups ? Array(sections.indices) : [])
        groupsDataSource.applySnapshotUsingReloadData(snapshot)
    }

    /// Items are positions in `schedulePrograms`; -1 is the row for a channel
    /// with nothing listed.
    private func configureScheduleDataSource() {
        let cell = UICollectionView.CellRegistration<LiveScheduleCell, Int> { [weak self] cell, _, index in
            cell.configure(program: self?.schedulePrograms[safe: index], now: Date())
        }
        scheduleDataSource = UICollectionViewDiffableDataSource(collectionView: schedule) { view, indexPath, index in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: index)
        }
    }

    private func loadSchedule(for row: IndexPath) {
        guard let channel = channel(at: row) else { return }
        scheduleChannel = row
        scheduleTitle.text = [channel.channelNumber.map(String.init), channel.name]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        schedulePrograms = LiveSchedule.upcoming(in: guideProvider(channel), now: Date(), limit: Metrics.scheduleLength)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(schedulePrograms.isEmpty ? [-1] : Array(schedulePrograms.indices))
        scheduleDataSource.applySnapshotUsingReloadData(snapshot)
        schedule.contentOffset = CGPoint(x: 0, y: -schedule.adjustedContentInset.top)
    }

    /// Opens on the playing channel, placed before the first frame so the
    /// preferred focus below names a cell that exists.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didScrollToCurrent, channels.bounds.height > 0 else { return }
        didScrollToCurrent = true
        channels.layoutIfNeeded()
        if let currentIndexPath {
            channels.scrollToItem(at: currentIndexPath, at: .centeredVertically, animated: false)
            channels.layoutIfNeeded()
        }
        fadeRowsUnderHeaders()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let focusRedirect { return [focusRedirect] }
        if let currentIndexPath, let cell = channels.cellForItem(at: currentIndexPath) { return [cell] }
        return [channels]
    }

    private func moveFocus(to view: UIView) {
        focusRedirect = view
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        focusRedirect = nil
    }

    /// The programmes on each visible row and in the schedule, as the guide's
    /// clock rolls over.
    func refreshPrograms() {
        var snapshot = dataSource.snapshot()
        let visible = channels.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        if !visible.isEmpty {
            snapshot.reconfigureItems(visible)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        if showsSchedule, !focusIsIn(schedule), let scheduleChannel { loadSchedule(for: scheduleChannel) }
    }

    // MARK: Columns

    /// Sizes the panel for the columns that are up and fades the others away.
    private func layoutColumns(duration: TimeInterval) {
        channelsLeading.constant = showsGroups ? Metrics.groupsWidth : 0
        widthConstraint.constant = channelsLeading.constant + Metrics.width
            + (showsSchedule ? Metrics.scheduleWidth : 0)
        let groupViews: [UIView] = [groups, groupsDivider]
        if showsGroups { groupViews.forEach { $0.isHidden = false } }
        if showsSchedule { scheduleColumn.isHidden = false }
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseInOut, animations: {
            groupViews.forEach { $0.alpha = self.showsGroups ? 1 : 0 }
            self.scheduleColumn.alpha = self.showsSchedule ? 1 : 0
            self.superview?.layoutIfNeeded()
        }, completion: { _ in
            if !self.showsGroups { groupViews.forEach { $0.isHidden = true } }
            if !self.showsSchedule { self.scheduleColumn.isHidden = true }
        })
        groupsExit.isEnabled = showsGroups
    }

    /// Left: the schedule goes first, then the groups come in; Left from the
    /// groups, or from a lineup with nothing to group, closes.
    private func handleLeft() {
        if showsSchedule {
            hideSchedule()
        } else if hasGroups, !showsGroups {
            let row = focusedChannelRow
            showGroups(focusing: row?.section ?? currentIndexPath?.section ?? 0, returningTo: row)
        } else {
            onClose?()
        }
    }

    /// Right from a channel: its schedule.
    private func handleRight() {
        guard !showsSchedule, let row = focusedChannelRow else { return }
        showSchedule(for: row)
    }

    /// Menu goes back one column at a time; false when only the channels are
    /// up, so the player closes the list.
    func handleMenu() -> Bool {
        if showsSchedule {
            hideSchedule()
            return true
        }
        if showsGroups {
            let back = groupEntry.flatMap { channels.cellForItem(at: $0) } ?? channels.visibleCells.first
            if let back { moveFocus(to: back) }
            return true
        }
        return false
    }

    // MARK: Groups

    /// `row` is where Right goes straight back to, until another group takes focus.
    private func showGroups(focusing section: Int, returningTo row: IndexPath?) {
        showsGroups = true
        groupEntry = row ?? entry(in: section)
        layoutColumns(duration: 0.3)
        let path = IndexPath(item: section, section: 0)
        groups.layoutIfNeeded()
        groups.scrollToItem(at: path, at: .centeredVertically, animated: false)
        groups.layoutIfNeeded()
        if let cell = groups.cellForItem(at: path) { moveFocus(to: cell) }
    }

    private func hideGroups() {
        guard showsGroups else { return }
        showsGroups = false
        layoutColumns(duration: 0.25)
    }

    /// The row a group is entered on: the playing channel in its own group,
    /// otherwise the group's first channel.
    private func entry(in section: Int) -> IndexPath {
        if let currentIndexPath, currentIndexPath.section == section { return currentIndexPath }
        return IndexPath(item: 0, section: section)
    }

    /// Shows a group's entry row: its first channel at the top under the
    /// group's name, or the playing channel in the middle.
    private func reveal(_ section: Int, animated: Bool) {
        let target = entry(in: section)
        guard let frame = channels.layoutAttributesForItem(at: target)?.frame else { return }
        let offset = target.item == 0
            ? frame.minY - headerHeight(of: section) - channels.adjustedContentInset.top
            : frame.midY - channels.bounds.height / 2
        focusScroll.scroll(to: CGPoint(x: channels.contentOffset.x, y: offset), animated: animated)
        if !animated { channels.layoutIfNeeded() }
    }

    /// Select on a group: straight to its entry row.
    private func enterGroup(_ section: Int) {
        reveal(section, animated: false)
        if let cell = channels.cellForItem(at: entry(in: section)) { moveFocus(to: cell) }
    }

    // MARK: Schedule

    private func showSchedule(for row: IndexPath) {
        loadSchedule(for: row)
        showsSchedule = true
        layoutColumns(duration: 0.3)
        schedule.layoutIfNeeded()
        if let first = schedule.cellForItem(at: IndexPath(item: 0, section: 0)), first.canBecomeFocused {
            moveFocus(to: first)
        }
    }

    /// Back to the channels, onto the one whose schedule it was when focus was in it.
    private func hideSchedule() {
        guard showsSchedule else { return }
        if focusIsIn(schedule), let back = scheduleChannel.flatMap({ channels.cellForItem(at: $0) }) {
            moveFocus(to: back)
        }
        showsSchedule = false
        scheduleEntry.isEnabled = false
        scheduleExit.isEnabled = false
        layoutColumns(duration: 0.25)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let next = context.nextFocusedView
        let inChannels = next?.isDescendant(of: channels) == true
        if showsGroups, inChannels { hideGroups() }
        scheduleEntry.isEnabled = showsSchedule && inChannels
        let inSchedule = next?.isDescendant(of: schedule) == true
        scheduleExit.isEnabled = inSchedule
        if inSchedule, let back = scheduleChannel.flatMap({ channels.cellForItem(at: $0) }) {
            scheduleExit.preferredFocusEnvironments = [back]
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Reaches here only when the focus engine had no move to make.
        if presses.contains(where: { $0.type == .leftArrow }), !focusIsIn(schedule) {
            handleLeft()
            return
        }
        if presses.contains(where: { $0.type == .rightArrow }), focusIsIn(channels) {
            handleRight()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: Focused row

    /// Grows the newly focused row to show what is next, and shrinks the last.
    private func expand(_ row: IndexPath?, with coordinator: UIFocusAnimationCoordinator) {
        let grown = row.flatMap { path in channel(at: path).flatMap(nextProgram(on:)) == nil ? nil : path }
        guard grown != expandedRow else { return }
        expandedRow = grown
        channels.collectionViewLayout.invalidateLayout()
        coordinator.addCoordinatedAnimations { self.channels.layoutIfNeeded() }
    }

    // MARK: Pinned headers

    /// Where a focused row rests: fully visible, and clear of the pinned group
    /// name above it. The nearest such offset to `offset`, so a row already in
    /// the clear does not move.
    private func restingOffset(for indexPath: IndexPath, near offset: CGFloat) -> CGFloat? {
        guard let frame = channels.layoutAttributesForItem(at: indexPath)?.frame else { return nil }
        let inset = channels.adjustedContentInset
        let highest = frame.minY - headerHeight(of: indexPath.section) - inset.top - Metrics.focusMargin
        let lowest = frame.maxY + Metrics.focusMargin + inset.bottom - channels.bounds.height
        return min(max(offset, lowest), highest)
    }

    /// Rows fade as they slide under a pinned group name, so the name never
    /// sits on top of a row's text.
    private func fadeRowsUnderHeaders() {
        let headers = channels.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
        for cell in channels.visibleCells {
            let covered = headers.map { header in
                max(0, min(cell.frame.maxY, header.frame.maxY) - max(cell.frame.minY, header.frame.minY))
            }.max() ?? 0
            cell.contentView.alpha = max(0, 1 - covered / (Metrics.rowHeight * 0.6))
        }
    }
}

extension LiveChannelSidebarView: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === groups {
            enterGroup(indexPath.item)
        } else if collectionView === schedule {
            guard let program = schedulePrograms[safe: indexPath.item],
                  let channel = scheduleChannel.flatMap(channel(at:)),
                  let cell = schedule.cellForItem(at: indexPath) else { return }
            onProgramSelected?(program, channel, cell.convert(cell.bounds, to: nil))
        } else if let channel = channel(at: indexPath) {
            onSelect?(channel)
        }
    }

    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        // The "No guide data" row is a note, not a choice.
        collectionView !== schedule || !schedulePrograms.isEmpty
    }

    /// Right from the groups (through `groupsExit`) lands on the group's entry
    /// row; Right from a channel (through `scheduleEntry`) on the programme on now.
    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if collectionView === schedule { return schedulePrograms.isEmpty ? nil : IndexPath(item: 0, section: 0) }
        guard collectionView === channels, showsGroups, let groupEntry,
              channels.cellForItem(at: groupEntry) != nil else { return nil }
        return groupEntry
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        if collectionView === groups {
            // Moving through the groups jumps the list along, as the library's
            // letter strip does. Arriving from the channels leaves it in place.
            guard let section = context.nextFocusedIndexPath?.item,
                  context.nextFocusedView?.isDescendant(of: groups) == true,
                  context.previouslyFocusedView?.isDescendant(of: groups) == true else { return }
            groupEntry = entry(in: section)
            reveal(section, animated: true)
            return
        }
        guard collectionView === channels else { return }
        let next = context.nextFocusedView?.isDescendant(of: channels) == true ? context.nextFocusedIndexPath : nil
        expand(next, with: coordinator)
        // With the schedule up, it follows the channel in focus.
        if showsSchedule, let next, next != scheduleChannel { loadSchedule(for: next) }
        focusScroll.focusChanged(to: context.nextFocusedView,
                                 target: next.flatMap { restingOffset(for: $0, near: channels.contentOffset.y) }
                                     .map { CGPoint(x: channels.contentOffset.x, y: $0) })
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === channels else { return }
        let preferred = focusedChannelRow.flatMap { restingOffset(for: $0, near: targetContentOffset.pointee.y) }
            .map { CGPoint(x: targetContentOffset.pointee.x, y: $0) }
        targetContentOffset.pointee = focusScroll.targetContentOffset(proposed: targetContentOffset.pointee,
                                                                      preferred: preferred)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === channels else { return }
        focusScroll.didEndDragging(willDecelerate: decelerate)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === channels else { return }
        focusScroll.didEndScrolling()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === channels else { return }
        focusScroll.didEndScrolling()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === channels else { return }
        fadeRowsUnderHeaders()
    }
}

// MARK: - Group row

/// One group: its name and how many channels it holds, with a speaker glyph
/// on the group the playing channel is in.
private final class LiveChannelGroupCell: UICollectionViewCell {

    private let plate = UIView()
    private let title = UILabel()
    private let count = UILabel()
    private let playingGlyph = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.layer.cornerRadius = LiveChannelSidebarView.Metrics.rowRadius
        plate.layer.borderWidth = 1
        plate.layer.cornerCurve = .continuous
        title.font = .systemFont(ofSize: 27, weight: .semibold)
        title.textColor = .white
        count.font = .systemFont(ofSize: 23, weight: .medium)
        count.textColor = UIColor.white.withAlphaComponent(0.6)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        playingGlyph.tintColor = UIColor.white.withAlphaComponent(0.7)
        playingGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        playingGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [title, playingGlyph, count])
        stack.spacing = 10
        stack.alignment = .center
        stack.setCustomSpacing(16, after: playingGlyph)
        [plate, stack].forEach {
            contentView.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: contentView.topAnchor),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        applyFocus(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, count: Int, isPlaying: Bool) {
        self.title.text = title
        self.count.text = count.formatted()
        playingGlyph.isHidden = !isPlaying
    }

    private func applyFocus(_ focused: Bool) {
        plate.backgroundColor = UIColor.white.withAlphaComponent(focused ? 0.18 : 0)
        plate.layer.borderColor = UIColor.white.withAlphaComponent(focused ? 0.25 : 0).cgColor
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.applyFocus(focused) }
    }
}

// MARK: - Schedule row

/// One programme in the schedule: its start time and title, with how far
/// through it the broadcast is for the one on now.
private final class LiveScheduleCell: UICollectionViewCell {

    private let plate = UIView()
    private let time = UILabel()
    private let title = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint?
    /// Centred alone; raised over the progress bar on the programme on now.
    private var titleCenter: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.layer.cornerRadius = LiveChannelSidebarView.Metrics.rowRadius
        plate.layer.borderWidth = 1
        plate.layer.cornerCurve = .continuous
        time.font = .monospacedDigitSystemFont(ofSize: 23, weight: .medium)
        time.textColor = UIColor.white.withAlphaComponent(0.6)
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.textColor = .white
        track.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        track.layer.cornerRadius = 2
        fill.backgroundColor = .white
        fill.layer.cornerRadius = 2
        track.addSubview(fill)

        [plate, time, title, track].forEach {
            contentView.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        fill.translatesAutoresizingMaskIntoConstraints = false
        let fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        self.fillWidth = fillWidth
        titleCenter = title.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: contentView.topAnchor),
            plate.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            plate.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            time.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            time.widthAnchor.constraint(equalToConstant: 84),
            time.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            title.leadingAnchor.constraint(equalTo: time.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            titleCenter,
            track.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            track.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
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

    /// nil is the row for a channel with nothing listed.
    func configure(program: UnifiedProgram?, now: Date) {
        guard let program else {
            time.text = nil
            title.text = String(localized: "No guide data")
            title.textColor = UIColor.white.withAlphaComponent(0.6)
            track.isHidden = true
            titleCenter.constant = 0
            return
        }
        time.text = program.startTime.formatted(Date.FormatStyle.dateTime.hour().minute())
        title.text = program.displayTitle
        title.textColor = .white
        let total = program.endTime.timeIntervalSince(program.startTime)
        let isOnNow = program.startTime <= now && total > 0
        track.isHidden = !isOnNow
        titleCenter.constant = isOnNow ? -6 : 0
        if isOnNow {
            let fraction = min(max(now.timeIntervalSince(program.startTime) / total, 0), 1)
            fillWidth?.isActive = false
            fillWidth = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: CGFloat(max(fraction, 0.001)))
            fillWidth?.isActive = true
        }
    }

    private func applyFocus(_ focused: Bool) {
        plate.backgroundColor = UIColor.white.withAlphaComponent(focused ? 0.18 : 0)
        plate.layer.borderColor = UIColor.white.withAlphaComponent(focused ? 0.25 : 0).cgColor
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.applyFocus(focused) }
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
/// Focused, it grows by a line that says what is next.
private final class LiveChannelSidebarCell: UICollectionViewCell {

    private let plate = UIView()
    private let logo = UIImageView()
    private let channelLine = UILabel()
    private let programLine = UILabel()
    private let nextLine = UILabel()
    private let playingGlyph = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    private let track = UIView()
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint?
    private var isCurrent = false
    private var hasNext = false
    private var logoURL: URL?
    private var imageTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.layer.cornerRadius = LiveChannelSidebarView.Metrics.rowRadius
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
        nextLine.font = .systemFont(ofSize: 21, weight: .medium)
        nextLine.textColor = UIColor.white.withAlphaComponent(0.6)
        playingGlyph.tintColor = .white
        playingGlyph.contentMode = .scaleAspectFit
        playingGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

        track.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        track.layer.cornerRadius = 2
        fill.backgroundColor = .white
        fill.layer.cornerRadius = 2
        track.addSubview(fill)

        [plate, logo, channelLine, programLine, nextLine, playingGlyph, track].forEach {
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

            // From the top, not centred: the row grows downward when focused.
            logo.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            logo.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            logo.widthAnchor.constraint(equalToConstant: 120),
            logo.heightAnchor.constraint(equalToConstant: 68),

            channelLine.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 20),
            channelLine.trailingAnchor.constraint(lessThanOrEqualTo: playingGlyph.leadingAnchor, constant: -12),
            channelLine.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            programLine.leadingAnchor.constraint(equalTo: channelLine.leadingAnchor),
            programLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            programLine.topAnchor.constraint(equalTo: channelLine.bottomAnchor, constant: 2),
            nextLine.leadingAnchor.constraint(equalTo: channelLine.leadingAnchor),
            nextLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            nextLine.topAnchor.constraint(equalTo: programLine.bottomAnchor, constant: 4),

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
        // The fade under a pinned group name belongs to the row's last place.
        contentView.alpha = 1
    }

    func configure(channel: UnifiedChannel, program: UnifiedProgram?, next: UnifiedProgram?, isCurrent: Bool) {
        self.isCurrent = isCurrent
        channelLine.text = [channel.channelNumber.map(String.init), channel.name]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        programLine.text = program?.title ?? String(localized: "No guide data")
        programLine.textColor = program == nil ? UIColor.white.withAlphaComponent(0.6) : .white
        playingGlyph.isHidden = !isCurrent
        hasNext = next != nil
        if let next {
            let time = next.startTime.formatted(Date.FormatStyle.dateTime.hour().minute())
            // The rail's Info pane's wording, so both say "next" the same way.
            nextLine.text = String(localized: "Next: \(next.displayTitle) at \(time)")
        }

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
        // Only the focused row has room for the line; the layout grows it.
        nextLine.alpha = focused && hasNext ? 1 : 0
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.applyFocus(focused) }
    }
}
