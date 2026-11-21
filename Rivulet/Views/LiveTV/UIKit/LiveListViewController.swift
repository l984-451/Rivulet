// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveListViewController.swift
//  Rivulet
//
//  The List layout: categories on the left (`LiveCategoryList`), the chosen
//  one's channels on the right with what each airs now. Selection follows
//  focus, as in the guide's category pills. Plays and opens the programme menu
//  as What's On does; there is no corner player here, so Back ends a channel.
//  Right on a channel opens the guide for its category: the host builds it
//  (`makeGuide`), and the list lays it over itself as a child and takes it off
//  again, so on the way back its row is there to take focus at once.
//

import UIKit
import Combine

/// Where the list comes back to from the guide: the guide's tab, and the
/// channel focused there.
struct LiveListReturn {
    let target: LiveGuideTarget
    let channelId: String?
}

final class LiveListViewController: UIViewController {

    private enum Metrics {
        /// The Live TV pages' margin (`MediaRowMetrics.liveLeading`).
        static let side: CGFloat = MediaRowMetrics.liveLeading
        /// Below the shell's collapsed pill.
        static let top: CGFloat = ShellPillMetrics.contentClearance
        /// The clock's line, as on What's On.
        static let clockTop: CGFloat = 52
        static let categoryWidth: CGFloat = 480
        static let columnGap: CGFloat = 72
        /// The chosen category's name and count above its channels.
        static let headerHeight: CGFloat = 92
        static let channelSpacing: CGFloat = 8
        static var channelX: CGFloat { side + categoryWidth + columnGap }
    }

    private let sourceIdFilter: String?
    /// Builds the guide for a category, on a channel. Its argument is how the
    /// guide leaves: with the tab and channel to come back on.
    var makeGuide: ((LiveGuideTarget, String, @escaping (LiveListReturn) -> Void) -> UIViewController)?
    private var guide: UIViewController?
    /// Back from the guide: the channel whose row is preferred until focus lands.
    private var returnChannelId: String?
    private var list = LiveCategoryList.build(LiveCategoryList.Input(channels: []))
    private var selectedId: String?
    /// Folded sections per sidebar entry, kept for the session: the list is
    /// rebuilt each time it comes back from the guide.
    private static var collapsedBySource: [String: Set<String>] = [:]
    private var collapsedSourceIds: Set<String> {
        get { Self.collapsedBySource[sourceIdFilter ?? ""] ?? [] }
        set { Self.collapsedBySource[sourceIdFilter ?? ""] = newValue }
    }
    /// The channels on the right, and the category they belong to.
    private var shownCategoryId: String?
    private var shownIds: [String] = []
    private var shownById: [String: UnifiedChannel] = [:]

    private let categoryView = SidebarCollectionView(
        frame: .zero, collectionViewLayout: makeLayout(rowHeight: LiveCategoryCell.height, spacing: 0, sideInset: 0))
    private let channelView = UICollectionView(
        frame: .zero, collectionViewLayout: makeLayout(rowHeight: LiveChannelRowCell.height,
                                                       spacing: Metrics.channelSpacing,
                                                       sideInset: LiveChannelRowCell.platterOutset))
    private var categoryData: UICollectionViewDiffableDataSource<Int, String>!
    private var channelData: UICollectionViewDiffableDataSource<Int, String>!
    /// Between the columns: Right lands on the channels' first visible row,
    /// Left on the selected category, rather than on the nearest row.
    private let columnGuide = UIFocusGuide()

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let clockLabel = UILabel()
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    /// Read once by `preferredFocusEnvironments`.
    private var pendingFocus: UIFocusEnvironment?
    private var cancellables = Set<AnyCancellable>()
    private var minuteTimer: Timer?
    private var timerTicks = 0
    /// A guide or timer rebuild waited because it would have removed the row being browsed.
    private var rebuildHeld = false
    /// Measures the rows on screen once they settle (`LiveStreamProber`).
    private var probeWork: DispatchWorkItem?
    private var guideSwipe: DirectionalInputBinding?
    /// The remote gesture that brought focus into the channels. That same
    /// Right goes on to reach `pressesBegan`, and must not open the guide.
    private var channelEntryGesture = -1

