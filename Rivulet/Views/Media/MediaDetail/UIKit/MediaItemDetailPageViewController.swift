// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The title-first detail page for any MediaItem (Docs/atv_ref/episode_details_ref.JPG,
//  episode_details_bottom_ref.JPG), blur-faded in over the carousel; Menu returns.

import Combine
import UIKit

/// The Apple TV app's product-page scrim, so the title stack stays readable
/// over any backdrop. Each layer fills the hero page.
private final class ScrimGradientView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for layer in GradientView.productPageScrim() {
            layer.frame = bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(layer)
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class MediaItemDetailPageViewController: UIViewController {

    /// Mutable so a post-playback refresh can swap in the re-fetched copy
    /// (issue #228). The ref never changes — only the user state does.
    private var item: MediaItem
    private let onPlay: (MediaItem, String?) -> Void

    private let backdrop = UIImageView()
    private let scrim = ScrimGradientView()
    private let textColumn = UIStackView()

    // Scroll: a fixed backdrop behind a transparent scroll view. The scroll
    // content is the hero page (one viewport) + the below-fold info columns.
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let heroContent = UIView()
    private let belowFold = UIView()
    private let belowFoldTitle = UILabel()
    private let infoColumns = InfoColumnsView()
    private var scrolledDown = false

    // Hero rows (async-filled ones start hidden so the stack doesn't reserve a gap).
    private let showTitleLabel = UILabel()
    private let genreRatingRow = UIStackView()
    private let genreLabel = UILabel()
    private let ratingBadge = MediaItemDetailPageViewController.badge()
    private let synopsisLabel = UILabel()
    private let descriptionIndicator = DescriptionTranslationView()
    private let descriptionTranslation = SiloDescriptionTranslationController()
    private var descriptionObservers = Set<AnyCancellable>()
    private var latestDetail: MediaItemDetail?
    private var allowsAutomaticDescriptionTranslation = false
    private let metadataSpacer = UIView()
    private let dateRow = UIStackView()
    private let dateLabel = UILabel()
    private let capabilityBadges = MediaCapabilityBadgesView()
    private let ratingsView = RatingsGridView()
    private var preferredTextColumnWidth: NSLayoutConstraint?
    private weak var infoButton: FocusableActionButton?
    private var themeTask: Task<Void, Never>?
    private var playButton: FocusableActionButton?
    /// The Play pill's own label, held so a post-playback refresh can flip
    /// Play ↔ Resume without rebuilding (and re-focusing) the action row.
    private weak var playTitleLabel: UILabel?
    private weak var watchedButton: FocusableActionButton?
    private weak var watchlistButton: FocusableActionButton?
    private weak var actionRow: UIStackView?
    private weak var versionsButton: FocusableActionButton?
    private var onWatchlist = false
    /// The show above this episode, kept from `loadDetail` so Go to Show opens
    /// without a second fetch.
    private var show: MediaItem?

    private var isWatched: Bool
    private let blurFade = BlurFadeTransitioningDelegate()
    private var provider: MediaProvider? { MediaProviderRegistry.shared.provider(for: item.ref.providerID) }

    init(item: MediaItem, seriesTitle: String?, onPlay: @escaping (MediaItem, String?) -> Void) {
        self.item = item
        self.onPlay = onPlay
        self.isWatched = item.isWatched
        self.resumeOffset = item.userState.viewOffset
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = blurFade      // blur-fade present/dismiss
        if let seriesTitle, !seriesTitle.isEmpty { setShowTitle(seriesTitle) }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        descriptionTranslation.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDescriptionTranslation() }
            .store(in: &descriptionObservers)

        // Fixed backdrop behind everything.
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        view.addSubview(backdrop)

        // Transparent scroll view (driven by Down/Up, not the focus engine).
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isScrollEnabled = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        // Hero page (one viewport tall): scrim + the title/actions column.
        heroContent.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(heroContent)
        scrim.translatesAutoresizingMaskIntoConstraints = false
        heroContent.addSubview(scrim)
        buildTextColumn(into: heroContent)
        buildBelowFold()

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            heroContent.topAnchor.constraint(equalTo: contentView.topAnchor),
            heroContent.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            heroContent.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            heroContent.heightAnchor.constraint(equalTo: view.heightAnchor),

            scrim.topAnchor.constraint(equalTo: heroContent.topAnchor),
            scrim.leadingAnchor.constraint(equalTo: heroContent.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: heroContent.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: heroContent.bottomAnchor),

            textColumn.leadingAnchor.constraint(equalTo: heroContent.leadingAnchor, constant: PreviewCarouselGeometry.expandedChromeInset),
            textColumn.bottomAnchor.constraint(equalTo: heroContent.safeAreaLayoutGuide.bottomAnchor, constant: -115),   // measured on device, tvOS 27
            textColumn.topAnchor.constraint(greaterThanOrEqualTo: heroContent.safeAreaLayoutGuide.topAnchor, constant: 40),
            textColumn.widthAnchor.constraint(lessThanOrEqualToConstant: 1060),
            textColumn.widthAnchor.constraint(lessThanOrEqualTo: heroContent.widthAnchor,
                                               constant: -2 * PreviewCarouselGeometry.expandedChromeInset),

            belowFold.topAnchor.constraint(equalTo: heroContent.bottomAnchor),
            belowFold.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            belowFold.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            belowFold.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(dismissSelf))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)

        loadBackdrop()
        loadDetail()

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.view.window != nil, self.presentedViewController == nil else { return }
                SiloThemeMusicController.shared.resume()
                self.activateThemeForVisiblePage()
            }
            .store(in: &refreshObservers)

        // Issue #228: this page is seeded from an immutable snapshot, so
        // playing the episode and coming back left it showing the old state.
        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshWatchState()
            }
            .store(in: &refreshObservers)
    }

    // MARK: - Down/Up page scroll

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A press the version picker declines bubbles here; it must not scroll the page.
        guard presentedViewController == nil else { super.pressesBegan(presses, with: event); return }
        for press in presses {
            switch press.type {
            case .downArrow where !scrolledDown:
                setScrolledDown(true); return
            case .upArrow where scrolledDown:
                setScrolledDown(false); return
            default: break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    private func setScrolledDown(_ down: Bool) {
        scrolledDown = down
        view.layoutIfNeeded()
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        // Scroll so the below-fold's TOP aligns with the screen top (one
        // viewport), making the light-top / dark-bottom split fill the screen.
        let target = down ? min(view.bounds.height, maxY) : 0
        UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseInOut]) {
            self.scrollView.contentOffset = CGPoint(x: 0, y: target)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let playButton { return [playButton] }
        return super.preferredFocusEnvironments
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        allowsAutomaticDescriptionTranslation = true
        configureDescriptionTranslation()
        activateThemeForVisiblePage()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func activateThemeForVisiblePage() {
        if let silo = provider as? SiloProvider,
           SiloSession.account?.providerID == silo.id,
           SiloSession.authorityRevision == silo.authorityRevision {
            themeTask?.cancel()
            themeTask = Task { [weak self] in
                await SiloThemeMusicController.shared.refresh(provider: silo)
                guard let self, !Task.isCancelled, self.view.window != nil,
                      self.presentedViewController == nil,
                      SiloSession.account?.providerID == silo.id,
                      SiloSession.authorityRevision == silo.authorityRevision else { return }
                await SiloThemeMusicController.shared.activate(ownerID: self.item.ref.itemID, provider: silo)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        allowsAutomaticDescriptionTranslation = false
        themeTask?.cancel()
        themeTask = nil
        SiloThemeMusicController.shared.stop()
        descriptionTranslation.stop()
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    // MARK: - Build

    private func buildTextColumn(into parent: UIView) {
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.axis = .vertical
        textColumn.alignment = .leading
        // Apple's rhythm: 18 between rows, 6 under the show name, 32 above the buttons.
        textColumn.spacing = 18
        parent.addSubview(textColumn)

        // 1. Show title (small) — filled by setShowTitle (init or fetch).
        style(showTitleLabel, size: 38, weight: .bold, alpha: 0.5)
        showTitleLabel.isHidden = (showTitleLabel.text ?? "").isEmpty
        textColumn.addArrangedSubview(showTitleLabel)
        textColumn.setCustomSpacing(6, after: showTitleLabel)

        // 2. Episode/item title (large). Both titles cap at 600 wide.
        let titleLabel = label(item.title, size: 48, weight: .bold, alpha: 1)
        textColumn.addArrangedSubview(titleLabel)
        for l in [showTitleLabel, titleLabel] {
            l.widthAnchor.constraint(lessThanOrEqualToConstant: 600).isActive = true
        }

        // 3. Genre · rating.
        genreRatingRow.axis = .horizontal
        genreRatingRow.alignment = .center
        genreRatingRow.spacing = 6
        style(genreLabel, size: 25, weight: .medium, alpha: 1)
        genreRatingRow.addArrangedSubview(genreLabel)
        if let rating = item.contentRating, !rating.isEmpty {
            ratingBadge.text = rating
            genreRatingRow.addArrangedSubview(ratingBadge)
        } else {
            ratingBadge.isHidden = true
        }
        genreRatingRow.isHidden = (item.contentRating ?? "").isEmpty   // until genres load
        textColumn.addArrangedSubview(genreRatingRow)

        // 4. Synopsis with a bold "S2, E1:" prefix.
        style(synopsisLabel, size: 23, weight: .medium, alpha: 0.9)
        synopsisLabel.numberOfLines = 3
        synopsisLabel.lineBreakMode = .byTruncatingTail
        synopsisLabel.setContentHuggingPriority(.required, for: .vertical)
        synopsisLabel.setContentCompressionResistancePriority(.init(749), for: .vertical)
        synopsisLabel.attributedText = synopsisAttributed()
        synopsisLabel.isHidden = (synopsisLabel.attributedText?.length ?? 0) == 0
        synopsisLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 860).isActive = true
        textColumn.addArrangedSubview(synopsisLabel)

        // 5. Date/runtime, source capabilities and review marks size independently.
        dateRow.axis = .horizontal
        dateRow.alignment = .center
        dateRow.spacing = 12
        style(dateLabel, size: 25, weight: .medium, alpha: 0.75)
        dateLabel.text = dateRuntimeText()
        dateRow.addArrangedSubview(dateLabel)
        dateRow.addArrangedSubview(descriptionIndicator)
        dateRow.setContentHuggingPriority(.required, for: .vertical)
        textColumn.addArrangedSubview(dateRow)
        textColumn.addArrangedSubview(metadataSpacer)
        let collapsedSpacer = metadataSpacer.heightAnchor.constraint(equalToConstant: 0)
        collapsedSpacer.priority = .init(1)
        collapsedSpacer.isActive = true
        metadataSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        metadataSpacer.widthAnchor.constraint(equalToConstant: 0).isActive = true
        let metadataViews: [UIView] = [capabilityBadges, ratingsView]
        for metadata in metadataViews {
            metadata.isHidden = true
            textColumn.addArrangedSubview(metadata)
            metadata.widthAnchor.constraint(equalTo: textColumn.widthAnchor).isActive = true
            metadata.setContentHuggingPriority(.required, for: .vertical)
        }
        let preferredWidth = textColumn.widthAnchor.constraint(equalToConstant: 860)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        preferredTextColumnWidth = preferredWidth

        // 6. Actions.
        textColumn.setCustomSpacing(0, after: dateRow)
        textColumn.setCustomSpacing(32, after: capabilityBadges)
        textColumn.setCustomSpacing(32, after: ratingsView)
        textColumn.addArrangedSubview(makeActionRow())
    }

    /// The below-fold: a darkened panel (over the fixed backdrop) with the title
    /// centered on top and the Information / Languages / Accessibility columns.
    /// Per episode_details_bottom_ref.JPG.
    private func buildBelowFold() {
        belowFold.translatesAutoresizingMaskIntoConstraints = false
        belowFold.backgroundColor = .clear
        contentView.addSubview(belowFold)

        // Light blurred backdrop for the whole below-fold (the top half stays
        // light over the fixed backdrop).
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        blur.translatesAutoresizingMaskIntoConstraints = false
        belowFold.addSubview(blur)

        // The top half is just the blurred backdrop; the BOTTOM HALF gets a dark
        // background that the columns sit on.
        let topHalf = UILayoutGuide()
        belowFold.addLayoutGuide(topHalf)
        let darkBG = UIView()
        darkBG.translatesAutoresizingMaskIntoConstraints = false
        darkBG.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        belowFold.addSubview(darkBG)

        belowFoldTitle.translatesAutoresizingMaskIntoConstraints = false
        belowFoldTitle.text = item.title
        belowFoldTitle.font = .systemFont(ofSize: 76, weight: .bold)
        belowFoldTitle.textColor = .white
        belowFoldTitle.textAlignment = .center
        belowFoldTitle.numberOfLines = 2
        belowFold.addSubview(belowFoldTitle)

        infoColumns.translatesAutoresizingMaskIntoConstraints = false
        belowFold.addSubview(infoColumns)

        let inset = PreviewCarouselGeometry.expandedChromeInset
        NSLayoutConstraint.activate([
            belowFold.heightAnchor.constraint(greaterThanOrEqualTo: view.heightAnchor),

            blur.topAnchor.constraint(equalTo: belowFold.topAnchor),
            blur.leadingAnchor.constraint(equalTo: belowFold.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: belowFold.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: belowFold.bottomAnchor),

            // topHalf = one half of a viewport from the top of the below-fold.
            topHalf.topAnchor.constraint(equalTo: belowFold.topAnchor),
            topHalf.leadingAnchor.constraint(equalTo: belowFold.leadingAnchor),
            topHalf.trailingAnchor.constraint(equalTo: belowFold.trailingAnchor),
            topHalf.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),

            // Dark background over the bottom half.
            darkBG.topAnchor.constraint(equalTo: topHalf.bottomAnchor),
            darkBG.leadingAnchor.constraint(equalTo: belowFold.leadingAnchor),
            darkBG.trailingAnchor.constraint(equalTo: belowFold.trailingAnchor),
            darkBG.bottomAnchor.constraint(equalTo: belowFold.bottomAnchor),

            // Title in the top (light) half.
            // Cap top 64 from the screen top, measured on device (tvOS 27).
            belowFoldTitle.topAnchor.constraint(equalTo: belowFold.topAnchor,
                                                constant: 64 - (belowFoldTitle.font.ascender - belowFoldTitle.font.capHeight)),
            belowFoldTitle.centerXAnchor.constraint(equalTo: belowFold.centerXAnchor),
            belowFoldTitle.leadingAnchor.constraint(greaterThanOrEqualTo: belowFold.leadingAnchor, constant: inset),

            // Columns in the bottom (dark) half.
            infoColumns.topAnchor.constraint(equalTo: topHalf.bottomAnchor, constant: 56),
            infoColumns.leadingAnchor.constraint(equalTo: belowFold.leadingAnchor, constant: inset),
            infoColumns.trailingAnchor.constraint(equalTo: belowFold.trailingAnchor, constant: -inset),
            infoColumns.bottomAnchor.constraint(lessThanOrEqualTo: belowFold.bottomAnchor, constant: -80),
        ])
    }

    private func makeActionRow() -> UIView {
        // Metadata-only items (TMDB/Discover, unmatched) have no playback
        // route — the primary action is the Watchlist toggle, and the
        // watched/watchlist circles are dropped (no provider state).
        if item.isMetadataOnly || item.isAvailable == false { return makeMetadataOnlyActionRow() }
        let (pill, title, _) = FocusableActionButton.pill(title: playPillTitle, systemImage: "play.fill")
        pill.onPrimaryAction = { [weak self] in guard let self else { return }; self.onPlay(self.item, nil) }
        playButton = pill
        playTitleLabel = title

        // Match the carousel chrome: Watched = checkmark, Watchlist = plus.
        let watched = FocusableActionButton.circle(systemImage: isWatched ? "checkmark.circle.fill" : "checkmark")
        watchedButton = watched
        watched.onPrimaryAction = { [weak self] in self?.toggleWatched() }

        let watchlist = FocusableActionButton.circle(systemImage: "plus")
        watchlistButton = watchlist
        watchlist.onPrimaryAction = { [weak self] in self?.toggleWatchlist() }
        let ref = item.ref
        Task { [weak self] in
            guard let p = MediaProviderRegistry.shared.provider(for: ref.providerID) else { return }
            let on = await p.isOnWatchlist(ref)
            await MainActor.run { self?.onWatchlist = on; self?.updateWatchlistIcon() }
        }

        let row = UIStackView(arrangedSubviews: [pill, watched, watchlist])
        actionRow = row
        // An episode's Watched acts on the episode alone; the whole show is
        // marked from the show's own page, which this opens.
        if item.kind == .episode, let showRef, !showRef.itemID.isEmpty {
            let goToShow = FocusableActionButton.circle(systemImage: "tv")
            goToShow.onPrimaryAction = { [weak self] in
                guard let self else { return }
                PreviewCarouselViewController.openShowDetail(showRef, show: self.show, from: self)
            }
            row.addArrangedSubview(goToShow)
        }
        row.axis = .horizontal
        row.spacing = HeroPillButton.rowGap
        row.alignment = .center
        return row
    }

    private func makeMetadataOnlyActionRow() -> UIView {
        let (pill, title, icon) = FocusableActionButton.pill(title: "Watchlist", systemImage: nil)

        if ProviderWatchlistPill.bind(pill, icon: icon, title: title, item: item,
                                     presenter: { [weak self] in self }) {
            // The saved title belongs to its native server, not Plex Discover.
        } else if let tmdbID = item.tmdbID {
            let guid = "tmdb://\(tmdbID)"
            func render() {
                let isOn = PlexWatchlistService.shared.contains(guid: guid)
                    || PlexWatchlistService.shared.contains(tmdbId: tmdbID)
                icon.image = UIImage(systemName: isOn ? "bookmark.fill" : "bookmark")
            }
            render()
            let item = self.item
            pill.onPrimaryAction = {
                Task { @MainActor in
                    let service = PlexWatchlistService.shared
                    if service.contains(guid: guid) || service.contains(tmdbId: tmdbID) {
                        await service.remove(guid: guid)
                    } else {
                        let entry = PlexWatchlistItem(
                            id: guid,
                            title: item.title,
                            year: item.year,
                            type: item.kind == .movie ? .movie : .show,
                            posterURL: item.artwork.poster,
                            guids: [guid]
                        )
                        await service.add(guid: guid, item: entry)
                    }
                    render()
                }
            }
        } else {
            icon.image = UIImage(systemName: "bookmark")
        }
        playButton = pill

        let row = UIStackView(arrangedSubviews: [pill])
        if let silo = provider as? SiloProvider, item.kind == .movie || item.kind == .show {
            let request = FocusableActionButton.circle(systemImage: "plus.app")
            request.accessibilityLabel = "Request"
            request.isHidden = true
            request.onPrimaryAction = { [weak self] in
                guard let self, self.view.window != nil,
                      SiloSession.account?.providerID == silo.id,
                      SiloSession.authorityRevision == silo.authorityRevision else { return }
                self.present(SiloRequestsViewController(provider: silo, context: .search(self.item.title)), animated: true)
            }
            row.addArrangedSubview(request)
            Task { [weak self, weak request] in
                let status = try? await SiloRequests(provider: silo).status()
                let allowed = status?.isAvailable == true
                guard let self, let request, self.view.window != nil,
                      SiloSession.account?.providerID == silo.id,
                      SiloSession.authorityRevision == silo.authorityRevision else { return }
                request.isHidden = !allowed
            }
        }
        row.axis = .horizontal
        row.spacing = HeroPillButton.rowGap
        row.alignment = .center
        return row
    }

    // MARK: - Data

    private func setShowTitle(_ title: String) {
        showTitleLabel.text = title
        showTitleLabel.isHidden = title.isEmpty
    }

    /// Synopsis with a BOLD "S2, E1:" prefix, regular body.
    private func synopsisAttributed() -> NSAttributedString? {
        guard let overview = item.overview, !overview.isEmpty else { return nil }
        let body = NSMutableAttributedString()
        let color = UIColor.white.withAlphaComponent(0.9)
        if let s = item.seasonNumber, let e = item.episodeNumber {
            body.append(NSAttributedString(string: "S\(s), E\(e): ", attributes: [
                .font: UIFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: color]))
        }
        body.append(NSAttributedString(string: overview, attributes: [
            .font: UIFont.systemFont(ofSize: 23, weight: .medium), .foregroundColor: color]))
        return body
    }

    private func dateRuntimeText() -> String? {
        var parts: [String] = []
        if let date = Self.displayDate(item.releaseDate) { parts.append(date) }
        else if let year = item.year { parts.append(String(year)) }
        if let runtime = item.runtime, runtime > 0 { parts.append(Self.formatRuntime(runtime)) }
        if let edition = item.editionTitle, !edition.isEmpty { parts.append(edition) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func loadDetail() {
        Task { [weak self] in
            guard let self, let provider = self.provider else { return }
            // For an episode or a season, the show supplies the series title AND
            // the genres (their own detail usually has no genres).
            var showGenres: [String] = []
            if let showRef = self.showRef,
               let showDetail = try? await provider.fullDetail(for: showRef) {
                showGenres = showDetail.genres
                await MainActor.run {
                    self.show = showDetail.item
                    if (self.showTitleLabel.text ?? "").isEmpty { self.setShowTitle(showDetail.item.title) }
                }
            }
            guard let detail = try? await provider.fullDetail(for: self.item.ref) else {
                if !showGenres.isEmpty { await MainActor.run { self.setGenres(showGenres) } }
                return
            }
            await MainActor.run {
                self.applyDetail(detail, fallbackGenres: showGenres)
                self.configureDescriptionTranslation()
            }
        }
    }

    private func setGenres(_ genres: [String]) {
        guard !genres.isEmpty else { return }
        genreLabel.text = genres.prefix(3).joined(separator: " · ")
        genreRatingRow.isHidden = false
    }

    private func applyDetail(_ detail: MediaItemDetail, fallbackGenres: [String]) {
        latestDetail = detail
        // The seed can be stale on open; `detail` is a fresh read, so reuse it.
        applyWatchState(from: detail.item)
        synopsisLabel.attributedText = synopsisAttributed()
        synopsisLabel.isHidden = (synopsisLabel.attributedText?.length ?? 0) == 0
        refreshDescriptionIndicator()
        setGenres(detail.genres.isEmpty ? fallbackGenres : detail.genres)
        infoColumns.configure(detail: detail)
        preferredTextColumnWidth?.constant = detail.ratingPresentation == .allAvailable ? 1060 : 860
        capabilityBadges.configure(source: detail.primarySource,
                                   style: detail.showsTechnicalMetadata ? .technical : .standard,
                                   includesAccessibility: true)
        ratingsView.configure(detail.chromeRatings)
        textColumn.setCustomSpacing(capabilityBadges.isHidden && ratingsView.isHidden ? 32 : 18, after: metadataSpacer)
        if detail.showsTechnicalMetadata, infoButton == nil, let actionRow {
            let button = FocusableActionButton.circle(systemImage: "info")
            button.onPrimaryAction = { [weak self] in
                guard let self, let latest = self.latestDetail else { return }
                self.present(InfoPopupViewController(content: InfoPopupContent.fullInfo(detail: latest),
                                                      height: 940), animated: true)
            }
            actionRow.addArrangedSubview(button)
            infoButton = button
        }
        addVersionsButton(detail)
    }

    private func configureDescriptionTranslation() {
        guard let detail = latestDetail, let provider = provider as? SiloProvider else { return }
        descriptionTranslation.configure(provider: provider, detail: detail,
                                         allowAutomatic: allowsAutomaticDescriptionTranslation)
    }

    private func applyDescriptionTranslation() {
        if let updated = descriptionTranslation.detail, updated.item.ref == item.ref {
            let changed = item.overview != updated.item.overview
                || item.overviewIsMachineTranslated != updated.item.overviewIsMachineTranslated
            if changed { applyDetail(updated, fallbackGenres: []) }
            else { latestDetail = updated }
        }
        refreshDescriptionIndicator()
    }

    private func refreshDescriptionIndicator() {
        let matches = descriptionTranslation.detail?.item.ref == item.ref
        let hasDescription = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let isTranslating = matches && descriptionTranslation.isTranslating
        synopsisLabel.alpha = isTranslating ? 0.65 : 1
        descriptionIndicator.configure(
            isTranslating: isTranslating,
            isMachineTranslated: hasDescription && item.overviewIsMachineTranslated == true,
            canTranslate: matches && descriptionTranslation.canTranslate,
            errorMessage: matches ? descriptionTranslation.errorMessage : nil,
            onTranslate: { [weak self] in self?.descriptionTranslation.translate() }, compact: true)
    }

    /// Versions button after Watchlist, once the detail shows two or more files.
    private func addVersionsButton(_ detail: MediaItemDetail) {
        let versions = VersionPicker.versions(in: detail)
        guard !versions.isEmpty, versionsButton == nil, let row = actionRow, let watchlist = watchlistButton,
              let index = row.arrangedSubviews.firstIndex(of: watchlist) else { return }
        let button = FocusableActionButton.circle(systemImage: "square.stack")
        button.onPrimaryAction = { [weak self, weak button] in
            guard let self, let button else { return }
            VersionPicker.present(versions, from: self, sourceFrame: button.convert(button.bounds, to: nil)) {
                [weak self] id in
                guard let self else { return }
                self.onPlay(self.item, id)
            }
        }
        row.insertArrangedSubview(button, at: index + 1)
        versionsButton = button
    }

    // MARK: - Watch-state refresh (issue #228)

    /// Repaints the Watched glyph and Play label on `.plexDataNeedsRefresh`, posted once
    /// the player's last report has committed (dismiss is about 2 s too early).
    private func refreshWatchState() {
        guard isViewLoaded, !item.isMetadataOnly, item.isAvailable != false, let provider else { return }
        watchRefreshToken &+= 1
        let token = watchRefreshToken
        let ref = item.ref
        Task { [weak self] in
            guard let detail = try? await provider.fullDetail(for: ref) else { return }
            await MainActor.run {
                guard let self, self.watchRefreshToken == token, detail.item.ref == ref else { return }
                self.applyWatchState(from: detail.item)
            }
        }
    }

    /// Repaint the two bits that show watch state from a fresh copy of the same
    /// item. Only these two: the item is otherwise a snapshot the rest of the
    /// page is already laid out from.
    private func applyWatchState(from refreshed: MediaItem) {
        guard refreshed.ref == item.ref else { return }
        item = refreshed
        isWatched = refreshed.isWatched
        resumeOffset = refreshed.userState.viewOffset
        watchedButton?.setIcon(isWatched ? "checkmark.circle.fill" : "checkmark")
        playTitleLabel?.text = playPillTitle
    }

    private var watchRefreshToken: UInt64 = 0
    private var refreshObservers = Set<AnyCancellable>()

    /// Local resume point, like `isWatched`, so the pill repaints without a round trip.
    /// `EpisodePicker.playTitle` ranks it above the watched flag.
    private var resumeOffset: TimeInterval = 0

    private var playPillTitle: String {
        EpisodePicker.playTitle(
            resumes: WatchProgressPolicy.hasResumePoint(offsetSeconds: resumeOffset, runtimeSeconds: item.runtime),
            watched: isWatched)
    }

    private func toggleWatched() {
        isWatched.toggle()
        watchedButton?.setIcon(isWatched ? "checkmark.circle.fill" : "checkmark")
        // Plex drops the resume point on scrobble and unscrobble (#270).
        resumeOffset = 0
        playTitleLabel?.text = playPillTitle
        let target = isWatched
        Task { [weak self] in
            guard let self, let provider = self.provider else { return }
            if target { try? await provider.markPlayed(self.item.ref) }
            else { try? await provider.markUnplayed(self.item.ref) }
            // Every surface re-reads, this page too, so a failed mark falls back to the server.
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
        }
    }

    private func toggleWatchlist() {
        onWatchlist.toggle()
        updateWatchlistIcon()
        let target = onWatchlist
        Task { [weak self] in
            guard let self, let provider = self.provider else { return }
            do {
                if target { try await provider.addToWatchlist(self.item.ref) }
                else { try await provider.removeFromWatchlist(self.item.ref) }
            } catch {
                // Revert: the flip above promised a state the server refused,
                // and leaving it would just come back wrong on reopen.
                self.onWatchlist = !target
                self.updateWatchlistIcon()
            }
        }
    }

    // Distinct active glyphs: watched = filled check, watchlist = saved bookmark.
    private func updateWatchlistIcon() {
        watchlistButton?.setIcon(onWatchlist ? "bookmark.fill" : "plus")
    }

    /// The show above an episode (grandparent) or a season (parent).
    private var showRef: MediaItemRef? {
        item.kind == .season ? item.parentRef : item.grandparentRef
    }

    private func loadBackdrop() {
        // The EPISODE's own still (same art the episode list uses), NOT the show
        // hero. Fall back to the item's backdrop/poster, never the grandparent.
        // A season's thumbnail IS its poster, so it leads with the wide art.
        let url = item.kind == .season
            ? item.artwork.backdrop ?? item.parentArtwork?.backdrop ?? item.artwork.thumbnail
            : item.artwork.thumbnail ?? item.artwork.backdrop ?? item.artwork.poster
        guard let url else { return }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .full)
            await MainActor.run { self?.backdrop.image = image }
        }
    }

    // MARK: - Helpers

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat) -> UILabel {
        let l = UILabel()
        style(l, size: size, weight: weight, alpha: alpha)
        l.text = text
        return l
    }

    private func style(_ l: UILabel, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat) {
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = UIColor.white.withAlphaComponent(alpha)
        l.numberOfLines = 2
    }

    /// Small bordered capsule badge (rating, DV, Atmos, SDH, …).
    private static func badge(_ text: String = "") -> UILabel {
        let l = PaddedLabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = text
        l.font = .systemFont(ofSize: 15, weight: .bold)
        l.textAlignment = .center
        l.textColor = UIColor.white.withAlphaComponent(0.75)
        l.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        l.layer.borderWidth = 1
        l.layer.cornerRadius = 4
        l.layer.cornerCurve = .continuous
        // Apple caps a badge at 22pt total height.
        l.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return l
    }

    private static func formatRuntime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m) min"
    }

    private static let dateParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f
    }()
    private static let dateDisplay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()
    private static func displayDate(_ iso: String?) -> String? {
        guard let iso, let date = dateParser.date(from: String(iso.prefix(10))) else { return nil }
        return dateDisplay.string(from: date)
    }
}

