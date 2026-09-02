// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItemDetailPageViewController.swift
//  Rivulet
//
//  A reusable, title-first detail page for any MediaItem (episode, movie, show).
//  Layout follows Docs/atv_ref/episode_details_ref.JPG (hero) and
//  episode_details_bottom_ref.JPG (Information / Languages / Accessibility
//  columns). Reached by a blur-fade from the carousel detail's episode
//  description; Menu/Back returns.
//
//  Stage 3a: the hero. Hero order matches the reference:
//    show title (small) · episode title (large) · genre · rating ·
//    "S2, E1: synopsis" · date · runtime + capability badges ·
//    Play + Watched + Watchlist.
//  Below-fold info columns (3b) and the custom blur-fade (3c) land next.
//

import Combine
import UIKit

/// A diagonal dark scrim (bottom-left → top-right) so the title stack stays
/// readable over any backdrop. Static gradient as a UIView layer (no morph).
private final class ScrimGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        guard let g = layer as? CAGradientLayer else { return }
        g.colors = [
            UIColor.black.withAlphaComponent(0.92).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.clear.cgColor,
        ]
        g.locations = [0.0, 0.45, 1.0]
        g.startPoint = CGPoint(x: 0.0, y: 1.0)   // bottom-left
        g.endPoint = CGPoint(x: 1.0, y: 0.0)     // top-right
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class MediaItemDetailPageViewController: UIViewController {

    /// Mutable so a post-playback refresh can swap in the re-fetched copy
    /// (issue #228). The ref never changes — only the user state does.
    private var item: MediaItem
    private let onPlay: (MediaItem) -> Void

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
    private let dateRow = UIStackView()
    private let dateLabel = UILabel()
    private let badgeRow = UIStackView()
    private var playButton: FocusableActionButton?
    /// The Play pill's own label, held so a post-playback refresh can flip
    /// Play ↔ Resume without rebuilding (and re-focusing) the action row.
    private weak var playTitleLabel: UILabel?
    private weak var watchedButton: FocusableActionButton?
    private weak var watchlistButton: FocusableActionButton?
    private var onWatchlist = false

    private var isWatched: Bool
    private let blurFade = BlurFadeTransitioningDelegate()
    private var provider: MediaProvider? { MediaProviderRegistry.shared.provider(for: item.ref.providerID) }

    init(item: MediaItem, seriesTitle: String?, onPlay: @escaping (MediaItem) -> Void) {
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
            textColumn.bottomAnchor.constraint(equalTo: heroContent.safeAreaLayoutGuide.bottomAnchor, constant: -98),
            textColumn.widthAnchor.constraint(lessThanOrEqualToConstant: 820),

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
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    // MARK: - Build

    private func buildTextColumn(into parent: UIView) {
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.axis = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 10
        parent.addSubview(textColumn)

        // 1. Show title (small) — filled by setShowTitle (init or fetch).
        style(showTitleLabel, size: 34, weight: .bold, alpha: 0.9)
        showTitleLabel.isHidden = (showTitleLabel.text ?? "").isEmpty
        textColumn.addArrangedSubview(showTitleLabel)

        // 2. Episode/item title (large).
        let titleLabel = label(item.title, size: 50, weight: .bold, alpha: 1)
        textColumn.addArrangedSubview(titleLabel)

        // 3. Genre · rating.
        genreRatingRow.axis = .horizontal
        genreRatingRow.alignment = .center
        genreRatingRow.spacing = 14
        style(genreLabel, size: 24, weight: .semibold, alpha: 0.85)
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
        style(synopsisLabel, size: 24, weight: .regular, alpha: 0.9)
        synopsisLabel.numberOfLines = 3
        synopsisLabel.attributedText = synopsisAttributed()
        synopsisLabel.isHidden = (synopsisLabel.attributedText?.length ?? 0) == 0
        synopsisLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 820).isActive = true
        textColumn.addArrangedSubview(synopsisLabel)

        // 5. Date · runtime + capability badges.
        dateRow.axis = .horizontal
        dateRow.alignment = .center
        dateRow.spacing = 12
        style(dateLabel, size: 22, weight: .semibold, alpha: 0.8)
        dateLabel.text = dateRuntimeText()
        dateRow.addArrangedSubview(dateLabel)
        badgeRow.axis = .horizontal
        badgeRow.alignment = .center
        badgeRow.spacing = 8
        dateRow.addArrangedSubview(badgeRow)
        textColumn.addArrangedSubview(dateRow)

        // 6. Actions.
        textColumn.setCustomSpacing(28, after: dateRow)
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
        belowFoldTitle.font = .systemFont(ofSize: 52, weight: .bold)
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
            belowFoldTitle.topAnchor.constraint(equalTo: belowFold.safeAreaLayoutGuide.topAnchor, constant: 64),
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
        if item.isMetadataOnly { return makeMetadataOnlyActionRow() }
        let pill = FocusableActionButton()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerRadius = 32
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let icon = UIImageView(image: UIImage(systemName: "play.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .white
        title.text = playPillTitle
        pill.addSubview(icon)
        pill.addSubview(title)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 64),
            icon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 24),
            icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -28),
            title.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        pill.invertOnFocus = [icon, title]
        pill.onPrimaryAction = { [weak self] in guard let self else { return }; self.onPlay(self.item) }
        playButton = pill
        playTitleLabel = title

        // Match the carousel chrome: Watched = checkmark, Watchlist = plus.
        let watched = circleButton(systemImage: isWatched ? "checkmark.circle.fill" : "checkmark")
        watchedButton = watched
        watched.onPrimaryAction = { [weak self] in self?.toggleWatched() }

        let watchlist = circleButton(systemImage: "plus")
        watchlistButton = watchlist
        watchlist.onPrimaryAction = { [weak self] in self?.toggleWatchlist() }
        let ref = item.ref
        Task { [weak self] in
            guard let p = MediaProviderRegistry.shared.provider(for: ref.providerID) else { return }
            let on = await p.isOnWatchlist(ref)
            await MainActor.run { self?.onWatchlist = on; self?.updateWatchlistIcon() }
        }

        let row = UIStackView(arrangedSubviews: [pill, watched, watchlist])
        row.axis = .horizontal
        row.spacing = 18
        row.alignment = .center
        return row
    }

    private func makeMetadataOnlyActionRow() -> UIView {
        let pill = FocusableActionButton()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerRadius = 32
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .white
        title.text = "Watchlist"
        pill.addSubview(icon)
        pill.addSubview(title)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 64),
            icon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 24),
            icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -28),
            title.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        pill.invertOnFocus = [icon, title]

        if let tmdbID = item.tmdbID {
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
        row.axis = .horizontal
        row.spacing = 18
        row.alignment = .center
        return row
    }

    private func circleButton(systemImage: String) -> FocusableActionButton {
        let b = FocusableActionButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.layer.cornerRadius = 32
        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        b.addSubview(icon)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 64),
            b.heightAnchor.constraint(equalToConstant: 64),
            icon.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
        ])
        b.invertOnFocus = [icon]
        return b
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
                .font: UIFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: color]))
        }
        body.append(NSAttributedString(string: overview, attributes: [
            .font: UIFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: color]))
        return body
    }

    private func dateRuntimeText() -> String? {
        var parts: [String] = []
        if let date = Self.displayDate(item.releaseDate) { parts.append(date) }
        else if let year = item.year { parts.append(String(year)) }
        if let runtime = item.runtime, runtime > 0 { parts.append(Self.formatRuntime(runtime)) }
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
                    if (self.showTitleLabel.text ?? "").isEmpty { self.setShowTitle(showDetail.item.title) }
                }
            }
            guard let detail = try? await provider.fullDetail(for: self.item.ref) else {
                if !showGenres.isEmpty { await MainActor.run { self.setGenres(showGenres) } }
                return
            }
            await MainActor.run { self.applyDetail(detail, fallbackGenres: showGenres) }
        }
    }

    private func setGenres(_ genres: [String]) {
        guard !genres.isEmpty else { return }
        genreLabel.text = genres.prefix(3).joined(separator: " · ")
        genreRatingRow.isHidden = false
    }

    private func applyDetail(_ detail: MediaItemDetail, fallbackGenres: [String]) {
        // This page is seeded from a snapshot that can already be stale on open
        // (marked watched from a tile menu, then opened before the hub refresh
        // lands). `detail` is a fresh server read, so spend it on the watch bits
        // too rather than issuing a second GET for them.
        applyWatchState(from: detail.item)
        setGenres(detail.genres.isEmpty ? fallbackGenres : detail.genres)
        infoColumns.configure(detail: detail)
        // Capability badges: file quality (4K/DV/Atmos/…) + SDH/AD. Strip any
        // parenthetical channel-layout noise ("5.1(side)" → "5.1").
        let source = detail.mediaSources.first
        var badges = source?.qualityBadges() ?? []
        if source?.subtitleTracks.contains(where: { $0.isHearingImpaired }) ?? false { badges.append("SDH") }
        if source?.audioTracks.contains(where: {
            ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri")
        }) ?? false { badges.append("AD") }
        badgeRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for raw in badges {
            let text = raw.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { badgeRow.addArrangedSubview(Self.badge(text)) }
        }
    }

    // MARK: - Watch-state refresh (issue #228)

    /// Re-read this item's watch state after playback and repaint the two bits
    /// that show it: the Watched glyph and the Play / Resume label. Driven by
    /// `.plexDataNeedsRefresh`, which the player posts only once its final
    /// progress report has had time to commit server-side — an `onDismiss`
    /// hook would fire ~2s early and read the stale value.
    private func refreshWatchState() {
        guard isViewLoaded, !item.isMetadataOnly, let provider else { return }
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
        setCircleIcon(watchedButton, isWatched ? "checkmark.circle.fill" : "checkmark")
        playTitleLabel?.text = playPillTitle
    }

    private var watchRefreshToken: UInt64 = 0
    private var refreshObservers = Set<AnyCancellable>()

    /// Local mirror of the resume point, so the pill can repaint the moment the
    /// user acts instead of waiting on the server round-trip (the same reason
    /// `isWatched` is mirrored). Seeded from the item, re-seeded by every
    /// refresh, zeroed by a Mark as Watched.
    ///
    /// Deliberately NOT `viewOffset > 0 && !isWatched`: a resume point outranks
    /// the watched flag everywhere else in the app (`PlexMetadata.isWatched`
    /// reports false while a rewatch is in progress, and both the poster and
    /// episode cells show the progress bar instead of the watched glyph), so
    /// keying off `isWatched` would label a resumable rewatch "Play".
    private var resumeOffset: TimeInterval = 0

    private var playPillTitle: String { resumeOffset > 0 ? "Resume" : "Play" }

    private func toggleWatched() {
        isWatched.toggle()
        setCircleIcon(watchedButton, isWatched ? "checkmark.circle.fill" : "checkmark")
        // Plex drops the resume point on both scrobble and unscrobble (the same
        // thing `PlexDataStore.updateItemWatchStatus` does locally), so the pill
        // stops offering a resume that no longer exists. Issue #270: it used to
        // keep saying "Resume" with nothing left to resume to.
        resumeOffset = 0
        playTitleLabel?.text = playPillTitle
        let target = isWatched
        Task { [weak self] in
            guard let self, let provider = self.provider else { return }
            if target { try? await provider.markPlayed(self.item.ref) }
            else { try? await provider.markUnplayed(self.item.ref) }
            // Same repaint the player uses on dismissal: every surface showing
            // this item's watch state re-reads it (this page included, so a
            // failed mark falls back to server truth), and Home drops or
            // restores the Continue Watching tile.
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
        setCircleIcon(watchlistButton, onWatchlist ? "bookmark.fill" : "plus")
    }
    private func setCircleIcon(_ button: FocusableActionButton?, _ name: String) {
        (button?.subviews.compactMap { $0 as? UIImageView }.first)?.image = UIImage(systemName: name)
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
        l.font = .systemFont(ofSize: 18, weight: .semibold)
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        l.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        l.layer.borderWidth = 1
        l.layer.cornerRadius = 6
        l.layer.cornerCurve = .continuous
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
    private let inset = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}

// MARK: - Blur-fade transition

/// Present: the carousel behind blurs in while the detail page fades in.
/// Dismiss: the reverse — page fades out as the carousel sharpens back.
/// Shared by the episode detail page AND the standalone (no-carousel) expanded
/// detail mode of PreviewCarouselViewController.
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