    private static let timeFormat = Date.FormatStyle.dateTime.hour().minute()

    init(sourceIdFilter: String?) {
        self.sourceIdFilter = sourceIdFilter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)
        setUpHeader()
        setUpColumns()
        setUpEmptyState()

        let store = LiveTVDataStore.shared
        Publishers.CombineLatest4(store.$channels, store.$sources, store.$recentChannelIds,
                                  store.$favoriteIds.combineLatest(store.$unfavoritedIds))
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        // A guide update changes what rows say, and which rows there are: For You and the
        // genre rows come from what is on, as may a smart list with a genre rule.
        // The rows' text follows at once; the categories at most every few seconds, since a
        // launch delivers the guide in many batches and each rebuild walks the whole lineup.
        store.$epg
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibleRows() }
            .store(in: &cancellables)
        store.$epg
            .dropFirst()
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.rebuild(keepingSelection: true) }
            .store(in: &cancellables)
        store.$isLoadingChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateEmptyState() }
            .store(in: &cancellables)
        // A channel's quality, noted while it played.
        LiveStreamQualityStore.shared.$byChannel
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibleRows() }
            .store(in: &cancellables)
        // The viewer's own lists and pins, changed from a hold menu here or elsewhere.
        let lists = LiveChannelListStore.shared
        lists.$lists.map { _ in () }.merge(with: lists.$pinnedCategoryKeys.map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)

        Task { @MainActor in
            if store.channels.isEmpty { await store.loadChannels() }
            if store.epg.isEmpty { await store.loadEPG(startDate: Date(), hours: 12) }
            await store.refreshScheduledRecordings()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateClock()
        rebuild()
        minuteTimer?.invalidate()
        // What is on, and how far through, moves by the minute.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateClock()
                self.timerTicks += 1
                // For You and the genre rows follow what is on: rebuilt every five minutes.
                if self.timerTicks % 10 == 0 || self.rebuildHeld {
                    self.rebuild(keepingSelection: true)
                } else {
                    self.refreshVisibleRows()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Again on each appear: handlers are asked newest first.
        MenuPressInterceptor.register(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopProbing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        MenuPressInterceptor.resign(self)
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingFocus { return [pendingFocus] }
        if let guide { return [guide] }
        if let row = returnFocusTarget() { return [row] }
        return [categoryView]
    }

    // MARK: - Guide

    /// The guide over the list, on the focused channel. It covers the
    /// focused row, which then cannot keep focus, so the guide is laid out at
    /// once and given focus before the engine looks elsewhere (the shell's
    /// edge, which opens the sidebar). Inside, the channel's programme takes it.
    private func showGuide(_ target: LiveGuideTarget, channelId: String) {
        guard guide == nil, let makeGuide else { return }
        stopProbing()
        let guide = makeGuide(target, channelId) { [weak self] back in self?.closeGuide(back) }
        self.guide = guide
        // Opaque, so the list never shows through where the guide draws nothing.
        guide.view.backgroundColor = .black
        guide.view.frame = view.bounds
        guide.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(guide)
        view.addSubview(guide.view)
        guide.didMove(toParent: self)
        guide.view.layoutIfNeeded()
        // Covered is not enough: a covered row keeps focus. Hidden, it cannot.
        setColumnsHidden(true)
        // After the press that opened it has been handled; during it the
        // request is dropped.
        DispatchQueue.main.async { [weak self, weak guide] in
            guard let self, let guide, self.guide === guide else { return }
            let target: UIView = Self.guideContainer(in: guide.view) ?? guide.view
            UIFocusSystem.focusSystem(for: self.view)?.requestFocusUpdate(to: target)
        }
    }

    private func setColumnsHidden(_ hidden: Bool) {
        categoryView.isHidden = hidden
        channelView.isHidden = hidden
    }

    /// The guide's UIKit grid inside its hosting view.
    private static func guideContainer(in view: UIView) -> UIView? {
        if view is EPGContainerView { return view }
        for subview in view.subviews {
            if let found = guideContainer(in: subview) { return found }
        }
        return nil
    }

    /// Back from the guide, on its tab and the channel focused there. The row
    /// is brought on screen under the guide first, so the moment the guide
    /// comes off it is there to take focus.
    private func closeGuide(_ back: LiveListReturn) {
        guard let guide else { return }
        if let id = list.categoryId(backFrom: back.target, openedFrom: selectedId, channelId: back.channelId) {
            selectCategory(id)
            categoryView.preferredFocusIndexPath = categoryData.indexPath(for: id)
        }
        returnChannelId = back.channelId
        if let channelId = back.channelId, let indexPath = channelData.indexPath(for: channelId) {
            channelView.layoutIfNeeded()
            channelView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            channelView.layoutIfNeeded()
        }

        setColumnsHidden(false)
        guide.willMove(toParent: nil)
        guide.view.removeFromSuperview()
        guide.removeFromParent()
        self.guide = nil

        let target = returnFocusTarget() ?? selectedCategoryIndexPath().flatMap { categoryView.cellForItem(at: $0) }
        if let target { UIFocusSystem.focusSystem(for: view)?.requestFocusUpdate(to: target) }
    }

    /// The returning channel's row, while it is on screen.
    private func returnFocusTarget() -> UIView? {
        guard let id = returnChannelId, let indexPath = channelData.indexPath(for: id) else { return nil }
        return channelView.cellForItem(at: indexPath)
    }

    // Right on a channel opens the guide: the press here, the swipe through
    // `guideSwipe`. Nothing lies to the right of a row, so the engine never
    // takes this move itself.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presentedViewController == nil,
              presses.contains(where: { $0.type == .rightArrow }), focusIsOnChannel() else {
            super.pressesBegan(presses, with: event)
            return
        }
        openGuide()
    }

    private func focusIsOnChannel() -> Bool {
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: channelView)
    }

    /// Only a fresh Right once focus is on a channel; the one that moved it there is spent.
    private func openGuide() {
        guard MenuPressInterceptor.remoteGestures.count != channelEntryGesture,
              let categoryId = selectedId, let channelId = focusedChannelId(),
              let target = list.guideTarget(for: categoryId) else { return }
        showGuide(target, channelId: channelId)
    }

    // Left from the channels: the guide between the columns now leads to the
    // selected category; from the categories, to the channels.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        if next.isDescendant(of: view) { returnChannelId = nil }
        if next.isDescendant(of: channelView), context.previouslyFocusedView?.isDescendant(of: channelView) != true {
            channelEntryGesture = MenuPressInterceptor.remoteGestures.count
        }
        if next.isDescendant(of: channelView) {
            columnGuide.preferredFocusEnvironments = [categoryView]
            categoryView.preferredFocusIndexPath = selectedCategoryIndexPath()
        } else if next.isDescendant(of: categoryView) {
            columnGuide.preferredFocusEnvironments = [channelView]
        }
    }

    // MARK: - Layout

    private static func makeLayout(rowHeight: CGFloat, spacing: CGFloat, sideInset: CGFloat) -> UICollectionViewLayout {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(rowHeight))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: sideInset, bottom: 0, trailing: sideInset)
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func setUpHeader() {
        titleLabel.font = .systemFont(ofSize: 56, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 26, weight: .medium)
        countLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        clockLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        [titleLabel, countLabel, clockLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            clockLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.clockTop),
            clockLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.side),

            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.top),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.channelX),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 20),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Metrics.side),
        ])
    }

    private func setUpColumns() {
        for collection in [categoryView, channelView] as [UICollectionView] {
            collection.backgroundColor = .clear
            collection.contentInsetAdjustmentBehavior = .never
            collection.delegate = self
            collection.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(collection)
        }
        // Focus entering a column goes where `indexPathForPreferredFocusedView` says.
        categoryView.remembersLastFocusedIndexPath = false
        channelView.remembersLastFocusedIndexPath = false
        // The first capsule sits on the header's line; the row is 3pt taller than its capsule.
        categoryView.contentInset = UIEdgeInsets(top: Metrics.top - 3, left: 0, bottom: 60, right: 0)
        channelView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        categoryView.register(LiveCategoryCell.self, forCellWithReuseIdentifier: LiveCategoryCell.reuseID)
        channelView.register(LiveChannelRowCell.self, forCellWithReuseIdentifier: LiveChannelRowCell.reuseID)

        categoryData = UICollectionViewDiffableDataSource(collectionView: categoryView) { [weak self] cv, indexPath, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: LiveCategoryCell.reuseID, for: indexPath) as! LiveCategoryCell
            if let self, let category = self.list.category(id) {
                cell.configure(category, selected: id == self.selectedId,
                               collapsed: category.sourceId.map { self.collapsedSourceIds.contains($0) } ?? false)
            }
            return cell
        }
        channelData = UICollectionViewDiffableDataSource(collectionView: channelView) { [weak self] cv, indexPath, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: LiveChannelRowCell.reuseID, for: indexPath) as! LiveChannelRowCell
            if let self, let channel = self.shownById[id] {
                cell.configure(channel, nowNext: self.nowNext(channel))
            }
            return cell
        }

        channelView.addGestureRecognizer(TileLongPress.makeRecognizer(target: self, action: #selector(handleLongPress(_:))))
        categoryView.addGestureRecognizer(TileLongPress.makeRecognizer(target: self,
                                                                       action: #selector(handleCategoryLongPress(_:))))
        guideSwipe = DirectionalInputBinding(
            gatedSwipesOn: channelView,
            directions: [.right],
            shouldHandle: { [weak self] _ in
                guard let self else { return false }
                return self.presentedViewController == nil && self.focusIsOnChannel()
            },
            onSwipe: { [weak self] _ in self?.openGuide() })

        view.addLayoutGuide(columnGuide)
        let outset = LiveChannelRowCell.platterOutset
        NSLayoutConstraint.activate([
            categoryView.topAnchor.constraint(equalTo: view.topAnchor),
            categoryView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            categoryView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.side),
            categoryView.widthAnchor.constraint(equalToConstant: Metrics.categoryWidth),

            // Wider than the rows by the platter's reach, so it is not clipped.
            channelView.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.top + Metrics.headerHeight),
            channelView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            channelView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.channelX - outset),
            channelView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -(Metrics.side - outset)),

            columnGuide.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.top),
            columnGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            columnGuide.leadingAnchor.constraint(equalTo: categoryView.trailingAnchor),
            columnGuide.trailingAnchor.constraint(equalTo: channelView.leadingAnchor),
        ])
        columnGuide.preferredFocusEnvironments = [channelView]
    }

    private func setUpEmptyState() {
        emptyLabel.text = String(localized: "No channels yet. Add a Live TV source in Settings.")
        emptyLabel.font = .systemFont(ofSize: 30, weight: .medium)
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        emptyLabel.isHidden = true
        spinner.color = .white
        spinner.hidesWhenStopped = true
        [emptyLabel, spinner].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Content

    /// Rebuilds the categories from the store, keeping the selection where it
    /// still exists. A selected row that went away (its last favourite
    /// removed) hands over to the first category.
    ///
    /// `keepingSelection`: a rebuild nobody asked for (the guide moved on, the timer). An on-now
    /// row (For You, a genre) can end while the viewer is in it; the rebuild then waits until
    /// they have left the row, so the list never jumps to another category under them.
    private func rebuild(keepingSelection: Bool = false) {
        guard isViewLoaded else { return }
        let next = LiveTVDataStore.shared.liveCategoryList(sourceIdFilter: sourceIdFilter,
                                                           collapsedSourceIds: collapsedSourceIds)
        if keepingSelection, let selectedId, list.category(selectedId) != nil, next.category(selectedId) == nil {
            rebuildHeld = true
            refreshVisibleRows()
            return
        }
        rebuildHeld = false
        list = next
        let ids = list.categories.map(\.id)
        let existing = Set(categoryData.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        // Same ids, new counts: a row's identity never changes, so diffing alone never reaches it.
        snapshot.reconfigureItems(ids.filter(existing.contains))
        categoryData.apply(snapshot, animatingDifferences: false)

        if selectedId.flatMap({ list.category($0) }) == nil {
            selectedId = list.categories.first { $0.kind != .sourceHeader }?.id
            categoryView.preferredFocusIndexPath = selectedId.flatMap { categoryData.indexPath(for: $0) }
        }
        showChannels()
        updateEmptyState()
    }

    /// The selected category's channels on the right. Within one category the
    /// rows diff, so focus stays put; a new category starts at its top.
    private func showChannels() {
        let channels = selectedId.map { list.channels(in: $0) } ?? []
        let sameCategory = selectedId == shownCategoryId
        let focusedId = sameCategory ? focusedChannelId() : nil
        let oldIds = shownIds
        shownCategoryId = selectedId
        shownIds = channels.map(\.id)
        shownById = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(shownIds)
        if sameCategory, oldIds == shownIds {
            // Nothing moved (the usual guide update): only the rows on screen need their new text,
            // not a diff of what can be tens of thousands of rows.
            refreshVisibleRows()
        } else if sameCategory {
            snapshot.reconfigureItems(oldIds.filter { shownById[$0] != nil })
            channelData.apply(snapshot, animatingDifferences: false)
        } else {
            // Skips the diff: All Channels can hold tens of thousands of rows,
            // and focus walking the categories swaps them on every step.
            channelData.applySnapshotUsingReloadData(snapshot)
            channelView.setContentOffset(CGPoint(x: 0, y: -channelView.adjustedContentInset.top), animated: false)
        }

        scheduleProbe()
        let category = selectedId.flatMap { list.category($0) }
        titleLabel.text = category?.title
        countLabel.text = category.map { String(localized: "\($0.channelCount) channels") }

        // The focused row went away (a favourite removed): the next row takes
        // focus, or the one before at the end, or the categories when none is left.
        if let focusedId, shownById[focusedId] == nil {
            let index = oldIds.firstIndex(of: focusedId) ?? 0
            let target = oldIds[(index + 1)...].first { shownById[$0] != nil }
                ?? oldIds[..<index].last { shownById[$0] != nil }
            DispatchQueue.main.async { [weak self] in
                if let target { self?.focusChannel(target) } else { self?.focusSelectedCategory() }
            }
        }
    }

    private func selectCategory(_ id: String) {
        guard id != selectedId else { return }
        selectedId = id
        for case let cell as LiveCategoryCell in categoryView.visibleCells {
            guard let indexPath = categoryView.indexPath(for: cell) else { continue }
            cell.isSelectedRow = categoryData.itemIdentifier(for: indexPath) == id
        }
        showChannels()
    }

    private func toggleSection(_ sourceId: String) {
        if collapsedSourceIds.contains(sourceId) {
            collapsedSourceIds.remove(sourceId)
        } else {
            collapsedSourceIds.insert(sourceId)
        }
        // The header keeps its id, so it keeps focus; the channels stay as they are.
        rebuild()
    }

    private func nowNext(_ channel: UnifiedChannel, now: Date = Date()) -> LiveNowNext {
        LiveNowNext.of(LiveTVDataStore.shared.epg[channel.id], at: now)
    }

    /// Text and progress of the rows on screen, without a reload.
    private func refreshVisibleRows() {
        let now = Date()
        for case let cell as LiveChannelRowCell in channelView.visibleCells {
            guard let indexPath = channelView.indexPath(for: cell),
                  let id = channelData.itemIdentifier(for: indexPath),
                  let channel = shownById[id] else { continue }
            cell.configure(channel, nowNext: nowNext(channel, now: now), now: now)
        }
    }

    private func updateClock() {
        clockLabel.text = Date().formatted(Self.timeFormat)
    }

    private func updateEmptyState() {
        let empty = list.categories.isEmpty
        let loading = LiveTVDataStore.shared.isLoadingChannels
        if empty && loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        emptyLabel.isHidden = !(empty && !loading)
        titleLabel.isHidden = empty
        countLabel.isHidden = empty
    }

    // MARK: - Measuring streams

    /// The rows on screen, a moment after they settle, while nothing plays here.
    private func scheduleProbe() {
        probeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let rows = self.channelView.indexPathsForVisibleItems.sorted()
                .compactMap { self.channelData.itemIdentifier(for: $0) }
                .compactMap { self.shownById[$0] }
            LiveStreamProber.shared.probe(rows) { [weak self] in
                guard let self else { return false }
                return self.view.window != nil && self.presentedViewController == nil && self.guide == nil
            }
        }
        probeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func stopProbing() {
        probeWork?.cancel()
        probeWork = nil
        LiveStreamProber.shared.stop()
    }

    // MARK: - Focus

    private func requestFocus(_ environment: UIFocusEnvironment) {
        pendingFocus = environment
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // Left set, it would pull every later focus update back here.
        pendingFocus = nil
    }

    private func focusedChannelId() -> String? {
        TileLongPress.focusedCell(in: channelView).flatMap { channelData.itemIdentifier(for: $0) }
    }

    /// The selected category's row, or its source's header while it is folded away.
    private func selectedCategoryIndexPath() -> IndexPath? {
        guard let id = selectedId else { return nil }
        if let indexPath = categoryData.indexPath(for: id) { return indexPath }
        return list.category(id)?.sourceId
            .flatMap { categoryData.indexPath(for: LiveCategoryList.id(.sourceHeader, sourceId: $0)) }
    }

    private func focusSelectedCategory() {
        guard let indexPath = selectedCategoryIndexPath() else { return }
        categoryView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        categoryView.layoutIfNeeded()
        categoryView.preferredFocusIndexPath = indexPath
        requestFocus(categoryView)
    }

    private func focusChannel(_ id: String) {
        guard let indexPath = channelData.indexPath(for: id) else { return }
        channelView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        channelView.layoutIfNeeded()
        if let cell = channelView.cellForItem(at: indexPath) { requestFocus(cell) }
    }

    private func firstVisibleChannelIndexPath() -> IndexPath? {
        channelView.indexPathsForVisibleItems.min { $0.item < $1.item }
    }

    // MARK: - Actions

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let indexPath = TileLongPress.focusedCell(in: channelView),
              let id = channelData.itemIdentifier(for: indexPath),
              let channel = shownById[id] else { return }
        let frame = channelView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        stopProbing()
        LiveChannelPresenter.presentMenu(channel: channel, program: nowNext(channel).current, from: self,
                                         sourceFrame: frame, sourceIdFilter: sourceIdFilter,
                                         onDismiss: focusAfterPlayer)
    }

    /// Held Select on a category: pin a group to the top, rename or delete one
    /// of the viewer's own lists, change a smart list's rules, or start a smart list.
    @objc private func handleCategoryLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let indexPath = TileLongPress.focusedCell(in: categoryView),
              let id = categoryData.itemIdentifier(for: indexPath),
              let category = list.category(id) else { return }
        let store = LiveChannelListStore.shared
        var sections: [[TileMenuAction]] = []
        if let key = category.pinKey {
            if store.isPinned(key) {
                sections.append([TileMenuAction(title: "Unpin", systemImage: "pin.slash") { store.togglePin(key) }])
            } else {
                sections.append([TileMenuAction(title: "Pin", systemImage: "pin") { store.togglePin(key) }])
            }
        }
        if case .list(let listId) = category.kind {
            sections += LiveSmartListMenu.editSections(listId: listId, from: self, sourceIdFilter: sourceIdFilter)
            sections.append([TileMenuAction(title: "Rename", systemImage: "pencil") { [weak self] in
                guard let self else { return }
                LiveProgramMenu.presentNameEntry(title: "Rename List", initialText: category.title, from: self) { name in
                    store.rename(listId, to: name)
                }
            }])
            sections.append([TileMenuAction(title: "Delete", systemImage: "trash", destructive: true) { [weak self] in
                self?.present(ConfirmationPopupViewController(
                    title: String(localized: "Delete \u{201C}\(category.title)\u{201D}?"),
                    message: String(localized: "This removes the list from this Apple TV. Its channels stay where they are."),
                    confirmTitle: String(localized: "Delete"), destructive: true,
                    onConfirm: { store.delete(listId) }), animated: true)
            }])
        }
        sections.append([LiveSmartListMenu.newAction(from: self, sourceIdFilter: sourceIdFilter)])
        let frame = categoryView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        present(TileMenuPopupViewController(sections: sections, sourceFrame: frame,
                                            header: TileMenuHeader(title: category.title)), animated: false)
    }

    /// Full screen on the glass rail, as from What's On. No corner player
    /// here, so Back ends the channel; focus comes back to the channel that
    /// was on screen, which may have changed in the player.
    private func play(_ channel: UnifiedChannel) {
        // The provider may allow one stream: nothing is measured while one plays.
        stopProbing()
        LiveChannelPresenter.play(channel, from: self, sourceIdFilter: sourceIdFilter, onDismiss: focusAfterPlayer)
    }

    private var focusAfterPlayer: (UnifiedChannel) -> Void {
        { [weak self] channel in DispatchQueue.main.async { self?.focusChannel(channel.id) } }
    }
}

