// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveSearchViewController.swift
//  Rivulet
//
//  The Search tab when only Live TV is signed in: look up a channel by name,
//  number or call sign, or by what it airs now (`LiveChannelSearch`). Built
//  like the library search (`SearchContainerViewController`): the keyboard on
//  top, the results as the search controller's results page. Select plays a
//  channel; held Select opens the programme menu.
//

import UIKit
import Combine

final class LiveSearchViewController: UIViewController {
    private let results = LiveSearchResultsViewController()
    private let searchController: UISearchController
    private let searchContainer: UISearchContainerViewController

    private var index: LiveChannelSearch.Index?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var minuteTimer: Timer?

    /// Which half the next focus request aims at, as in the library search.
    private enum Half { case keyboard, results }
    private var preferredHalf: Half = .keyboard

    init() {
        searchController = UISearchController(searchResultsController: results)
        searchContainer = UISearchContainerViewController(searchController: searchController)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = String(localized: "Search channels")
        // The results are the whole page; nothing should dim them.
        searchController.obscuresBackgroundDuringPresentation = false

        results.onPlay = { [weak self] channel in self?.play(channel) }
        results.onMenu = { [weak self] channel, program, frame in self?.presentMenu(channel, program: program, frame: frame) }

        addChild(searchContainer)
        searchContainer.view.frame = view.bounds
        searchContainer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(searchContainer.view)
        searchContainer.didMove(toParent: self)

        let store = LiveTVDataStore.shared
        store.$channels.map { _ in () }.merge(with: store.$epg.map { _ in () })
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.rebuildIndex() }
            .store(in: &cancellables)
        Task { @MainActor in
            if store.channels.isEmpty { await store.loadChannels() }
            if store.epg.isEmpty { await store.loadEPG(startDate: Date(), hours: 12) }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildIndex()
        minuteTimer?.invalidate()
        // What airs now moves on; the index holds it.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildIndex() }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    /// Leaving the tab (the shell caches this controller) resets the query, as the library search does.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        minuteTimer?.invalidate()
        minuteTimer = nil
        guard presentedViewController == nil else { return }
        preferredHalf = .keyboard
        guard searchController.searchBar.text?.isEmpty == false else { return }
        searchController.searchBar.text = nil
        runSearch("")
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard preferredHalf == .keyboard else { return [results] }
        // As in the library search: the bar, then the container that creates the keyboard.
        return [searchController.searchBar, searchContainer]
    }

    // MARK: - Searching

    /// Built off the main thread: a large lineup takes a moment.
    private func rebuildIndex() {
        let store = LiveTVDataStore.shared
        let channels = store.channels
        let epg = store.epg
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                LiveChannelSearch.Index(channels, epg: epg, now: Date())
            }.value
            guard let self, !Task.isCancelled else { return }
            self.index = built
            self.runSearch(self.searchController.searchBar.text ?? "")
        }
    }

    private func runSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results.show(nil, query: "")
            return
        }
        guard let index else {
            results.showSearching()
            return
        }
        searchTask = Task { [weak self] in
            // A short pause, so typing a word runs one search, not one per letter.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                LiveChannelSearch.search(trimmed, in: index)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.results.show(found, query: trimmed)
        }
    }

    // MARK: - Actions

    /// Full screen, as from the List: no corner player here, so Back ends the channel.
    private func play(_ channel: UnifiedChannel) {
        preferredHalf = .results
        LiveChannelPresenter.play(channel, from: self)
    }

    private func presentMenu(_ channel: UnifiedChannel, program: UnifiedProgram?, frame: CGRect?) {
        preferredHalf = .results
        LiveChannelPresenter.presentMenu(channel: channel, program: program, from: self, sourceFrame: frame)
    }

    // MARK: - Keyboard and results

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView, next.isDescendant(of: view) else { return }
        preferredHalf = next.isDescendant(of: results.view) ? .results : .keyboard
    }

    /// Down out of the keyboard and Up out of the top result, when the engine
    /// declined the move (the collapsed keyboard is the usual reason), as the
    /// library search does. Swipes reach the engine and need no help.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presentedViewController == nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        let types = Set(presses.map(\.type))
        let before = UIFocusSystem.focusSystem(for: view)?.focusedItem
        if types.contains(.downArrow), !results.containsFocus {
            DispatchQueue.main.async { [weak self] in
                guard let self, UIFocusSystem.focusSystem(for: self.view)?.focusedItem === before,
                      self.results.aimAtFirstRow() else { return }
                self.move(to: .results)
            }
        } else if types.contains(.upArrow), results.focusIsOnFirstRow {
            DispatchQueue.main.async { [weak self] in
                guard let self, UIFocusSystem.focusSystem(for: self.view)?.focusedItem === before else { return }
                self.move(to: .keyboard)
            }
        }
        super.pressesBegan(presses, with: event)
    }

    private func move(to half: Half) {
        preferredHalf = half
        if half == .keyboard, !searchController.searchBar.isFirstResponder {
            // The keyboard grows back only when the field becomes first responder.
            searchController.searchBar.becomeFirstResponder()
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

extension LiveSearchViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        runSearch(searchController.searchBar.text ?? "")
    }
}

extension LiveSearchViewController: SidebarTabReselecting {
    func reselectSidebarTab() {
        move(to: .keyboard)
    }
}

// MARK: - Results page

