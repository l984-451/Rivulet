// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  A season's own page: its poster blurred behind and large on the right, its episodes in a vertical list of the show page's episode cards laid side by side. Plays through the item's
//  provider, so every entry point opens the same page. Menu returns.

import Combine
import UIKit

final class SeasonDetailViewController: UIViewController, UICollectionViewDelegate {

    private var season: MediaItem
    private var episodes: [MediaItem] = []
    private var episodesByID: [String: MediaItem] = [:]
    private var showTitle: String?
    private var seasonDetail: MediaItemDetail?
    private var showDetail: MediaItemDetail?
    private var ageRating: String?
    private var provider: (any MediaProvider)? { MediaProviderRegistry.shared.provider(for: season.ref.providerID) }

    private let background = UIImageView()
    private let themeVideo = ThemeVideoBackdropView()
    private let poster = UIImageView()
    private var collectionView: FocusScrollControlledCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    private let header = UIStackView()
    private let showTitleLabel = UILabel()
    private let logoView = UIImageView()
    private let metaRow = UIStackView()
    private let overviewLabel = UILabel()
    private var playButton: FocusableActionButton?
    private weak var playTitleLabel: UILabel?
    private weak var watchedButton: FocusableActionButton?
    private var isWatched: Bool

    private let blurFade = BlurFadeTransitioningDelegate()
    private var refreshObservers = Set<AnyCancellable>()
    private var loadToken: UInt64 = 0
    /// Go to Episode's episode: focused once its row exists, then forgotten.
    private var pendingFocusEpisodeID: String?

    private static let headerID = "header"
    private static let extrasID = "extras"
    /// The season's trailers and extras, in a row under the episodes.
    private let extrasShelf = ExtrasShelfView(leading: MediaRowMetrics.rowLeading)
    private static let posterSize = CGSize(width: 600, height: 900)
    /// The header's top meets the vertically centred poster's.
    private static let headerTop: CGFloat = (1080 - posterSize.height) / 2
    private static let logoHeight: CGFloat = 126
    private static let logoMaxWidth: CGFloat = 420