// MARK: - Collection views

extension LiveListViewController: UICollectionViewDelegate {
    /// Entry into a column: the channels' first visible row, or the selected category.
    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        collectionView === channelView ? firstVisibleChannelIndexPath() : selectedCategoryIndexPath()
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        // Scrolling through channels brings new rows on screen to measure.
        if collectionView === channelView { scheduleProbe() }
        guard collectionView === categoryView,
              let indexPath = context.nextFocusedIndexPath,
              let id = categoryData.itemIdentifier(for: indexPath),
              let category = list.category(id) else { return }
        // A header folds its section; it never changes the channels.
        if category.kind != .sourceHeader { selectCategory(id) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === channelView {
            guard let id = channelData.itemIdentifier(for: indexPath), let channel = shownById[id] else { return }
            play(channel)
            return
        }
        guard let id = categoryData.itemIdentifier(for: indexPath), let category = list.category(id) else { return }
        if category.kind == .sourceHeader, let sourceId = category.sourceId {
            toggleSection(sourceId)
        } else if let first = firstVisibleChannelIndexPath(), let cell = channelView.cellForItem(at: first) {
            requestFocus(cell)
        }
    }
}

// MARK: - Menu and sidebar reselect

extension LiveListViewController: MenuBackHandling, SidebarTabReselecting {
    /// Menu on a channel goes to the categories. On a category it declines,
    /// so the sidebar opens.
    func handleMenuBack() -> Bool {
        // Focus must be in this page: a player or menu presented over it holds
        // focus in its own views, and Menu keeps its meaning there.
        guard isViewLoaded, presentedViewController == nil,
              let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
              focused.isDescendant(of: channelView) else { return false }
        focusSelectedCategory()
        return true
    }

    /// Both columns to the top, and focus on the first category.
    func reselectSidebarTab() {
        // The guide over the list comes off first.
        if let guide {
            setColumnsHidden(false)
            guide.willMove(toParent: nil)
            guide.view.removeFromSuperview()
            guide.removeFromParent()
            self.guide = nil
        }
        ScrollToTopTransition.perform(in: categoryView) {
            categoryView.setContentOffset(CGPoint(x: 0, y: -categoryView.adjustedContentInset.top), animated: false)
            if let first = list.categories.first(where: { $0.kind != .sourceHeader }) { selectCategory(first.id) }
            categoryView.layoutIfNeeded()
            focusSelectedCategory()
        }
    }
}