/// Channels, then programmes on now, each a List row; a line of text while
/// there is no query or nothing was found.
final class LiveSearchResultsViewController: UIViewController, UICollectionViewDelegate {
    var onPlay: ((UnifiedChannel) -> Void)?
    var onMenu: ((UnifiedChannel, UnifiedProgram?, CGRect?) -> Void)?

    private enum Section: Int { case channels, onNow }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private var channelsById: [String: UnifiedChannel] = [:]
    private let messageLabel = UILabel()
    /// One-shot target for the container's focus request.
    private var aimedRow: IndexPath?

    override func viewDidLoad() {
        super.viewDidLoad()
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(LiveChannelRowCell.height))
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 8
            section.contentInsetsReference = .none
            let side = MediaRowMetrics.liveLeading
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: side, bottom: 40, trailing: side)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(64)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            header.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: side, bottom: 0, trailing: side)
            section.boundarySupplementaryItems = [header]
            return section
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(LiveChannelRowCell.self, forCellWithReuseIdentifier: LiveChannelRowCell.reuseID)
        collectionView.register(HubHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: HubHeaderView.reuseID)
        view.addSubview(collectionView)

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, indexPath, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: LiveChannelRowCell.reuseID, for: indexPath) as! LiveChannelRowCell
            if let channel = self?.channelsById[id] {
                cell.configure(channel, nowNext: LiveNowNext.of(LiveTVDataStore.shared.epg[channel.id], at: Date()))
            }
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] cv, kind, indexPath in
            let header = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: HubHeaderView.reuseID,
                                                             for: indexPath) as! HubHeaderView
            let section = self?.dataSource.sectionIdentifier(for: indexPath.section)
            header.configure(title: section == .onNow ? String(localized: "On Now") : String(localized: "Channels"),
                             style: .swiftUIInfiniteRow)
            return header
        }
        collectionView.addGestureRecognizer(TileLongPress.makeRecognizer(target: self, action: #selector(handleLongPress(_:))))

        messageLabel.font = .systemFont(ofSize: 30, weight: .medium)
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 2
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 1200),
        ])
        show(nil, query: "")
    }

    /// nil results: the prompt for an empty query.
    func show(_ found: LiveChannelSearch.Results?, query: String) {
        guard isViewLoaded else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        channelsById = [:]
        if let found {
            if !found.channels.isEmpty {
                snapshot.appendSections([.channels])
                snapshot.appendItems(found.channels.map { "c|\($0.id)" }, toSection: .channels)
                for channel in found.channels { channelsById["c|\(channel.id)"] = channel }
            }
            if !found.onNow.isEmpty {
                snapshot.appendSections([.onNow])
                snapshot.appendItems(found.onNow.map { "p|\($0.channel.id)" }, toSection: .onNow)
                for hit in found.onNow { channelsById["p|\(hit.channel.id)"] = hit.channel }
            }
        }
        // The index is rebuilt each minute and as the guide fills, which runs the search again:
        // the same results refresh their rows in place, and changed ones are diffed, so the
        // focused row and the scroll stay where the viewer is.
        let current = dataSource.snapshot()
        if current.sectionIdentifiers == snapshot.sectionIdentifiers,
           current.itemIdentifiers == snapshot.itemIdentifiers {
            var refreshed = current
            refreshed.reconfigureItems(current.itemIdentifiers)
            dataSource.apply(refreshed, animatingDifferences: false)
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        if found == nil {
            messageLabel.text = String(localized: "Search for a channel by name or number, or for what is on now.")
        } else if found?.isEmpty == true {
            messageLabel.text = String(localized: "No Results")
        } else {
            messageLabel.text = nil
        }
        messageLabel.isHidden = messageLabel.text == nil
    }

    func showSearching() {
        guard isViewLoaded else { return }
        dataSource.applySnapshotUsingReloadData(NSDiffableDataSourceSnapshot())
        messageLabel.text = String(localized: "Searching…")
        messageLabel.isHidden = false
    }

    // MARK: Focus

    var containsFocus: Bool {
        guard isViewLoaded, let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: collectionView)
    }

    var focusIsOnFirstRow: Bool {
        TileLongPress.focusedCell(in: collectionView) == IndexPath(item: 0, section: 0)
    }

    /// Brings the first result on screen and makes it the next focus target. False with no results.
    func aimAtFirstRow() -> Bool {
        guard isViewLoaded, collectionView.numberOfSections > 0, collectionView.numberOfItems(inSection: 0) > 0 else {
            return false
        }
        let first = IndexPath(item: 0, section: 0)
        collectionView.scrollToItem(at: first, at: .top, animated: false)
        collectionView.layoutIfNeeded()
        aimedRow = first
        return collectionView.cellForItem(at: first) != nil
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let aimed = aimedRow, let cell = collectionView.cellForItem(at: aimed) {
            aimedRow = nil
            return [cell]
        }
        return [collectionView].compactMap { $0 }
    }

    // MARK: Actions

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let channel = channelsById[id] else { return }
        onPlay?(channel)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let indexPath = TileLongPress.focusedCell(in: collectionView),
              let id = dataSource.itemIdentifier(for: indexPath), let channel = channelsById[id] else { return }
        let frame = collectionView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        onMenu?(channel, LiveNowNext.of(LiveTVDataStore.shared.epg[channel.id], at: Date()).current, frame)
    }
}