    init(season: MediaItem, showTitle: String? = nil, focusingEpisodeID: String? = nil) {
        self.season = season
        self.showTitle = showTitle ?? season.seriesTitle
        self.pendingFocusEpisodeID = focusingEpisodeID
        self.isWatched = season.isWatched
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = blurFade
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Go to Episode: the episode's season page, opened on it. `fallback` runs when the season can't be read.
    static func open(focusing episode: MediaItem, from presenter: UIViewController, fallback: @escaping () -> Void) {
        guard let seasonRef = episode.parentRef, !seasonRef.itemID.isEmpty,
              let provider = MediaProviderRegistry.shared.provider(for: episode.ref.providerID) else { return fallback() }
        Task { @MainActor in
            guard let season = try? await provider.fullDetail(for: seasonRef).item else { return fallback() }
            let page = SeasonDetailViewController(season: season, focusingEpisodeID: episode.ref.itemID)
            presenter.topmostPresented.present(page, animated: true)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        background.contentMode = .scaleAspectFill
        background.clipsToBounds = true
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        for layer in [background, themeVideo, blur] as [UIView] {
            layer.frame = view.bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(layer)
        }
        themeVideo.configure(item: season.ref, host: self)

        poster.translatesAutoresizingMaskIntoConstraints = false
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        poster.layer.cornerRadius = 16
        poster.layer.cornerCurve = .continuous
        poster.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        view.addSubview(poster)

        buildHeader()
        buildCollection()

        NSLayoutConstraint.activate([
            poster.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            poster.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -MediaRowMetrics.rowTrailing),
            poster.widthAnchor.constraint(equalToConstant: Self.posterSize.width),
            poster.heightAnchor.constraint(equalToConstant: Self.posterSize.height),

            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: poster.leadingAnchor, constant: -MediaRowMetrics.tileGap),
        ])

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(dismissSelf))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)

        extrasShelf.onPlay = { [weak self] trailer in
            guard let self else { return }
            ExtraPlayer.play(trailer, from: self)
        }
        applySnapshot()
        loadArtwork()
        load()

        // Playback and the menus' watched actions post this once the server has the change.
        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.load() }
            .store(in: &refreshObservers)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        themeVideo.setActive(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        themeVideo.setActive(false)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let id = pendingFocusEpisodeID, let indexPath = dataSource.indexPath(for: id),
           let cell = collectionView.cellForItem(at: indexPath) as? SeasonEpisodeCell {
            return [cell.episodeView]
        }
        return playButton.map { [$0] } ?? super.preferredFocusEnvironments
    }

    // Focus enters on the system's own update after the entrance: a request from
    // viewDidAppear is dropped, because focus is still on the presenter then.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Once only, after the episodes were there to land on: a later refresh must not pull focus back.
        if !episodes.isEmpty, context.nextFocusedView?.isDescendant(of: view) == true { pendingFocusEpisodeID = nil }
    }

    /// Scrolls the pending episode's row to the centre, where focus will keep it, so its cell
    /// exists for `preferredFocusEnvironments`; then asks for focus.
    private func focusPendingEpisode() {
        if let id = pendingFocusEpisodeID, let indexPath = dataSource.indexPath(for: id) {
            collectionView.layoutIfNeeded()
            if let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame {
                let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
                collectionView.contentOffset.y = min(max(0, frame.midY - collectionView.bounds.height / 2), maxY)
                collectionView.layoutIfNeeded()
            }
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    // MARK: - Build

    private func buildHeader() {
        header.translatesAutoresizingMaskIntoConstraints = false
        header.axis = .vertical
        header.alignment = .leading
        header.spacing = 18

        // The show's logo, as the show page leads with; its name until (or unless) one loads.
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.contentMode = .scaleAspectFit
        logoView.isHidden = true
        logoView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.logoHeight).isActive = true
        header.addArrangedSubview(logoView)
        header.setCustomSpacing(24, after: logoView)
        style(showTitleLabel, size: 38, weight: .bold, alpha: 0.5)
        header.addArrangedSubview(showTitleLabel)
        header.setCustomSpacing(6, after: showTitleLabel)

        let titleLabel = UILabel()
        style(titleLabel, size: 48, weight: .bold, alpha: 1)
        titleLabel.text = season.title
        header.addArrangedSubview(titleLabel)

        // Episodes and year, the age rating, the score and the Common Sense age.
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        metaRow.spacing = 12
        header.addArrangedSubview(metaRow)

        style(overviewLabel, size: 23, weight: .medium, alpha: 0.9)
        overviewLabel.numberOfLines = 3
        overviewLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 860).isActive = true
        header.addArrangedSubview(overviewLabel)
        applyText()

        let (pill, title, _) = FocusableActionButton.pill(title: String(localized: "Play"), systemImage: "play.fill")
        pill.onPrimaryAction = { [weak self] in
            guard let self else { return }
            self.play(EpisodePicker.firstUnplayed(in: self.episodes) ?? self.season, fromBeginning: false)
        }
        playButton = pill
        playTitleLabel = title
        let watched = FocusableActionButton.circle(systemImage: watchedGlyph)
        watched.onPrimaryAction = { [weak self] in self?.toggleWatched() }
        watchedButton = watched
        let info = FocusableActionButton.circle(systemImage: "text.page")
        info.onPrimaryAction = { [weak self] in self?.presentInfoPopup() }
        let actions = UIStackView(arrangedSubviews: [pill, watched, info])
        actions.axis = .horizontal
        actions.spacing = HeroPillButton.rowGap
        actions.alignment = .center
        header.setCustomSpacing(32, after: overviewLabel)
        header.addArrangedSubview(actions)
    }

    private func buildCollection() {
        let layout = UICollectionViewCompositionalLayout { index, _ in
            let height: NSCollectionLayoutDimension = index == 0
                ? .estimated(400) : .absolute(index == 2 ? ExtrasShelfView.height : EpisodeCell.thumbHeight)
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: height)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            // Measured from the screen edge, not tvOS's safe area, so the margin is the app's 80.
            section.contentInsetsReference = .none
            // Each card's focus reserve already puts one grid gap between artworks.
            // The extras row insets itself, so its cards' focus growth is not clipped.
            section.contentInsets = index == 0
                ? .init(top: Self.headerTop, leading: MediaRowMetrics.rowLeading, bottom: 40, trailing: 0)
                : .init(top: 0, leading: index == 2 ? 0 : MediaRowMetrics.rowLeading, bottom: 80, trailing: 0)
            return section
        }
        collectionView = FocusScrollControlledCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        // The header pins at the top; every episode row centres (see the class).
        collectionView.isScrollEnabled = false
        collectionView.topSectionIndex = 0
        collectionView.topBand = Self.headerTop
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        collectionView.delegate = self
        collectionView.register(HostCell.self, forCellWithReuseIdentifier: HostCell.reuseID)
        collectionView.register(SeasonEpisodeCell.self, forCellWithReuseIdentifier: SeasonEpisodeCell.reuseID)
        view.addSubview(collectionView)

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, indexPath, id in
            guard let self else { return UICollectionViewCell() }
            if id == Self.headerID {
                let cell = cv.dequeueReusableCell(withReuseIdentifier: HostCell.reuseID, for: indexPath) as! HostCell
                cell.host(self.header)
                return cell
            }
            if id == Self.extrasID {
                let cell = cv.dequeueReusableCell(withReuseIdentifier: HostCell.reuseID, for: indexPath) as! HostCell
                cell.host(self.extrasShelf, fillsWidth: true)
                return cell
            }
            let cell = cv.dequeueReusableCell(withReuseIdentifier: SeasonEpisodeCell.reuseID, for: indexPath) as! SeasonEpisodeCell
            if let episode = self.episodesByID[id] { self.configure(cell, with: episode) }
            return cell
        }
    }

    private func configure(_ cell: SeasonEpisodeCell, with episode: MediaItem) {
        cell.episodeView.configure(episode: episode)
        cell.episodeView.onPlay = { [weak self] in self?.play(episode, fromBeginning: false) }
        cell.episodeView.onShowDetails = { [weak self] in self?.presentEpisodePage(episode) }
        cell.episodeView.onLongPress = { [weak self] frame in
            guard let self else { return }
            EpisodeMenu.present(for: episode, from: self, sourceFrame: frame,
                                play: { [weak self] sourceID, fromBeginning in
                                    self?.play(episode, sourceID: sourceID, fromBeginning: fromBeginning)
                                },
                                moreInfo: { [weak self] in self?.presentEpisodePage(episode) })
        }
    }

    /// The cells are not focus stops; the header's buttons and each card's thumb and text are.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { false }

    // MARK: - Data

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems([Self.headerID], toSection: 0)
        let ids = episodes.map(\.ref.itemID)
        snapshot.appendItems(ids, toSection: 1)
        if !extrasShelf.tiles.isEmpty {
            snapshot.appendSections([2])
            snapshot.appendItems([Self.extrasID], toSection: 2)
        }
        // Same ids after a refresh: reconfigure so watched state repaints in place, and the
        // self-sizing header re-measures.
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(([Self.headerID] + ids).filter(existing.contains))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func load() {
        guard let provider else { return }
        loadToken &+= 1
        let token = loadToken
        let ref = season.ref
        let showRef = season.parentRef
        Task { [weak self] in
            let children = (try? await provider.children(of: ref)) ?? []
            let detail = try? await provider.fullDetail(for: ref)
            var show: MediaItemDetail?
            if let showRef { show = try? await provider.fullDetail(for: showRef) }
            guard let self, self.loadToken == token else { return }
            if let show { self.showDetail = show; self.showTitle = show.item.title }
            if let detail {
                self.seasonDetail = detail; self.season = detail.item
                let split = BelowFoldContentLoader.extraTiles(
                    from: detail.extras,
                    fallbackArt: detail.item.artwork.backdrop ?? detail.item.parentArtwork?.backdrop ?? detail.item.artwork.thumbnail,
                    youTubeVideoID: detail.youTubeTrailerID, providerID: detail.item.ref.providerID)
                self.extrasShelf.configure(split.trailers + split.extras)
            }
            self.episodes = EpisodePicker.inPlaybackOrder(children)
            self.episodesByID = Dictionary(self.episodes.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
            if !self.episodes.isEmpty { self.isWatched = self.episodes.allSatisfy(\.isWatched) }
            self.applyText()
            self.applySnapshot()
            if self.pendingFocusEpisodeID != nil { self.focusPendingEpisode() }
            self.loadLogo()
            if self.ageRating == nil, let showRef { self.loadAgeRating(showRef) }
        }
    }

    /// Common Sense, from Plex Discover: after the page is up, so it never holds the episodes.
    private func loadAgeRating(_ showRef: MediaItemRef) {
        guard let provider else { return }
        Task { [weak self] in
            guard let advisory = (try? await provider.contentAdvisory(for: showRef)) ?? nil,
                  let self else { return }
            self.showDetail?.contentAdvisory = advisory
            self.ageRating = advisory.ageRating
            self.applyText()
        }
    }

    private func applyText() {
        showTitleLabel.text = showTitle
        showTitleLabel.isHidden = (showTitle ?? "").isEmpty || !logoView.isHidden
        overviewLabel.text = season.overview
        overviewLabel.isHidden = (season.overview ?? "").isEmpty
        playTitleLabel?.text = EpisodePicker.firstUnplayed(in: episodes)
            .map { EpisodePicker.playTitle(for: $0, on: .season) } ?? String(localized: "Play")
        watchedButton?.setIcon(watchedGlyph)

        metaRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let count = episodes.isEmpty ? season.childProgress?.total : episodes.count
        let parts = [count.map { String(localized: "\($0) Episodes") }, season.year.map(String.init)].compactMap { $0 }
        if !parts.isEmpty {
            metaRow.addArrangedSubview(MediaDetailChromeView.makeCaptionLabel(parts.joined(separator: " · "), alpha: 0.75))
        }
        // A season rarely carries its own rating or score; the show's stand in.
        if let rated = seasonDetail?.contentRating ?? showDetail?.contentRating, !rated.isEmpty {
            metaRow.addArrangedSubview(MediaDetailChromeView.makeBadge(rated, alpha: 0.75))
        }
        MediaDetailChromeView.scoreAndAgeViews(ratings: scoreRatings, age: ageRating, alpha: 0.75)
            .forEach(metaRow.addArrangedSubview)
        metaRow.isHidden = metaRow.arrangedSubviews.isEmpty
    }

    private var scoreRatings: [MediaRating] {
        let own = seasonDetail?.ratings ?? []
        return own.isEmpty ? showDetail?.ratings ?? [] : own
    }

    private func loadLogo() {
        guard logoView.isHidden, let url = showDetail?.item.artwork.logo ?? season.parentArtwork?.logo else { return }
        Task { [weak self] in
            guard let image = await ImageCacheManager.shared.image(for: url), image.size.height > 0,
                  let self, self.logoView.isHidden else { return }
            // Fill the slot's height unless that breaks the width cap; aspect keeps it from centring.
            let aspect = image.size.width / image.size.height
            let height = min(Self.logoHeight, Self.logoMaxWidth / aspect)
            self.logoView.image = image
            NSLayoutConstraint.activate([
                self.logoView.widthAnchor.constraint(equalToConstant: height * aspect),
                self.logoView.heightAnchor.constraint(equalToConstant: height),
            ])
            self.logoView.isHidden = false
            self.applyText()
            self.relayoutHeader()
        }
    }

    /// The header's cell sizes itself; tell the layout when its content changes height.
    private func relayoutHeader() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([Self.headerID])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func presentInfoPopup() {
        guard var detail = seasonDetail ?? showDetail else { return }
        if detail.ratings.isEmpty { detail.ratings = scoreRatings }
        if detail.contentAdvisory == nil { detail.contentAdvisory = showDetail?.contentAdvisory }
        let show = showDetail
        Task { [weak self] in
            // The popup's ratings row wants the Worker's scores too, as the show page's does.
            if let show {
                let extra = await RatingsClient.shared.ratings(for: show, within: 1)
                if !extra.isEmpty { detail.ratings = MediaRating.ordered(detail.ratings + extra) }
            }
            guard let self else { return }
            let content = InfoPopupContent.fullInfo(detail: detail)
            self.present(InfoPopupViewController(content: content, width: InfoPopupViewController.infoWidth,
                                                 height: 900, scrollable: true), animated: true)
        }
    }

    private var watchedGlyph: String { isWatched ? "checkmark.circle.fill" : "checkmark" }

    private func loadArtwork() {
        guard let url = season.artwork.poster ?? season.parentArtwork?.poster else { return }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .full)
            self?.background.image = image
            self?.poster.image = image
        }
    }

    // MARK: - Actions

    private func play(_ item: MediaItem, sourceID: String? = nil, fromBeginning: Bool) {
        ProviderPlayer.play(item, fromBeginning: fromBeginning, sourceID: sourceID, from: self, onDismiss: nil)
    }

    private func presentEpisodePage(_ episode: MediaItem) {
        let page = MediaItemDetailPageViewController(
            item: episode, seriesTitle: showTitle,
            onPlay: { [weak self] ep, sourceID in self?.play(ep, sourceID: sourceID, fromBeginning: false) })
        present(page, animated: true)
    }

    private func toggleWatched() {
        isWatched.toggle()
        watchedButton?.setIcon(watchedGlyph)
        let target = isWatched
        let ref = season.ref
        guard let provider else { return }
        Task {
            if target { try? await provider.markPlayed(ref) } else { try? await provider.markUnplayed(ref) }
            // Every surface re-reads, this page too, so a failed mark falls back to the server.
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
        }
    }

    private func style(_ label: UILabel, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = UIColor.white.withAlphaComponent(alpha)
        label.numberOfLines = 2
    }
}

