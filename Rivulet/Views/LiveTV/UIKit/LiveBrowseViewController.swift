// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveBrowseViewController.swift
//  Rivulet
//
//  The Browse layout for Live TV, after the Apple TV app: shelves of 16:9
//  cards (recordings, favourites, what is on now, what starts soon, then each
//  channel group) under a header that describes whatever has focus. Offered
//  beside the Guide and Channels layouts, not instead of them.
//
//  Selecting a live card plays it full screen with the showcase chrome. Back
//  from there keeps it playing in the header's corner; selecting it again
//  takes it back full screen with no new tune. Multiview opens from the
//  player's chrome or from a card's long-press menu, and a tile can come back
//  out full screen. One session moves between the three the whole time.
//

import UIKit
import Combine

final class LiveBrowseViewController: UIViewController {

    private let sourceIdFilter: String?

    // Header
    private let backdrop = UIImageView()
    private let backdropFade = CAGradientLayer()
    private let backdropSideFade = CAGradientLayer()
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let summaryLabel = UILabel()
    private let clockLabel = UILabel()
    private let miniPlayer = LiveMiniPlayerView()
    private var miniSession: LiveTVSessionHandoff?

    // Shelves
    private struct Shelf {
        let id: String
        let title: String
        let items: [LiveCardItem]
    }

    private var collectionView: UICollectionView!
    /// Keyed by item id, so a card whose programme changes is refreshed in
    /// place instead of replaced (which would drop focus).
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var items: [String: LiveCardItem] = [:]
    private var shelfTitles: [String: String] = [:]

    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var cancellables = Set<AnyCancellable>()
    private var minuteTimer: Timer?
    private var backdropTask: Task<Void, Never>?
    private var backdropURL: URL?
    /// Something full screen is over the page (the player, multiview, the
    /// recordings list). Leaving for one of those is not leaving Live TV, so
    /// the corner player is not stopped for it.
    private var isCoveredByModal = false

    private static let timeFormat = Date.FormatStyle.dateTime.hour().minute()

    private enum Metrics {
        static let side: CGFloat = 90
        static let headerHeight: CGFloat = 470
        static let cardWidth: CGFloat = 400
        static let miniSize = CGSize(width: 448, height: 252)
    }

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
        setUpShelves()

        emptyLabel.text = "No channels yet. Add a Live TV source in Settings."
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

