// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveBrowseViewController.swift
//  Rivulet
//
//  What's On, the default Live TV layout (the Guide is the other), after the
//  Apple TV app: shelves of 16:9 cards (recordings, favourites, what is on
//  now, what starts soon, genres, then each channel group) under a header
//  that describes whatever has focus.
//
//  Selecting a live card plays it full screen on the VOD glass rail. Back
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
    /// Also multiview's Add More rows (`LiveMultiviewViewController`).
    typealias Shelf = LiveShelf

    private var collectionView: UICollectionView!
    /// One section and one item per shelf, both keyed by the shelf id: each
    /// row is a `ShelfRowCell` (Home's self-scrolling row), whose content is
    /// pushed in by `configureRow` rather than diffed.
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var shelves: [String: Shelf] = [:]
    /// Resting horizontal offset per shelf, so a row keeps its place across
    /// cell reuse and rebuilds.
    private var shelfOffsets: [String: CGFloat] = [:]

    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var cancellables = Set<AnyCancellable>()
    private var minuteTimer: Timer?
    private var backdropTask: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?
    private var backdropURL: URL?
    /// Something full screen is over the page (the player, multiview, the
    /// recordings list). Leaving for one of those is not leaving Live TV, so
    /// the corner player is not stopped for it.
    private var isCoveredByModal = false

    private static let timeFormat = Date.FormatStyle.dateTime.hour().minute()

    private enum Metrics {
        /// The Browse page's margin: Apple's live-row margin, which its rows
        /// use too (see `MediaRowMetrics.liveLeading`).
        static let side: CGFloat = MediaRowMetrics.liveLeading
        static let top: CGFloat = MediaRowMetrics.rowLeading
        /// The clock's line at the top right, above the corner player.
        static let clockBand: CGFloat = 48
        /// The corner player: a card's size, rounded to exact 16:9 (a card's
        /// 406x228 is not, which leaves a hairline strip beside the picture).
        static let miniSize = CGSize(width: 400, height: 225)
        /// Just tall enough for the corner player; the description on the left
        /// fits in the same band. Anything more was empty space above the rows.
        static let headerHeight: CGFloat = top + clockBand + miniSize.height + 18
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
        Publishers.CombineLatest4(store.$channels, store.$epg, store.$scheduledRecordings,
                                 store.$favoriteIds.combineLatest(store.$unfavoritedIds))
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

            clockLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.top),
            clockLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.side),

            miniPlayer.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.top + Metrics.clockBand),
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
            let isLive = program?.isLiveAiring == true
            eyebrowLabel.text = isLive ? "LIVE" : "ON NOW"
            eyebrowLabel.textColor = isLive ? .systemRed : UIColor.white.withAlphaComponent(0.8)
            titleLabel.text = program?.displayTitle ?? channel?.name
            if let program, !program.id.contains(":placeholder:") {
                detail.append("\(program.startTime.formatted(Self.timeFormat)) – \(program.endTime.formatted(Self.timeFormat))")
            }
            if !channelLine.isEmpty { detail.append(channelLine) }
        case .upcoming:
            eyebrowLabel.text = program.map { "STARTS \(LiveCardItem.startLabel($0).uppercased())" }
            eyebrowLabel.textColor = UIColor.white.withAlphaComponent(0.8)
            titleLabel.text = program?.displayTitle
            if !channelLine.isEmpty { detail.append(channelLine) }
        case .recording:
            let recording = item.recording
            eyebrowLabel.text = recording?.status == .recording ? "RECORDING" : "SCHEDULED"
            eyebrowLabel.textColor = recording?.status == .recording ? .systemRed : UIColor.white.withAlphaComponent(0.8)
            titleLabel.text = recording.map { UnifiedProgram.displayTitle($0.title) }
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

        let art = EPGImageClassifier.shared.wideArt(for: program) ?? item.recording?.posterURL
        setBackdrop(art)
        measureTask?.cancel()
        // An icon with no declared size shows once it measures wide.
        guard art == nil, let icon = program?.iconURL,
              EPGImageClassifier.shared.kind(for: icon) == nil else { return }
        measureTask = Task { [weak self] in
            let kind = await EPGImageClassifier.shared.classify(icon) {
                await ImageCacheManager.shared.image(for: icon)?.size
            }
            guard let self, !Task.isCancelled, kind == .landscape else { return }
            self.setBackdrop(icon)
        }
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
        // Home's shelf layout: one full-bleed row per section, the row itself
        // carrying the page margin and the peeks (see `MediaRowMetrics`). An
        // orthogonal section cannot: its landings pin a card to the raw
        // screen edge, which is what knocked these rows out of line.
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let rowSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(MediaRowMetrics.liveHeight + MediaRowMetrics.focusGrowthPadding))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: rowSize,
                                                           subitems: [NSCollectionLayoutItem(layoutSize: rowSize)])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsetsReference = .none
            section.contentInsets = .init(top: MediaRowMetrics.rowTopInset, leading: 0,
                                          bottom: MediaRowMetrics.rowBottomInset, trailing: 0)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(40)),
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
        collectionView.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
        collectionView.register(HubHeaderView.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: HubHeaderView.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.headerHeight),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, indexPath, id in
            let row = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
            self?.configureRow(row, shelfId: id)
            return row
        }
        dataSource.supplementaryViewProvider = { [weak self] cv, kind, indexPath in
            let header = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: HubHeaderView.reuseID,
                                                             for: indexPath) as! HubHeaderView
            if let self, let id = self.dataSource.sectionIdentifier(for: indexPath.section) {
                header.configure(title: self.shelves[id]?.title ?? "", style: .swiftUIInfiniteRow)
            }
            return header
        }
    }

    /// Bind a row to one shelf. The tile provider captures the shelf VALUE,
    /// so the count the row is configured with and the cards it vends always
    /// come from the same snapshot.
    private func configureRow(_ row: ShelfRowCell, shelfId: String) {
        guard let shelf = shelves[shelfId] else { return }
        let cards = shelf.items
        row.cellProvider = { innerCV, indexPath in
            let cell = innerCV.dequeueReusableCell(withReuseIdentifier: LiveCardCell.reuseID,
                                                   for: indexPath) as! LiveCardCell
            if indexPath.item < cards.count { cell.configure(cards[indexPath.item]) }
            return cell
        }
        row.onSelect = { [weak self, weak row] index in
            guard index < cards.count else { return }
            self?.activate(cards[index], sourceFrame: row?.frameInWindow(forItem: index))
        }
        row.onLongPressItem = { [weak self, weak row] index in
            guard index < cards.count else { return }
            self?.presentMenu(for: cards[index], sourceFrame: row?.frameInWindow(forItem: index))
        }
        row.onFocusItem = { [weak self] index in
            guard index < cards.count else { return }
            self?.showInfo(for: cards[index])
        }
        row.onOffsetChanged = { [weak self] offset in
            self?.shelfOffsets[shelfId] = offset
        }
        // The token is the row's cards by identity only, so a programme
        // changing on one channel does not reload the row (reloadData re-vends
        // cells at new indices and drops focus). Changed content is pushed into
        // the cards already on screen instead, which also moves their progress.
        var token = Hasher()
        for card in cards { token.combine(card.id) }
        row.configure(kind: .live, realCount: cards.count, hasSkeleton: false,
                      contentToken: token.finalize(), initialOffset: shelfOffsets[shelfId] ?? 0)
        let inner = row.rowCollectionView!
        for case let cell as LiveCardCell in inner.visibleCells {
            guard let indexPath = inner.indexPath(for: cell), indexPath.item < cards.count else { continue }
            cell.configure(cards[indexPath.item])
        }
    }

    /// The What's On rows for a source (nil: every source). Static so
    /// multiview's Add More offers the same rows.
    static func buildShelves(sourceIdFilter: String?, now: Date = Date()) -> [Shelf] {
        LiveTVDataStore.shared.whatsOnShelves(sourceIdFilter: sourceIdFilter, now: now)
    }

    private func rebuildShelves() {
        guard dataSource != nil else { return }
        let built = Self.buildShelves(sourceIdFilter: sourceIdFilter).filter { !$0.items.isEmpty }
        shelves = Dictionary(built.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for shelf in built {
            snapshot.appendSections([shelf.id])
            snapshot.appendItems([shelf.id], toSection: shelf.id)
        }
        // A row's identity never changes, so diffing alone never reaches it.
        // Reconfiguring hands every existing row its new cards, the ones
        // prepared just off screen as well as the visible ones.
        snapshot.reconfigureItems(built.map(\.id).filter(existing.contains))
        dataSource.apply(snapshot, animatingDifferences: false)

        // Keep the header in step with a card whose programme just changed,
        // and give it something to say before anything has focus.
        if let focused = focusedItem() {
            showInfo(for: focused)
        } else if titleLabel.text == nil, let first = built.first?.items.first {
            showInfo(for: first)
        }
        updateEmptyState(loading: LiveTVDataStore.shared.isLoadingChannels)
    }

    private func updateEmptyState(loading: Bool) {
        let empty = shelves.isEmpty
        if empty && loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        emptyLabel.isHidden = !(empty && !loading)
    }

    private func focusedItem() -> LiveCardItem? {
        for case let row as ShelfRowCell in collectionView.visibleCells {
            guard let index = row.focusedItemIndex(),
                  let indexPath = collectionView.indexPath(for: row),
                  let id = dataSource.itemIdentifier(for: indexPath),
                  let cards = shelves[id]?.items, index < cards.count else { continue }
            return cards[index]
        }
        return nil
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

    /// Full screen on the glass rail. The corner channel comes back
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
        presentPlayer(LiveTVAetherPlayerViewController(channel: channel, adopting: adopting))
    }

    /// `animated: false` when multiview has just grown the tile full screen.
    private func play(adopting session: LiveTVSessionHandoff, animated: Bool = true) {
        stopMini()
        presentPlayer(LiveTVAetherPlayerViewController(channel: session.channel,
                                                       adopting: session), animated: animated)
    }

    private func presentPlayer(_ player: LiveTVAetherPlayerViewController, animated: Bool = true) {
        player.modalPresentationStyle = .fullScreen
        let keepPlaying = UserDefaults.standard.object(forKey: "liveTVKeepPlayingInGuide") as? Bool ?? true
        if keepPlaying {
            player.onMinimize = { [weak self] session in self?.showMini(session) }
        }
        player.onOpenMultiview = { [weak self] session in
            self?.presentMultiview(adopting: session, adding: nil, fromPlayer: true)
        }
        isCoveredByModal = true
        present(player, animated: animated)
    }

    /// Multiview with the corner channel (when there is one) and `channel`.
    private func openMultiview(adding channel: UnifiedChannel) {
        presentMultiview(adopting: takeMini(), adding: channel)
    }

    /// `fromPlayer`: the full-screen player just closed without animation, and
    /// multiview takes over its picture (see `entersFromFullScreen`).
    private func presentMultiview(adopting session: LiveTVSessionHandoff?, adding channel: UnifiedChannel?,
                                  fromPlayer: Bool = false) {
        let multiview = LiveMultiviewViewController(adopting: session, adding: channel,
                                                    sourceIdFilter: sourceIdFilter)
        multiview.entersFromFullScreen = fromPlayer
        multiview.onWatchFullScreen = { [weak self] session in
            self?.play(adopting: session, animated: false)
        }
        isCoveredByModal = true
        present(multiview, animated: !fromPlayer)
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
