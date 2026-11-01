// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The detail chrome: logo, genre row, description, quality row, and the action
//  and cast row. Shared by `PreviewCardView` and the home hero's `HeroButtonRowView`.
//  It lays out to whatever width its host gives it; the host owns the vignette and the cascade.

import UIKit
import os.log

private let chromeLog = Logger(
    subsystem: "com.rivulet.app",
    category: "MediaDetailChromeView"
)

final class MediaDetailChromeView: UIView {

    /// Sizes shared with the home hero's buttons. The pill width is a floor; long titles grow past it.
    private static let actionButtonHeight: CGFloat = HeroPillButton.buttonHeight
    private static let actionPillWidth: CGFloat = HeroPillButton.pillWidth
    private static let playProgressTrackWidth: CGFloat = 50
    private static let playProgressTrackHeight: CGFloat = 8
    /// Apple's description cap: wider on an episode.
    private static let descriptionMaxWidth: CGFloat = 677
    private static let episodeDescriptionMaxWidth: CGFloat = 860
    private static let captionFont = UIFont.systemFont(ofSize: 25, weight: .medium)
    private static let descriptionFont = UIFont.systemFont(ofSize: 23, weight: .medium)
    private static let rolesLabelAlpha: CGFloat = 0.6

    // MARK: - Public surface

    /// `.expandedDetail` makes the action row interactive.
    enum Mode {
        case carouselStable
        case expandedDetail
    }

    var mode: Mode = .carouselStable {
        didSet {
            guard mode != oldValue else { return }
            applyMode()
        }
    }

    /// Current item this chrome is showing. Setting kicks off the
    /// metadata rebuild + async detail fetch.
    var item: MediaItem? {
        didSet {
            guard item != oldValue else { return }
            guard !isRefreshingWatchState else { return }
            applyItem()
        }
    }

    /// Cascade alpha — forwarded directly to `self.alpha`. The host owns
    /// the timing; this view just exposes a typed knob.
    var chromeAlpha: CGFloat {
        get { alpha }
        set { alpha = newValue }
    }

    /// Action callbacks; never invoked in `.carouselStable`, where the action row is inert.
    var onPlay: (() -> Void)?
    var onPlayVersion: ((String) -> Void)?
    var onToggleWatchlist: (() -> Void)?
    var onShowFullDescription: ((MediaItemDetail) -> Void)?

    /// The Play pill (rebuilt per item). Exposed so the host cell can point the
    /// focus engine at Play when the detail expands.
    private(set) var playButton: FocusableActionButton?
    /// Preferred focus target for the action row (Play), or nil before detail loads.
    var playFocusable: UIView? { playButton }

    /// Play pill progress fill, held because on a show or season the episode it tracks
    /// arrives asynchronously. Rebuilt with the pill.
    private var playProgressFillWidth: NSLayoutConstraint?
    /// The Play pill's title and progress track. Held so `setPlayTarget` can
    /// rewrite them: the pill is built once and only its watch-derived bits change.
    private weak var playTitleLabel: UILabel?
    private weak var playProgressTrack: UIView?
    private var descriptionMaxWidth: NSLayoutConstraint?

    // MARK: - State

    /// Monotonic load token. Bumped on every `applyItem()`; async detail
    /// fetch checks against this on completion and discards stale results.
    /// Prevents wrong metadata from snapping in when item changes quickly.
    private var loadToken: UInt64 = 0

    /// Cached detail, populated by `loadDetail()` when it lands. Used to
    /// repopulate genre + quality rows + cast label with richer fields.
    private var detail: MediaItemDetail?

    /// Sizes the logo view to the image's aspect, since `.scaleAspectFit` centres the glyphs
    /// and would push them right of the metadata's leading edge.
    private var logoAspectConstraint: NSLayoutConstraint?

    // MARK: - Subviews