        let store = LiveTVDataStore.shared
        Publishers.CombineLatest4(store.$channels, store.$epg, store.$scheduledRecordings, store.$favoriteIds)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.rebuildShelves() }
            .store(in: &cancellables)
        store.$isLoadingChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in self?.updateEmptyState(loading: loading) }
            .store(in: &cancellables)

        Task { @MainActor in
            if store.channels.isEmpty { await store.loadChannels() }
            if store.epg.isEmpty { await store.loadEPG(startDate: Date(), hours: 12) }
            await store.refreshScheduledRecordings()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isCoveredByModal = false
        updateClock()
        rebuildShelves()
        minuteTimer?.invalidate()
        // What is on, and how far through, moves by the minute.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateClock()
                self?.rebuildShelves()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        minuteTimer?.invalidate()
        minuteTimer = nil
        // Another tab or page: the corner channel ends here, as in the guide.
        if !isCoveredByModal {
            stopMini()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropFade.frame = backdrop.bounds
        backdropSideFade.frame = backdrop.bounds
        CATransaction.commit()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [collectionView].compactMap { $0 }
    }

    // MARK: - Header

    private func setUpHeader() {
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        backdrop.alpha = 0
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        // Fades into the page at the bottom and under the text on the left.
        let page = UIColor(white: 0.06, alpha: 1)
        backdropFade.colors = [page.withAlphaComponent(0).cgColor, page.cgColor]
        backdropFade.locations = [0.45, 1]
        backdropSideFade.colors = [page.cgColor, page.withAlphaComponent(0).cgColor]
        backdropSideFade.startPoint = CGPoint(x: 0, y: 0.5)
        backdropSideFade.endPoint = CGPoint(x: 0.7, y: 0.5)
        backdrop.layer.addSublayer(backdropSideFade)
        backdrop.layer.addSublayer(backdropFade)

        eyebrowLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.font = .systemFont(ofSize: 56, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 26, weight: .medium)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        summaryLabel.font = .systemFont(ofSize: 24)
        summaryLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        summaryLabel.numberOfLines = 3
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        clockLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        miniPlayer.isHidden = true

        [eyebrowLabel, titleLabel, detailLabel, summaryLabel, clockLabel, miniPlayer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        let textWidth: CGFloat = 1000
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.68),
            backdrop.heightAnchor.constraint(equalToConstant: Metrics.headerHeight + 60),

            clockLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            clockLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.side),

            miniPlayer.topAnchor.constraint(equalTo: clockLabel.bottomAnchor, constant: 18),
            miniPlayer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.side),
            miniPlayer.widthAnchor.constraint(equalToConstant: Metrics.miniSize.width),
            miniPlayer.heightAnchor.constraint(equalToConstant: Metrics.miniSize.height),

            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.side),
            summaryLabel.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),
            summaryLabel.bottomAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.headerHeight - 30),

            detailLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),
            detailLabel.bottomAnchor.constraint(equalTo: summaryLabel.topAnchor, constant: -12),

            titleLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),
            titleLabel.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -6),

            eyebrowLabel.leadingAnchor.constraint(equalTo: summaryLabel.leadingAnchor),
            eyebrowLabel.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -8),
        ])
    }

    private func updateClock() {
        clockLabel.text = Date().formatted(Self.timeFormat)
    }

    /// Describe `item` in the header, and show its art behind.
    private func showInfo(for item: LiveCardItem) {
        let program = item.program
        let channel = item.channel
        let channelLine = [channel?.channelNumber.map(String.init), channel?.name]
            .compactMap { $0 }
            .joined(separator: " · ")

        var detail: [String] = []
        switch item.kind {
        case .channel:
            eyebrowLabel.text = "LIVE"
            eyebrowLabel.textColor = .systemRed
            titleLabel.text = program?.title ?? channel?.name
            if let program, !program.id.contains(":placeholder:") {
                detail.append("\(program.startTime.formatted(Self.timeFormat)) – \(program.endTime.formatted(Self.timeFormat))")
            }
            if !channelLine.isEmpty { detail.append(channelLine) }
        case .upcoming:
            eyebrowLabel.text = program.map { "STARTS \($0.startTime.formatted(Self.timeFormat))" }
            eyebrowLabel.textColor = UIColor.white.withAlphaComponent(0.8)
            titleLabel.text = program?.title
            if !channelLine.isEmpty { detail.append(channelLine) }
        case .recording:
            let recording = item.recording
            eyebrowLabel.text = recording?.status == .recording ? "RECORDING" : "SCHEDULED"
            eyebrowLabel.textColor = recording?.status == .recording ? .systemRed : UIColor.white.withAlphaComponent(0.8)
            titleLabel.text = recording?.title
            if let recording {
                detail.append("\(recording.startTime.formatted(.dateTime.weekday().hour().minute())) – \(recording.endTime.formatted(Self.timeFormat))")
            }
            if let name = recording?.channelName ?? channel?.name { detail.append(name) }
        }
        if let episode = program?.episodeNumber, !episode.isEmpty { detail.append(episode) }
        if let rating = program?.contentRating, !rating.isEmpty { detail.append(rating) }
        detailLabel.text = detail.joined(separator: " · ")
        var summary = program?.description
        if let subtitle = program?.subtitle ?? item.recording?.subtitle, !subtitle.isEmpty {
            summary = [subtitle, summary].compactMap { $0 }.joined(separator: ". ")
        }
        summaryLabel.text = summary

        let wideIcon = program?.iconURL.flatMap { EPGImageClassifier.shared.isLandscape($0) ? $0 : nil }
        setBackdrop(program?.landscapeURL ?? wideIcon ?? item.recording?.posterURL)
    }

    /// Crossfade to `url`, after focus has settled so a fast sweep along a
    /// shelf does not load every card's art.
    private func setBackdrop(_ url: URL?) {
        guard url != backdropURL else { return }
        backdropURL = url
        backdropTask?.cancel()
        guard let url else {
            UIView.animate(withDuration: 0.3) { self.backdrop.alpha = 0 }
            return
        }
        backdropTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled, self.backdropURL == url else { return }
            UIView.transition(with: self.backdrop, duration: 0.35, options: .transitionCrossDissolve) {
                self.backdrop.image = image
                self.backdrop.alpha = image == nil ? 0 : 0.9
            }
        }
    }

    // MARK: - Shelves

    private func setUpShelves() {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                heightDimension: .fractionalHeight(1)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .absolute(Metrics.cardWidth),
                                  heightDimension: .absolute(Metrics.cardWidth * LiveCardCell.aspect)),
                subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = .continuous
            section.interGroupSpacing = 40
            section.contentInsets = .init(top: 18, leading: Metrics.side, bottom: 56, trailing: Metrics.side)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(50)),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top)
            header.contentInsets = .init(top: 0, leading: Metrics.side, bottom: 0, trailing: Metrics.side)
            section.boundarySupplementaryItems = [header]
            return section
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = true
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(LiveCardCell.self, forCellWithReuseIdentifier: LiveCardCell.reuseID)
        collectionView.register(LiveShelfHeaderView.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: LiveShelfHeaderView.reuseID)
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        collectionView.addGestureRecognizer(TileLongPress.makeRecognizer(target: self, action: #selector(longPressed(_:))))

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.headerHeight),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, indexPath, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: LiveCardCell.reuseID, for: indexPath) as! LiveCardCell
            if let item = self?.items[id] { cell.configure(item) }
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] cv, kind, indexPath in
            let header = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: LiveShelfHeaderView.reuseID,
                                                             for: indexPath) as! LiveShelfHeaderView
            if let self, let shelf = self.dataSource.sectionIdentifier(for: indexPath.section) {
                header.title = self.shelfTitles[shelf]
            }
            return header
        }
    }

    private func channelsInScope() -> [UnifiedChannel] {
        let channels = LiveTVDataStore.shared.channels
        guard let sourceIdFilter else { return channels }
        return channels.filter { $0.sourceId == sourceIdFilter }
    }

    private func buildShelves(now: Date = Date()) -> [Shelf] {
        let store = LiveTVDataStore.shared
        let channels = channelsInScope()
        let channelsById = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var shelves: [Shelf] = []

        func onNow(_ list: [UnifiedChannel], section: String) -> [LiveCardItem] {
            list.map { .channel($0, program: store.getCurrentProgram(for: $0), section: section) }
        }

        // What is being recorded or about to be.
        let recordings = store.scheduledRecordings
            .filter { ($0.status == .scheduled || $0.status == .recording) && $0.endTime > now }
            .filter { sourceIdFilter == nil || $0.sourceId == sourceIdFilter }
            .sorted { $0.startTime < $1.startTime }
            .prefix(30)
            .map { recording in
                LiveCardItem.recording(recording, channel: recording.channelId.flatMap { channelsById[$0] })
            }
        if !recordings.isEmpty {
            shelves.append(Shelf(id: "recordings", title: "Recordings", items: recordings))
        }

        let favourites = channels
            .filter { $0.isFavourite || store.isFavorite($0) }
            .sorted { lhs, rhs in
                let left: (Int, Int) = (lhs.favouriteRank ?? Int.max, lhs.channelNumber ?? Int.max)
                let right: (Int, Int) = (rhs.favouriteRank ?? Int.max, rhs.channelNumber ?? Int.max)
                return left < right
            }
        if !favourites.isEmpty {
            shelves.append(Shelf(id: "favorites", title: "Favorites", items: onNow(favourites, section: "favorites")))
        }

        if !channels.isEmpty {
            shelves.append(Shelf(id: "now", title: "On Now", items: onNow(Array(channels.prefix(150)), section: "now")))
        }

        // The next programme on each channel that starts within the next
        // ninety minutes.
        let horizon = now.addingTimeInterval(90 * 60)
        let soon = channels
            .compactMap { channel -> LiveCardItem? in
                guard let next = store.getNextProgram(for: channel),
                      !next.id.contains(":placeholder:"),
                      next.startTime > now, next.startTime <= horizon else { return nil }
                return .upcoming(next, on: channel)
            }
            .sorted { ($0.program?.startTime ?? now) < ($1.program?.startTime ?? now) }
            .prefix(40)
        if !soon.isEmpty {
            shelves.append(Shelf(id: "soon", title: "Starting Soon", items: Array(soon)))
        }

        // A shelf per channel group, when the source groups at all.
        let groups = Dictionary(grouping: channels) {
            $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let groupTitles = groups.keys.filter { !$0.isEmpty }.sorted()
        if groupTitles.count > 1 {
            for title in groupTitles.prefix(16) {
                let id = "group|\(title)"
                let list = Array((groups[title] ?? []).prefix(60))
                shelves.append(Shelf(id: id, title: title, items: onNow(list, section: id)))
            }
        }

        return shelves.map { Shelf(id: $0.id, title: $0.title, items: $0.items.uniquedById()) }
    }

    private func rebuildShelves() {
        guard dataSource != nil else { return }
        let shelves = buildShelves()
        let previous = items
        var next: [String: LiveCardItem] = [:]
        var titles: [String: String] = [:]
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for shelf in shelves where !shelf.items.isEmpty {
            snapshot.appendSections([shelf.id])
            titles[shelf.id] = shelf.title
            let fresh = shelf.items.filter { next[$0.id] == nil }
            for item in fresh { next[item.id] = item }
            snapshot.appendItems(fresh.map(\.id), toSection: shelf.id)
        }
        let changed = next.values.filter { previous[$0.id] != nil && previous[$0.id] != $0 }.map(\.id)
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        items = next
        shelfTitles = titles
        dataSource.apply(snapshot, animatingDifferences: false)

        // Keep the header in step with a card whose programme just changed,
        // and give it something to say before anything has focus.
        if let focused = focusedItem() {
            showInfo(for: focused)
        } else if titleLabel.text == nil, let first = shelves.first(where: { !$0.items.isEmpty })?.items.first {
            showInfo(for: first)
        }
        updateEmptyState(loading: LiveTVDataStore.shared.isLoadingChannels)
    }

    private func updateEmptyState(loading: Bool) {
        let empty = items.isEmpty
        if empty && loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        emptyLabel.isHidden = !(empty && !loading)
    }

    private func focusedItem() -> LiveCardItem? {
        guard let indexPath = TileLongPress.focusedCell(in: collectionView),
              let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return items[id]
    }

    // MARK: - Actions

    private func activate(_ item: LiveCardItem, sourceFrame: CGRect?) {
        switch item.kind {
        case .channel:
            if let channel = item.channel { play(channel) }
        case .upcoming:
            presentMenu(for: item, sourceFrame: sourceFrame)
        case .recording:
            presentRecordings()
        }
    }

    private func presentMenu(for item: LiveCardItem, sourceFrame: CGRect?) {
        switch item.kind {
        case .channel, .upcoming:
            guard let channel = item.channel else { return }
            LiveProgramMenu.present(
                program: item.program,
                channel: channel,
                from: self,
                sourceFrame: sourceFrame,
                onWatch: { [weak self] channel in self?.play(channel) },
                onMultiview: { [weak self] channel in self?.openMultiview(adding: channel) }
            )
        case .recording:
            presentRecordings()
        }
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let indexPath = TileLongPress.focusedCell(in: collectionView),
              let id = dataSource.itemIdentifier(for: indexPath),
              let item = items[id] else { return }
        let frame = collectionView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        presentMenu(for: item, sourceFrame: frame)
    }

    /// Full screen with the showcase chrome. The corner channel comes back
    /// as it is; any other channel replaces it.
    private func play(_ channel: UnifiedChannel) {
        var adopting: LiveTVSessionHandoff?
        if let mini = takeMini() {
            if mini.channel.id == channel.id {
                adopting = mini
            } else {
                mini.stop()
            }
        }
        presentPlayer(LiveTVAetherPlayerViewController(channel: channel, chromeStyle: .showcase, adopting: adopting))
    }

    private func play(adopting session: LiveTVSessionHandoff) {
        stopMini()
        presentPlayer(LiveTVAetherPlayerViewController(channel: session.channel, chromeStyle: .showcase,
                                                       adopting: session))
    }

    private func presentPlayer(_ player: LiveTVAetherPlayerViewController) {
        player.modalPresentationStyle = .fullScreen
        let keepPlaying = UserDefaults.standard.object(forKey: "liveTVKeepPlayingInGuide") as? Bool ?? true
        if keepPlaying {
            player.onMinimize = { [weak self] session in self?.showMini(session) }
        }
        player.onOpenMultiview = { [weak self] session in
            self?.presentMultiview(adopting: session, adding: nil)
        }
        isCoveredByModal = true
        present(player, animated: true)
    }

    /// Multiview with the corner channel (when there is one) and `channel`.
    private func openMultiview(adding channel: UnifiedChannel) {
        presentMultiview(adopting: takeMini(), adding: channel)
    }

    private func presentMultiview(adopting session: LiveTVSessionHandoff?, adding channel: UnifiedChannel?) {
        let multiview = LiveMultiviewViewController(adopting: session, adding: channel)
        multiview.onWatchFullScreen = { [weak self] session in
            self?.play(adopting: session)
        }
        isCoveredByModal = true
        present(multiview, animated: true)
    }

    private func presentRecordings() {
        stopMini()
        let recordings = LiveRecordingsViewController()
        recordings.modalPresentationStyle = .fullScreen
        isCoveredByModal = true
        present(recordings, animated: true)
    }

    // MARK: - Corner player

    private func showMini(_ session: LiveTVSessionHandoff) {
        if let old = miniSession, old !== session { old.stop() }
        miniSession = session
        miniPlayer.show(session)
        miniPlayer.isHidden = false
        // Still watching, only smaller: no screensaver over it.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Hand the corner session to someone else, leaving the corner empty.
    private func takeMini() -> LiveTVSessionHandoff? {
        guard let session = miniSession else { return nil }
        miniSession = nil
        miniPlayer.release()
        miniPlayer.isHidden = true
        // Whoever takes the session over (player, multiview) holds the
        // screensaver off itself.
        UIApplication.shared.isIdleTimerDisabled = false
        return session
    }

    private func stopMini() {
        takeMini()?.stop()
    }
}

// MARK: - Collection delegate

extension LiveBrowseViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = items[id] else { return }
        let frame = collectionView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        activate(item, sourceFrame: frame)
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let indexPath = context.nextFocusedIndexPath,
              let id = dataSource.itemIdentifier(for: indexPath),
              let item = items[id] else { return }
        showInfo(for: item)
    }
}

// MARK: - Shelf header

final class LiveShelfHeaderView: UICollectionReusableView {
    static let reuseID = "LiveShelfHeaderView"

    private let label = UILabel()

    var title: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 32, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