/// A UILabel with internal padding (for the bordered badges).
private final class PaddedLabel: UILabel {
    private let inset = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}

// MARK: - Blur-fade transition

/// Blurs what is behind while the page fades in, and the reverse on dismiss. Also used
/// by the carousel's standalone detail.
final class BlurFadeTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        BlurFadeAnimator(presenting: true)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        BlurFadeAnimator(presenting: false)
    }
}

final class BlurFadeAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool
    init(presenting: Bool) { self.presenting = presenting }

    func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval { presenting ? 0.45 : 0.4 }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        let duration = transitionDuration(using: ctx)

        if presenting {
            guard let toView = ctx.view(forKey: .to) else { ctx.completeTransition(true); return }
            // Blur sits over the still-visible carousel (.overFullScreen).
            let blur = UIVisualEffectView(effect: nil)
            blur.frame = container.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(blur)
            toView.frame = container.bounds
            toView.alpha = 0
            container.addSubview(toView)

            let anim = UIViewPropertyAnimator(duration: duration, curve: .easeInOut) {
                blur.effect = UIBlurEffect(style: .dark)
                toView.alpha = 1
            }
            anim.addCompletion { _ in
                blur.removeFromSuperview()    // page is opaque now
                ctx.completeTransition(!ctx.transitionWasCancelled)
            }
            anim.startAnimation()
        } else {
            guard let fromView = ctx.view(forKey: .from) else { ctx.completeTransition(true); return }
            // Blur (dark → clear) under the fading page reveals a sharpening carousel.
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
            blur.frame = container.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.insertSubview(blur, belowSubview: fromView)

            let anim = UIViewPropertyAnimator(duration: duration, curve: .easeInOut) {
                fromView.alpha = 0
                blur.effect = nil
            }
            anim.addCompletion { _ in
                blur.removeFromSuperview()
                ctx.completeTransition(!ctx.transitionWasCancelled)
            }
            anim.startAnimation()
        }
    }
}