/// One episode row: the show page's card with its description beside the thumb.
private final class SeasonEpisodeCell: UICollectionViewCell {
    static let reuseID = "SeasonEpisodeCell"
    let episodeView = EpisodeCell(layout: .sideBySide)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(episodeView)
        NSLayoutConstraint.activate([
            episodeView.topAnchor.constraint(equalTo: contentView.topAnchor),
            episodeView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            episodeView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        episodeView.onPlay = nil
        episodeView.onShowDetails = nil
        episodeView.onLongPress = nil
        episodeView.resetFocusVisual()
    }
}

/// Holds the page's one header view, which moves into whichever cell shows it.
private final class HostCell: UICollectionViewCell {
    static let reuseID = "HostCell"

    /// A recycled cell must not keep the view it hosted, or it shows under the next one.
    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.subviews.forEach { $0.removeFromSuperview() }
    }

    func host(_ view: UIView, fillsWidth: Bool = false) {
        guard view.superview !== contentView else { return }
        view.removeFromSuperview()
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            fillsWidth ? view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
                       : view.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
}

/// The episode long-press menu on the show and season pages: Home's tile menu, less the Go to
/// entries, which lead back to the page it opens on.
@MainActor
enum EpisodeMenu {
    static func present(for episode: MediaItem, from host: UIViewController, sourceFrame: CGRect,
                        play: @escaping (_ sourceID: String?, _ fromBeginning: Bool) -> Void,
                        moreInfo: @escaping () -> Void) {
        guard host.presentedViewController == nil,
              let provider = MediaProviderRegistry.shared.provider(for: episode.ref.providerID) else { return }
        Task { @MainActor [weak host] in
            let refresh = await provider.canRefreshMetadata()
            guard let host, host.presentedViewController == nil else { return }
            var sections = PlexHomeViewController.providerTileMenuSections(
                for: episode, provider: provider, isContinueWatching: false, canRefreshMetadata: refresh,
                onWatchFromBeginning: { play(nil, true) },
                onMoreInfo: moreInfo,
                onPlayVersion: { [weak host] in
                    Task { @MainActor in
                        guard let host, let detail = try? await provider.fullDetail(for: episode.ref) else { return }
                        VersionPicker.present(VersionPicker.versions(in: detail), from: host, sourceFrame: sourceFrame) {
                            play($0, false)
                        }
                    }
                },
                onAddToPlaylist: { [weak host] in
                    guard let host else { return }
                    PlaylistMenus.presentAddToPlaylist(for: episode, from: host, sourceFrame: sourceFrame)
                })
            sections = await PlexHomeViewController.addingServerEntries(to: sections, for: episode,
                                                                        provider: provider, from: host)
            guard host.presentedViewController == nil else { return }
            // animated: false; the popup runs its own entrance from the thumb.
            host.present(TileMenuPopupViewController(sections: sections, sourceFrame: sourceFrame), animated: false)
        }
    }
}