    /// Outer vertical stack — bottom-leading aligned by the host. Contains
    /// the metadata block + the action+cast row.
    private let chromeStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        // Not .fill: with the block's 860 cap that conflicts and can snap it to the
        // trailing edge. The action row gets its own full-width constraint.
        s.alignment = .leading
        s.spacing = 18
        return s
    }()

    /// Logo slot (126 pt), genre row, description and quality row, at most 860 pt wide
    /// and content height.
    private let metadataBlock: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.alignment = .leading
        s.spacing = 18
        return s
    }()

    /// Logo slot — fixed 126pt tall, bottom-leading aligned. The logo image
    /// (420pt max wide) or the fallback label (600pt max wide) occupies it
    /// depending on whether `artwork.logo` loaded.
    private let logoSlotView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let titleLogoImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let titleFallbackLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 48, weight: .bold)
        l.textColor = .white
        l.numberOfLines = 2
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// "Movie · Adventure · Sci-Fi  [TV-14]"
    private let genreRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 6
        s.alignment = .center
        return s
    }()

    /// The overview (Apple shows no tagline), up to 4 lines / 677pt wide (860 on
    /// an episode).
    private let descriptionLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = MediaDetailChromeView.descriptionFont
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        l.numberOfLines = 4
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// "2023 · 49 min   ⭐ 7.8   [4K] [DV] [5.1]", dimmer than the genre row.
    private let qualityRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 12
        s.alignment = .center
        return s
    }()

    /// Action buttons left, cast label right. A plain view, since a stack view flashes
    /// the buttons stretched wide on the first layout pass.
    private let actionAndCastRow: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    /// Left cluster — Play pill + Watched / Watchlist / Info circles.
    private let actionButtonsStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.alignment = .center
        s.spacing = HeroPillButton.rowGap
        return s
    }()

    /// "Starring …" in a 410pt box on the trailing margin, left-aligned, its
    /// bottom on the buttons' bottom. The names are brighter than the label.
    private let castLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = MediaDetailChromeView.captionFont
        l.textColor = .white
        l.numberOfLines = 3
        l.textAlignment = .natural
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MediaDetailChromeView is not Storyboard-backed")
    }

    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = false  // host flips this on for .expandedDetail

        logoSlotView.addSubview(titleLogoImageView)
        logoSlotView.addSubview(titleFallbackLabel)

        addSubview(chromeStack)

        metadataBlock.addArrangedSubview(logoSlotView)
        metadataBlock.addArrangedSubview(genreRow)
        metadataBlock.addArrangedSubview(descriptionLabel)
        metadataBlock.addArrangedSubview(qualityRow)
        chromeStack.addArrangedSubview(metadataBlock)

        // Apple's rhythm: 18 between the text rows, 32 above the buttons.
        chromeStack.setCustomSpacing(32, after: metadataBlock)
        chromeStack.addArrangedSubview(actionAndCastRow)

        // The two children compete only over the gap, so neither stretches past its content.
        actionAndCastRow.addSubview(actionButtonsStack)
        actionAndCastRow.addSubview(castLabel)

        // Hugging is .required so the stack never stretches beyond the sum
        // of its buttons.
        actionButtonsStack.setContentHuggingPriority(.required, for: .horizontal)
        actionButtonsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let descMaxWidth = descriptionLabel.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.descriptionMaxWidth)
        descriptionMaxWidth = descMaxWidth

        let castWidth = castLabel.widthAnchor.constraint(equalToConstant: 410)
        castWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Chrome stack fills self.
            chromeStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeStack.topAnchor.constraint(equalTo: topAnchor),
            chromeStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Logo slot: 126pt tall; the image caps at 420 wide, the text
            // title at 600.
            logoSlotView.heightAnchor.constraint(equalToConstant: 126),
            logoSlotView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            titleLogoImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            // Logo image: aspectFit, bottom-leading inside the slot.
            // No fixed height — a 500×120 logo renders at 500×120.
            titleLogoImageView.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleLogoImageView.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleLogoImageView.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),
            titleLogoImageView.topAnchor.constraint(greaterThanOrEqualTo: logoSlotView.topAnchor),
            // Fill the slot at 999, so an extra-wide logo shrinks to the 420 pt width cap.
            titleLogoImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 126),
            {
                let c = titleLogoImageView.heightAnchor.constraint(equalToConstant: 126)
                c.priority = .init(999)
                return c
            }(),

            // Fallback label: bottom-leading inside the slot.
            titleFallbackLabel.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleFallbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleFallbackLabel.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),

            descMaxWidth,

            // 860 pt cap; height follows content.
            metadataBlock.widthAnchor.constraint(lessThanOrEqualToConstant: Self.episodeDescriptionMaxWidth),

            // The action+cast row spans the full chrome width (the stack is
            // .leading now, so this must be explicit) — buttons leading, cast
            // trailing.
            actionAndCastRow.widthAnchor.constraint(equalTo: chromeStack.widthAnchor),

            // Action buttons pin to leading + centerY of the row.
            actionButtonsStack.leadingAnchor.constraint(equalTo: actionAndCastRow.leadingAnchor),
            actionButtonsStack.centerYAnchor.constraint(equalTo: actionAndCastRow.centerYAnchor),
            actionButtonsStack.topAnchor.constraint(greaterThanOrEqualTo: actionAndCastRow.topAnchor),
            actionButtonsStack.bottomAnchor.constraint(lessThanOrEqualTo: actionAndCastRow.bottomAnchor),

            // Row height derives from the action buttons stack
            // (54pt circle/pill height).
            actionAndCastRow.heightAnchor.constraint(greaterThanOrEqualTo: actionButtonsStack.heightAnchor),

            // Cast box: 410pt on the trailing margin, bottom on the buttons'
            // bottom. It may grow upward past the row; nothing sits there.
            castLabel.trailingAnchor.constraint(equalTo: actionAndCastRow.trailingAnchor),
            castLabel.bottomAnchor.constraint(equalTo: actionButtonsStack.bottomAnchor),
            castWidth,

            // Min 10pt gap between buttons and cast box: a very long button
            // row narrows the box, the buttons keep their widths.
            castLabel.leadingAnchor.constraint(greaterThanOrEqualTo: actionButtonsStack.trailingAnchor, constant: 10)
        ])

        applyMode()
    }

    // MARK: - Mode

    private func applyMode() {
        switch mode {
        case .carouselStable:
            actionAndCastRow.isUserInteractionEnabled = false
            isUserInteractionEnabled = false
        case .expandedDetail:
            actionAndCastRow.isUserInteractionEnabled = true
            isUserInteractionEnabled = true
        }
    }

    /// Toggles button focusability without changing mode, so Up from the below-fold
    /// cannot escape into the faded chrome.
    func setActionRowFocusable(_ on: Bool) {
        actionAndCastRow.isUserInteractionEnabled = on
    }

    // MARK: - Reset (host calls during cell reuse)

    /// Clears all displayed content and bumps the load token so any
    /// in-flight async work is discarded. Called by `PreviewCardView`'s
    /// `prepareForReuse`.
    func reset() {
        loadToken &+= 1
        item = nil
        detail = nil
        if let prev = logoAspectConstraint {
            prev.isActive = false
            logoAspectConstraint = nil
        }
        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        titleLogoImageView.isHidden = false
        titleFallbackLabel.isHidden = false
        descriptionLabel.text = nil
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionButtonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        playButton = nil
        castLabel.text = nil
    }

    /// See `logoAspectConstraint`.
    private func installLogoAspectConstraint(for image: UIImage) {
        guard image.size.height > 0 else { return }
        let aspect = image.size.width / image.size.height
        let c = titleLogoImageView.widthAnchor.constraint(
            equalTo: titleLogoImageView.heightAnchor,
            multiplier: aspect
        )
        c.priority = .required
        c.isActive = true
        logoAspectConstraint = c
    }

    // MARK: - Apply / load

    /// Repaints the watched glyph and Play pill from a re-fetched copy of the item (#228).
    /// Not `item = refreshed`: that rebuilds the action row, which often holds focus.
    func refreshWatchState(from refreshed: MediaItem) {
        guard let current = item, current.ref == refreshed.ref else { return }
        // Keep the stored item current so a later toggle/Play reads fresh state.
        isRefreshingWatchState = true
        item = refreshed
        isRefreshingWatchState = false

        heroWatched = refreshed.isWatched
        updateWatchedIcon()
        setPlayTarget(refreshed)
        // Shows/seasons: the pill moves to the next unwatched episode.
        resolvePlayTarget(for: refreshed, token: loadToken)
    }

    /// Set while `refreshWatchState` swaps the re-fetched item in, so the
    /// `item` `didSet` skips the full rebuild.
    private var isRefreshingWatchState = false

    /// Loads still out for the current item (logo, detail, Play target). At zero
    /// the chrome is final, and nothing swaps in after a fade-in.
    private var pendingLoads = 0
    private var readyWaiters: [() -> Void] = []

    var isContentReady: Bool { pendingLoads == 0 }

    /// Runs `body` once the current item's loads finish (at once if they have).
    /// A new item drops the waiters, whose owner holds its own deadline.
    func whenContentReady(_ body: @escaping () -> Void) {
        if isContentReady { body() } else { readyWaiters.append(body) }
    }

    private func finishLoad(_ token: UInt64) {
        guard token == loadToken, pendingLoads > 0 else { return }
        pendingLoads -= 1
        guard pendingLoads == 0 else { return }
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0() }
    }

    private func applyItem() {
        loadToken &+= 1
        let token = loadToken
        pendingLoads = 0
        readyWaiters = []

        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        descriptionLabel.text = nil
        descriptionLabel.attributedText = nil
        resolvedGenres = []
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let item = item else { return }

        descriptionMaxWidth?.constant = item.kind == .episode
            ? Self.episodeDescriptionMaxWidth : Self.descriptionMaxWidth
        rebuildGenreRow(item: item, detail: nil)
        rebuildQualityRow(item: item, detail: nil)
        rebuildActionButtons(item: item)
        resolvePlayTarget(for: item, token: token, countsTowardReady: true)

        // Clear any aspect constraint from the previous item — a stale
        // ratio would size the new image wrong while it's loading.
        if let prev = logoAspectConstraint {
            prev.isActive = false
            logoAspectConstraint = nil
        }

        // A cached logo renders on frame 0 with no fallback-text flash.
        let cachedLogo = item.artwork.logo.flatMap { ImageCacheManager.shared.cachedImage(for: $0) }
        if let cachedLogo {
            titleLogoImageView.image = cachedLogo
            titleLogoImageView.isHidden = false
            titleFallbackLabel.isHidden = true
            titleFallbackLabel.text = nil
            installLogoAspectConstraint(for: cachedLogo)
        } else {
            titleFallbackLabel.text = item.title
            titleFallbackLabel.isHidden = false
            titleLogoImageView.isHidden = true
            titleLogoImageView.image = nil
            if let logoURL = item.artwork.logo {
                pendingLoads += 1
                Task { [weak self] in
                    let image = await ImageCacheManager.shared.image(for: logoURL)
                    await MainActor.run {
                        guard let self else { return }
                        defer { self.finishLoad(token) }
                        guard self.loadToken == token else { return }
                        guard let image else { return }
                        self.titleLogoImageView.image = image
                        self.titleLogoImageView.isHidden = false
                        self.titleFallbackLabel.isHidden = true
                        self.installLogoAspectConstraint(for: image)
                    }
                }
            } else if let tmdbID = item.tmdbID {
                // TMDB-mapped items carry no logo in artwork — resolve one
                // from the TMDB images API via the shared cache.
                let type: TMDBMediaType = item.kind == .movie ? .movie : .tv
                pendingLoads += 1
                Task { [weak self] in
                    guard let logoURL = await TMDBLogoCache.shared.logoURL(tmdbId: tmdbID, type: type) else {
                        await MainActor.run { self?.finishLoad(token) }
                        return
                    }
                    let image = await ImageCacheManager.shared.image(for: logoURL)
                    await MainActor.run {
                        guard let self else { return }
                        defer { self.finishLoad(token) }
                        guard self.loadToken == token else { return }
                        guard let image else { return }
                        self.titleLogoImageView.image = image
                        self.titleLogoImageView.isHidden = false
                        self.titleFallbackLabel.isHidden = true
                        self.installLogoAspectConstraint(for: image)
                    }
                }
            }
        }

        // Detail fetch — populates richer genre / rating / quality / cast.
        loadDetail(for: item, token: token)
    }

    /// Async fetch of `MediaItemDetail` through the agnostic provider
    /// registry. Tries `MediaProvider` first (Plex), falls back to
    /// `MetadataSource` (TMDB) for catalog-only items.
    private func loadDetail(for item: MediaItem, token: UInt64) {
        pendingLoads += 1
        Task { [weak self] in
            guard let self else { return }
            guard let fetched = await Self.fetchDetail(item.ref) else {
                await MainActor.run { self.finishLoad(token) }
                return
            }
            // An episode's own detail has no genres — fall back to the parent
            // show's genres (same as the episode detail page).
            var genres = fetched.genres
            if genres.isEmpty, item.kind == .episode, let showRef = item.grandparentRef,
               let showDetail = await Self.fetchDetail(showRef) {
                genres = showDetail.genres
            }
            await MainActor.run {
                defer { self.finishLoad(token) }
                guard self.loadToken == token else { return }
                self.detail = fetched
                self.resolvedGenres = genres
                self.applyDetail(item: item, detail: fetched)
            }
        }
    }

    private var resolvedGenres: [String] = []

    /// Titles the pill ("Play S1, E3") through the same `EpisodePicker.resolvePlayTarget`
    /// Play uses, so it names the episode that plays.
    private func resolvePlayTarget(for item: MediaItem, token: UInt64, countsTowardReady: Bool = false) {
        guard item.kind == .show || item.kind == .season else { return }
        if countsTowardReady { pendingLoads += 1 }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if countsTowardReady { self.finishLoad(token) } }
            guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
                  let episode = await EpisodePicker.resolvePlayTarget(for: item, provider: provider),
                  self.loadToken == token
            else { return }
            self.setPlayTarget(episode)
        }
    }

    private static func fetchDetail(_ ref: MediaItemRef) async -> MediaItemDetail? {
        if let provider = await MainActor.run(body: {
            MediaProviderRegistry.shared.provider(for: ref.providerID)
        }) {
            return try? await provider.fullDetail(for: ref)
        }
        if let source = await MainActor.run(body: {
            MetadataSourceRegistry.shared.source(for: ref.providerID)
        }) {
            return try? await source.itemDetail(ref)
        }
        return nil
    }

    /// Re-render the chrome rows + description + cast with newly-loaded
    /// detail fields. Called only when the fetch lands and the load
    /// token still matches.
    private func applyDetail(item: MediaItem, detail: MediaItemDetail) {
        rebuildGenreRow(item: item, detail: detail)
        rebuildQualityRow(item: item, detail: detail)
        if let s = item.seasonNumber, let e = item.episodeNumber,
           let overview = detail.item.overview, !overview.isEmpty {
            // Episode: bold "S1, E1:" prefix before the synopsis.
            let color = UIColor.white.withAlphaComponent(0.85)
            let attr = NSMutableAttributedString(string: "S\(s), E\(e): ", attributes: [
                .font: UIFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: color])
            attr.append(NSAttributedString(string: overview, attributes: [
                .font: Self.descriptionFont, .foregroundColor: color]))
            descriptionLabel.attributedText = attr
        } else if let overview = detail.item.overview, !overview.isEmpty {
            descriptionLabel.text = overview
            descriptionLabel.font = Self.descriptionFont
        }
        let topCast = detail.cast.prefix(3).map { $0.name }
        if !topCast.isEmpty {
            let attr = NSMutableAttributedString(string: "Starring ", attributes: [
                .foregroundColor: UIColor.white.withAlphaComponent(Self.rolesLabelAlpha)])
            attr.append(NSAttributedString(string: topCast.joined(separator: ", ")))
            castLabel.attributedText = attr
        } else {
            castLabel.attributedText = nil
        }
        addVersionsButton(detail)
    }

    /// Versions button after Info, once the detail shows two or more files.
    private func addVersionsButton(_ detail: MediaItemDetail) {
        let versions = VersionPicker.versions(in: detail)
        guard !versions.isEmpty, versionsButton == nil, let info = infoButton,
              let index = actionButtonsStack.arrangedSubviews.firstIndex(of: info) else { return }
        let button = makeCircleButton(systemImage: "square.stack")
        button.onPrimaryAction = { [weak self, weak button] in
            guard let self, let button, let host = self.hostViewController else { return }
            VersionPicker.present(versions, from: host, sourceFrame: button.convert(button.bounds, to: nil)) {
                [weak self] id in self?.onPlayVersion?(id)
            }
        }
        actionButtonsStack.insertArrangedSubview(button, at: index + 1)
        versionsButton = button
    }

    // MARK: - Row builders

    private func rebuildActionButtons(item: MediaItem) {
        actionButtonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Metadata-only items have no provider, so Play and Watched would no-op.
        if item.isMetadataOnly {
            rebuildMetadataOnlyActions(item: item)
            return
        }

        let play = makePlayPill(item: item)
        play.onPrimaryAction = { [weak self] in self?.onPlay?() }
        // Movie/episode: the item's own state. Show/season: reads "Play" until
        // the Play target resolves async in `resolvePlayTarget`.
        setPlayTarget(item)

        let watched = makeCircleButton(systemImage: "checkmark")
        watchedButton = watched
        heroWatched = item.isWatched
        updateWatchedIcon()
        watched.onPrimaryAction = { [weak self] in self?.toggleWatched(item) }

        let watchlist = makeCircleButton(systemImage: "plus")     // add to watchlist
        watchlistButton = watchlist
        heroOnWatchlist = false
        updateWatchlistIcon()
        let ref = item.ref
        Task { [weak self] in
            guard let p = MediaProviderRegistry.shared.provider(for: ref.providerID) else { return }
            let on = await p.isOnWatchlist(ref)
            await MainActor.run { self?.heroOnWatchlist = on; self?.updateWatchlistIcon() }
        }
        watchlist.onPrimaryAction = { [weak self] in self?.toggleWatchlist(item) }

        let info = makeCircleButton(systemImage: "text.page")     // open details popup
        infoButton = info
        info.onPrimaryAction = { [weak self] in
            guard let self, let detail = self.detail else { return }
            self.onShowFullDescription?(detail)
        }

        actionButtonsStack.addArrangedSubview(play)
        actionButtonsStack.addArrangedSubview(watched)
        // Jellyfin has no watchlist: its add throws, so the button would flip
        // and snap back. Nil provider keeps today's behaviour.
        if MediaProviderRegistry.shared.provider(for: item.ref.providerID)?.supportsWatchlist ?? true {
            actionButtonsStack.addArrangedSubview(watchlist)
        }
        actionButtonsStack.addArrangedSubview(info)
        // An episode's Watched acts on the episode alone; the whole show is
        // marked from the show's own page, which this opens.
        if item.kind == .episode, let showRef = item.grandparentRef, !showRef.itemID.isEmpty {
            let goToShow = makeCircleButton(systemImage: "tv")
            goToShow.onPrimaryAction = { [weak self] in
                guard let self, let host = self.hostViewController else { return }
                PreviewCarouselViewController.openShowDetail(showRef, from: host)
            }
            actionButtonsStack.addArrangedSubview(goToShow)
        }
        playButton = play
    }

    private var hostViewController: UIViewController? {
        sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
    }

    /// Watchlist pill (Plex Discover, by tmdb guid) and Info. No Watched: external items have no watch state.
    private func rebuildMetadataOnlyActions(item: MediaItem) {
        let pill = makeWatchlistPill(item: item)

        let info = makeCircleButton(systemImage: "text.page")
        info.onPrimaryAction = { [weak self] in
            guard let self, let detail = self.detail else { return }
            self.onShowFullDescription?(detail)
        }

        actionButtonsStack.addArrangedSubview(pill)
        actionButtonsStack.addArrangedSubview(info)
        // The pill is the row's primary focus target (playFocusable feeds
        // the carousel's land-on-primary routing).
        playButton = pill
    }

    /// Watchlist pill — same hardcoded geometry as the Play pill
    /// (Self.actionPillWidth × Self.actionButtonHeight) with bookmark
    /// icon + state-reflecting label.
    private func makeWatchlistPill(item: MediaItem) -> FocusableActionButton {
        let pill = FocusableActionButton()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerRadius = Self.actionButtonHeight / 2
        pill.layer.cornerCurve = .continuous

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = HeroPillButton.titleFont
        label.textColor = .white

        let contentStack = UIStackView(arrangedSubviews: [icon, label])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = HeroPillButton.iconGap

        pill.addSubview(contentStack)
        NSLayoutConstraint.activate(Self.pillConstraints(pill, content: contentStack) + [
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24)
        ])
        pill.invertOnFocus = [icon, label]

        guard let tmdbID = item.tmdbID else {
            icon.image = UIImage(systemName: "bookmark")
            label.text = "Watchlist"
            return pill
        }
        let guid = "tmdb://\(tmdbID)"

        func render() {
            let isOn = PlexWatchlistService.shared.contains(guid: guid)
                || PlexWatchlistService.shared.contains(tmdbId: tmdbID)
            icon.image = UIImage(systemName: isOn ? "bookmark.fill" : "bookmark")
            label.text = "Watchlist"
        }
        render()

        pill.onPrimaryAction = { [weak pill] in
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
                _ = pill  // keep the pill alive through the await for render
                render()
            }
        }
        return pill
    }

    private weak var watchedButton: FocusableActionButton?
    private weak var watchlistButton: FocusableActionButton?
    private weak var infoButton: FocusableActionButton?
    private weak var versionsButton: FocusableActionButton?
    private var heroWatched = false
    private var heroOnWatchlist = false

    private func toggleWatched(_ item: MediaItem) {
        // The stored item, not the one captured at build: a refresh since then
        // carries the show's current episode counts.
        let current = self.item ?? item
        if current.kind == .show { confirmShowWatchChange(current); return }
        setWatched(!heroWatched, current)
    }

    /// A show's Watched changes every episode at once, so it asks first and
    /// says how many episodes are already watched.
    private func confirmShowWatchChange(_ show: MediaItem) {
        guard let host = hostViewController else { return }
        let prompt = ShowWatchPrompt(progress: show.childProgress)
        let alert = UIAlertController(title: show.title, message: prompt.message, preferredStyle: .alert)
        for choice in prompt.choices {
            alert.addAction(UIAlertAction(title: choice.title, style: .default) { [weak self] _ in
                self?.setWatched(choice.markWatched, show)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        host.present(alert, animated: true)
    }

    private func setWatched(_ target: Bool, _ item: MediaItem) {
        heroWatched = target
        updateWatchedIcon()
        Task {
            guard let p = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
            if target { try? await p.markPlayed(item.ref) } else { try? await p.markUnplayed(item.ref) }
            // Repaint every surface showing watch state, as the player does (#270).
            NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
        }
    }

    private func toggleWatchlist(_ item: MediaItem) {
        heroOnWatchlist.toggle()
        updateWatchlistIcon()
        let target = heroOnWatchlist
        Task { [weak self] in
            guard let p = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
            do {
                if target { try await p.addToWatchlist(item.ref) } else { try await p.removeFromWatchlist(item.ref) }
            } catch {
                // The optimistic flip above was a promise the server didn't keep
                // (unmatched item, no Discover match). Put the icon back rather
                // than leave it claiming a state that won't survive reopening.
                await MainActor.run {
                    guard let self else { return }
                    self.heroOnWatchlist = !target
                    self.updateWatchlistIcon()
                }
            }
        }
    }

    // Distinct active glyphs so watched ≠ watchlist when both are on.
    private func updateWatchedIcon() {
        Self.setCircleIcon(watchedButton, heroWatched ? "checkmark.circle.fill" : "checkmark")
    }
    private func updateWatchlistIcon() {
        Self.setCircleIcon(watchlistButton, heroOnWatchlist ? "bookmark.fill" : "plus")
    }
    static func setCircleIcon(_ button: FocusableActionButton?, _ name: String) {
        (button?.subviews.compactMap { $0 as? UIImageView }.first)?.image = UIImage(systemName: name)
    }

    private func rebuildGenreRow(item: MediaItem, detail: MediaItemDetail?) {
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // resolvedGenres includes the parent show's genres for episodes (an
        // episode's own detail has none).
        let parts = ([Self.kindLabel(item.kind)] + resolvedGenres.prefix(2)).filter { !$0.isEmpty }
        if !parts.isEmpty {
            genreRow.addArrangedSubview(Self.makeCaptionLabel(parts.joined(separator: " · "), alpha: 1))
        }

        if let contentRating = detail?.contentRating, !contentRating.isEmpty {
            genreRow.addArrangedSubview(Self.makeBadge(contentRating, alpha: 1))
        }
    }

    /// Apple dims the whole metadata row, text and badges alike.
    private static let qualityRowAlpha: CGFloat = 0.75

    private func rebuildQualityRow(item: MediaItem, detail: MediaItemDetail?) {
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var parts: [String] = []
        if item.kind == .episode,
           let raw = item.releaseDate,
           let formatted = Self.formattedAirDate(raw) {
            parts.append(formatted)
        } else if let year = item.year {
            parts.append(String(year))
        }
        if let runtime = item.runtime, runtime > 0 { parts.append(Self.formatRuntime(runtime)) }
        if let edition = detail?.item.editionTitle ?? item.editionTitle, !edition.isEmpty { parts.append(edition) }

        if !parts.isEmpty {
            qualityRow.addArrangedSubview(
                Self.makeCaptionLabel(parts.joined(separator: " · "), alpha: Self.qualityRowAlpha))
        }

        // One score, from the source chosen in Appearance, and the Common Sense age; episodes show neither.
        if item.kind != .episode {
            Self.scoreAndAgeViews(ratings: detail?.ratings ?? [], age: detail?.contentAdvisory?.ageRating,
                                  alpha: Self.qualityRowAlpha).forEach(qualityRow.addArrangedSubview)
        }

        for badge in Self.calmBadges(detail?.primarySource) {
            qualityRow.addArrangedSubview(Self.makeBadge(badge, alpha: Self.qualityRowAlpha))
        }
    }

    /// The score (glyph or source name, then value) and the Common Sense age with its green seal.
    static func scoreAndAgeViews(ratings: [MediaRating], age: String?, alpha: CGFloat) -> [UIView] {
        var views: [UIView] = []
        if let rating = MediaRating.detailRating(in: ratings) {
            let label = makeCaptionLabel(rating.badgeText, alpha: alpha)
            let ratingStack: UIStackView
            if rating.source == .rottenTomatoes || rating.source == .rottenTomatoesAudience {
                let glyph = UIImageView(image: emojiGlyph(
                    rating.source == .rottenTomatoes ? (rating.value >= 6 ? "🍅" : "🤢") : "🍿"))
                glyph.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    glyph.widthAnchor.constraint(equalToConstant: 20),
                    glyph.heightAnchor.constraint(equalToConstant: 20)
                ])
                ratingStack = UIStackView(arrangedSubviews: [glyph, label])
                ratingStack.spacing = 2
            } else {
                ratingStack = UIStackView(arrangedSubviews: [makeCaptionLabel(rating.name, alpha: alpha), label])
                ratingStack.spacing = 6
            }
            ratingStack.axis = .horizontal
            ratingStack.alignment = .center
            views.append(ratingStack)
        }
        if let age {
            let seal = UIImageView(image: UIImage(systemName: "checkmark.circle"))
            seal.tintColor = .systemGreen
            seal.contentMode = .scaleAspectFit
            seal.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                seal.widthAnchor.constraint(equalToConstant: 20),
                seal.heightAnchor.constraint(equalToConstant: 20)
            ])
            let ageStack = UIStackView(arrangedSubviews: [seal, makeCaptionLabel(age, alpha: alpha)])
            ageStack.axis = .horizontal
            ageStack.spacing = 2
            ageStack.alignment = .center
            views.append(ageStack)
        }
        return views
    }

    /// The row's quality badges, kept short: 4K only, every range badge (DV, HDR10+ ...), and audio only
    /// when it is object audio.
    static func calmBadges(_ source: MediaSource?) -> [String] {
        guard let source else { return [] }
        var badges = source.resolutionBadge == "4K" ? ["4K"] : []
        badges += source.rangeBadges
        if let audio = source.audioBadge {
            if audio.hasSuffix("Atmos") { badges.append("Atmos") } else if audio.hasPrefix("DTS-X") { badges.append("DTS:X") }
        }
        return badges
    }

    /// An emoji as the score's glyph (tomato when fresh at 60% and up, nauseated face when rotten,
    /// popcorn for the audience); the system's art, so no rating-site artwork ships in the app.
    private static func emojiGlyph(_ emoji: String) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
            let glyph = emoji as NSString
            let font = UIFont.systemFont(ofSize: 17)
            let size = glyph.size(withAttributes: [.font: font])
            glyph.draw(at: CGPoint(x: (20 - size.width) / 2, y: (20 - size.height) / 2), withAttributes: [.font: font])
        }
    }

    // MARK: - Factories

    private func makePlayPill(item: MediaItem) -> FocusableActionButton {
        let pill = FocusableActionButton()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerRadius = Self.actionButtonHeight / 2
        pill.layer.cornerCurve = .continuous

        let playIcon = UIImageView(image: UIImage(systemName: "play.fill"))
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.tintColor = .white
        playIcon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = HeroPillButton.titleFont
        titleLabel.textColor = .white
        // Text is set by `setPlayTarget`, called right after this returns (and
        // again on every refresh) — building it here too would just be a second
        // rule to keep in sync.
        playTitleLabel = titleLabel

        let progressTrack = UIView()
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        progressTrack.layer.cornerRadius = Self.playProgressTrackHeight / 2
        progressTrack.clipsToBounds = true
        playProgressTrack = progressTrack

        let progressFill = UIView()
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = .white
        progressTrack.addSubview(progressFill)
        let fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        playProgressFillWidth = fillWidth

        // Content is centered in the pill (not leading-anchored) so a pill
        // wider than its content doesn't leave it stranded on the left.
        let contentStack = UIStackView(arrangedSubviews: [playIcon, progressTrack, titleLabel])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = HeroPillButton.iconGap

        pill.addSubview(contentStack)

        NSLayoutConstraint.activate(Self.pillConstraints(pill, content: contentStack) + [
            playIcon.widthAnchor.constraint(equalToConstant: 24),
            playIcon.heightAnchor.constraint(equalToConstant: 24),

            progressTrack.heightAnchor.constraint(equalToConstant: Self.playProgressTrackHeight),
            progressTrack.widthAnchor.constraint(equalToConstant: Self.playProgressTrackWidth),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillWidth
        ])

        pill.invertOnFocus = [playIcon, titleLabel]
        pill.invertBackgroundOnFocus = [progressTrack]
        pill.invertFillOnFocus = [progressFill]
        return pill
    }

    /// Pill geometry shared with `HeroPillButton`: fixed height, the shared
    /// width as a floor, content centred inside Apple's side padding.
    private static func pillConstraints(_ pill: UIView, content: UIView) -> [NSLayoutConstraint] {
        let restingWidth = pill.widthAnchor.constraint(equalToConstant: actionPillWidth)
        restingWidth.priority = .defaultLow
        return [
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: actionPillWidth),
            restingWidth,
            pill.heightAnchor.constraint(equalToConstant: actionButtonHeight),
            content.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: pill.leadingAnchor, constant: HeroPillButton.sidePadding),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: pill.trailingAnchor, constant: -HeroPillButton.sidePadding)
        ]
    }

    /// Point the Play pill at what pressing it would actually play: `target` is
    /// the hero item for a movie/episode, and the resolved episode for a show.
    /// The bar shows only while the title says Resume, so the two never disagree.
    private func setPlayTarget(_ target: MediaItem) {
        let resumes = target.isInProgress
        playProgressTrack?.isHidden = !resumes
        playProgressFillWidth?.constant = resumes
            ? Self.playProgressTrackWidth * CGFloat(target.watchProgress ?? 0) : 0
        playTitleLabel?.text = EpisodePicker.playTitle(for: target, on: item?.kind ?? target.kind)
    }

    private func makeCircleButton(systemImage: String) -> FocusableActionButton {
        let circle = FocusableActionButton()
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.layer.cornerRadius = Self.actionButtonHeight / 2

        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        circle.addSubview(icon)

        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: Self.actionButtonHeight),
            circle.heightAnchor.constraint(equalToConstant: Self.actionButtonHeight),
            icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30)
        ])

        circle.invertOnFocus = [icon]
        return circle
    }

    // MARK: - Statics

    private static func formattedAirDate(_ raw: String) -> String? {
        guard let date = plexDateParser.date(from: String(raw.prefix(10))) else { return nil }
        return airDateDisplay.string(from: date)
    }
    private static let plexDateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let airDateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func formatRuntime(_ runtime: TimeInterval) -> String {
        let minutes = Int(runtime / 60)
        let hours = minutes / 60
        let remaining = minutes % 60
        if hours > 0 {
            return remaining > 0 ? "\(hours)h \(remaining)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private static func kindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .movie: return "Movie"
        case .show, .season, .episode: return "TV Show"
        case .collection: return "Collection"
        case .playlist: return "Playlist"
        case .person: return "Person"
        case .unknown: return ""
        }
    }

    static func makeCaptionLabel(_ text: String, alpha: CGFloat) -> UILabel {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = text
        l.font = captionFont
        l.textColor = UIColor.white.withAlphaComponent(alpha)
        return l
    }

    /// Bordered rating / quality badge, 22pt tall in total (Apple's badge cap).
    static func makeBadge(_ text: String, alpha: CGFloat) -> UIView {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(alpha)
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(alpha * 0.7).cgColor
        container.layer.cornerRadius = 4
        container.layer.cornerCurve = .continuous
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }
}

/// What the show page's Watched prompt says: the watched count, and only the
/// choices that would change an episode. Without counts it offers both.
struct ShowWatchPrompt: Equatable {
    struct Choice: Equatable {
        let title: String
        let markWatched: Bool
    }

    static let markWatched = Choice(title: "Mark All Watched", markWatched: true)
    static let markUnwatched = Choice(title: "Mark All Unwatched", markWatched: false)

    let message: String?
    let choices: [Choice]

    init(progress: ChildProgress?) {
        guard let progress, progress.total > 0 else {
            message = nil
            choices = [Self.markWatched, Self.markUnwatched]
            return
        }
        let total = progress.total
        let played = min(max(progress.played, 0), total)
        message = "\(played) of \(total) episodes watched."
        choices = (played < total ? [Self.markWatched] : []) + (played > 0 ? [Self.markUnwatched] : [])
    }
}
