// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaDetailChromeView.swift
//  Rivulet
//
//  The shared chrome surface — logo / genre row / description / quality
//  row / action+cast row — used by the carousel cell (`PreviewCardView`,
//  which also backs the standalone detail) and the home hero button row
//  (`HeroButtonRowView`).
//
//  Layout structure:
//
//      ┌─────────────────────────────────────────┐  ← self
//      │ ┌──────────────────┐                    │
//      │ │ metadataBlock    │  (760pt max)       │
//      │ │   logoSlot       │                    │
//      │ │   genreRow       │                    │
//      │ │   descLabel      │                    │
//      │ │   qualityRow     │                    │
//      │ └──────────────────┘                    │
//      │  ↕ 32pt                                 │
//      │ ┌───────────────────────────────────────┤
//      │ │ actionAndCastRow (full width)         │
//      │ │   [Play][Watched][+][i]    Starring … │
//      │ └───────────────────────────────────────┤
//      └─────────────────────────────────────────┘
//
//  The carousel cell anchors this view bottom-leading inside the card,
//  with the card's horizontal insets (118pt) applied to self's leading
//  and trailing anchors. The expanded detail VC anchors it bottom-leading
//  to the screen with the expanded insets (140pt). The chrome view itself
//  is layout-agnostic — it just lays out its own internal stack from the
//  width its host gives it.
//
//  Animation:
//   - The host owns the cascade timer. This view exposes `chromeAlpha`
//     which forwards directly to `self.alpha`.
//   - The vignette is OUTSIDE this view (owned by the host: carousel
//     cell or expanded-detail VC) because the vignette is part of the
//     surrounding hero, not the chrome content.
//
//  Mode:
//   - `.carouselStable` — action row is interaction-disabled (carousel
//     paging owns input). This is the only mode wired up in Iter A.
//   - `.expandedDetail` — action row becomes focus-enabled and tap-wired
//     (Iter B+). Mode is a property so the host can flip it; this view
//     reads it during `applyItem`.
//

import UIKit
import os.log

private let chromeLog = Logger(
    subsystem: "com.rivulet.app",
    category: "MediaDetailChromeView"
)

final class MediaDetailChromeView: UIView {

    /// Hardcoded action-button sizing shared with the home hero's
    /// `HeroPillButton`/`HeroCircleButton` (see `HeroButtonRowView`) so the
    /// carousel/expanded-detail row matches the hero exactly. Width is
    /// fixed regardless of content (icon/label/progress) so pills don't
    /// grow or shrink per item.
    private static let actionButtonHeight: CGFloat = HeroPillButton.buttonHeight
    private static let actionPillWidth: CGFloat = HeroPillButton.pillWidth
    private static let playProgressTrackWidth: CGFloat = 60

    // MARK: - Public surface

    /// Layout mode — narrows insets, swaps action-row interactivity.
    /// In Iter A only `.carouselStable` is exercised; the structure is in
    /// place for Iter B to flip to `.expandedDetail`.
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

    /// Action callbacks. In `.carouselStable` mode these are not invoked
    /// (action row is interaction-disabled). Wired in `.expandedDetail`
    /// during Iter B/D.
    var onPlay: (() -> Void)?
    var onToggleWatched: (() -> Void)?
    var onToggleWatchlist: (() -> Void)?
    var onShowFullDescription: ((MediaItemDetail) -> Void)?

    /// The Play pill (rebuilt per item). Exposed so the host cell can point the
    /// focus engine at Play when the detail expands.
    private(set) var playButton: FocusableActionButton?
    /// Preferred focus target for the action row (Play), or nil before detail loads.
    var playFocusable: UIView? { playButton }

    /// Fill width of the Play pill's watch-progress bar, held so the fraction can
    /// be set after the pill is built — on a show/season the bar belongs to the
    /// episode Play resolves to, which only arrives asynchronously. Rebuilt with
    /// the pill.
    private var playProgressFillWidth: NSLayoutConstraint?
    /// The Play pill's time readout. Held so `setPlayTarget` can rewrite it —
    /// the pill is built once and only its watch-derived bits change.
    private weak var playTimeLabel: UILabel?

    // MARK: - State

    /// Monotonic load token. Bumped on every `applyItem()`; async detail
    /// fetch checks against this on completion and discards stale results.
    /// Prevents wrong metadata from snapping in when item changes quickly.
    private var loadToken: UInt64 = 0

    /// Cached detail, populated by `loadDetail()` when it lands. Used to
    /// repopulate genre + quality rows + cast label with richer fields.
    private var detail: MediaItemDetail?

    /// Per-item aspect-ratio constraint on the logo image view. Plex
    /// logo assets are typically wide PNGs with the visible glyphs at
    /// natural aspect (no transparent padding) — but `.scaleAspectFit`
    /// in a UIImageView CENTERS the content inside the view bounds,
    /// which would offset the visible glyphs right of the metadata's
    /// leading edge. Installing a width = height * imageAspect
    /// constraint when the image lands sizes the view exactly to the
    /// visible pixels, so leading-aligned constraint to the metadata
    /// edge lines up the glyphs flush left.
    private var logoAspectConstraint: NSLayoutConstraint?

    // MARK: - Subviews

    /// Outer vertical stack — bottom-leading aligned by the host. Contains
    /// the metadata block + the action+cast row.
    private let chromeStack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        // LEADING, not .fill: the metadata block has a ≤760 width cap, and
        // .fill pins both its edges to the stack — an undefined conflict that
        // could snap the block to the trailing edge (far right) when the chrome
        // is wider than 760. Leading-align it deterministically; the action row
        // gets an explicit full-width constraint instead.
        s.alignment = .leading
        s.spacing = 14
        return s
    }()

    /// Inner metadata block — vertical stack, max 760pt wide.
    /// Natural-content height: takes as much vertical space as the logo
    /// slot (138pt) + genre row + description + quality row + spacing.
    /// The outer `chromeStack` settles this block above the action row;
    /// the chrome view itself is anchored from below by the card.
    /// Matches the carousel-stable layout at commit `bc127a9` (the
    /// agreed visual baseline at the start of Iter A).
    private let metadataBlock: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.alignment = .leading
        s.spacing = 14
        return s
    }()

    /// Logo slot — fixed 138pt tall, 620pt max wide, bottom-leading
    /// aligned. Either the logo image or the fallback label occupies it
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
        l.font = .systemFont(ofSize: 52, weight: .bold)
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
        s.spacing = 8
        s.alignment = .center
        return s
    }()

    /// Italic tagline OR plain overview, up to 3 lines / 560pt wide.
    private let descriptionLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 24, weight: .regular)
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        l.numberOfLines = 4
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// "Next Up: S1E3 · Title" (or "Resume:" when the target is in progress),
    /// shown between the metadata block and the action row on show/season cards
    /// so the user knows which episode Play will start. Hidden for movies and
    /// episodes, and until the target episode resolves.
    private let nextUpLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 22, weight: .semibold)
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        l.isHidden = true
        return l
    }()

    /// "2023 · 49 min   ⭐ 7.8   [4K] [DV] [5.1]" — caption.bold(), white.
    private let qualityRow: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .horizontal
        s.spacing = 8
        s.alignment = .center
        return s
    }()

    /// Bottom action+cast row. NOT a stack view — using a UIStackView
    /// here was causing the action buttons to flash stretched-wide on
    /// the first layout pass before constraints settled. A plain
    /// UIView with explicit leading/trailing constraints on the two
    /// children gives byte-stable widths from frame zero: action
    /// buttons hug their content on the left, cast label hugs its
    /// content on the right, the gap between is the leftover.
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
        s.spacing = 18
        return s
    }()

    /// "Starring …" text, right-aligned, capped at 460pt.
    private let castLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 24, weight: .regular)
        l.textColor = UIColor.white.withAlphaComponent(0.85)
        l.numberOfLines = 3
        l.textAlignment = .right
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// Season pages only: the season's poster, large, leading of the whole text
    /// column. Hidden for every other kind — movie/show heroes stay
    /// backdrop-driven.
    private let seasonPosterView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = 14
        v.layer.cornerCurve = .continuous
        v.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        v.isHidden = true
        return v
    }()
    /// The text column's leading: on the chrome edge normally, indented past the
    /// poster on season pages. Exactly one is active at a time (deactivate before
    /// activate — both constrain chromeStack.leading).
    private var chromeLeadingDefault: NSLayoutConstraint!
    private var chromeLeadingWithPoster: NSLayoutConstraint!

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

        // Equal rhythm across the lower block: description → quality → action
        // all separated by the same gap. (description→quality is a custom
        // metadataBlock spacing; quality→action is the chromeStack gap.)
        metadataBlock.setCustomSpacing(30, after: descriptionLabel)
        chromeStack.setCustomSpacing(30, after: metadataBlock)
        chromeStack.addArrangedSubview(nextUpLabel)
        chromeStack.setCustomSpacing(16, after: nextUpLabel)
        chromeStack.addArrangedSubview(actionAndCastRow)

        // actionAndCastRow is a plain UIView (not a stack). Children
        // are pinned explicitly: actionButtonsStack to leading +
        // centerY, castLabel to trailing + centerY, with a min-gap
        // between. The two compete only over the gap, so neither
        // can stretch beyond its content width.
        actionAndCastRow.addSubview(actionButtonsStack)
        actionAndCastRow.addSubview(castLabel)

        // Each action button has a hardcoded width (Self.actionPillWidth /
        // Self.actionButtonHeight), so the stack already settles at a
        // fixed total width. Hugging is still set to .required so the
        // stack itself never stretches beyond the sum of its children.
        actionButtonsStack.setContentHuggingPriority(.required, for: .horizontal)
        actionButtonsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        castLabel.setContentHuggingPriority(.required, for: .horizontal)

        let descMaxWidth = descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        descMaxWidth.priority = .required

        addSubview(seasonPosterView)
        chromeLeadingDefault = chromeStack.leadingAnchor.constraint(equalTo: leadingAnchor)
        chromeLeadingWithPoster = chromeStack.leadingAnchor.constraint(
            equalTo: seasonPosterView.trailingAnchor, constant: 48)
        chromeLeadingDefault.isActive = true

        NSLayoutConstraint.activate([
            // Chrome stack fills self (leading is the default/poster pair above).
            chromeStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeStack.topAnchor.constraint(equalTo: topAnchor),
            chromeStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Season poster: bottom-aligned with the chrome (the action row),
            // growing upward to its preferred height; the required top bound
            // shrinks it on shorter chromes instead of overflowing the hero.
            seasonPosterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            seasonPosterView.bottomAnchor.constraint(equalTo: chromeStack.bottomAnchor),
            seasonPosterView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            seasonPosterView.widthAnchor.constraint(equalTo: seasonPosterView.heightAnchor, multiplier: 2.0 / 3.0),
            {
                let c = seasonPosterView.heightAnchor.constraint(equalToConstant: 480)
                c.priority = .init(999)
                return c
            }(),

            // Logo slot: 138pt tall, 620pt max wide.
            logoSlotView.heightAnchor.constraint(equalToConstant: 138),
            logoSlotView.widthAnchor.constraint(lessThanOrEqualToConstant: 620),

            // Logo image: aspectFit, bottom-leading inside the slot.
            // No fixed height — a 500×120 logo renders at 500×120.
            titleLogoImageView.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleLogoImageView.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleLogoImageView.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),
            titleLogoImageView.topAnchor.constraint(greaterThanOrEqualTo: logoSlotView.topAnchor),
            // Cap height at slot height; prefer to fill it. The
            // priority-999 equality lets the inequality + aspect
            // constraints drive height down when an extra-wide asset
            // would push width past the 620pt slot.
            titleLogoImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 138),
            {
                let c = titleLogoImageView.heightAnchor.constraint(equalToConstant: 138)
                c.priority = .init(999)
                return c
            }(),

            // Fallback label: bottom-leading inside the slot.
            titleFallbackLabel.leadingAnchor.constraint(equalTo: logoSlotView.leadingAnchor),
            titleFallbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: logoSlotView.trailingAnchor),
            titleFallbackLabel.bottomAnchor.constraint(equalTo: logoSlotView.bottomAnchor),

            descMaxWidth,

            // Metadata block capped at 760pt wide. Block height is
            // natural (content-driven); chromeStack pins it above the
            // action row from below. With .leading alignment it sits at the
            // leading edge at its natural width — no trailing-pin conflict.
            metadataBlock.widthAnchor.constraint(lessThanOrEqualToConstant: 760),

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

            // Cast label pins to trailing + centerY, capped at 460pt.
            castLabel.trailingAnchor.constraint(equalTo: actionAndCastRow.trailingAnchor),
            castLabel.centerYAnchor.constraint(equalTo: actionAndCastRow.centerYAnchor),
            castLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),

            // Min 40pt gap between buttons and cast label. The cast
            // can compress its width down to 0 (lessThanOrEqual width
            // cap) when needed, but the action buttons keep their
            // intrinsic widths.
            castLabel.leadingAnchor.constraint(greaterThanOrEqualTo: actionButtonsStack.trailingAnchor, constant: 40)
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

    /// Make the action buttons (un)focusable WITHOUT changing mode. Used when the
    /// user enters the below-fold (details): the chrome is faded out, and its
    /// buttons must be non-focusable so focus can't escape UP from the below-fold
    /// primary row into a chrome button (which is the hero → "jumps to carousel").
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
        clearSeasonPoster()
    }

    /// Put the chrome back on its default (posterless) leading. Both call sites
    /// must run this before deciding whether the new item wants a poster.
    private func clearSeasonPoster() {
        seasonPosterView.image = nil
        seasonPosterView.isHidden = true
        chromeLeadingWithPoster.isActive = false
        chromeLeadingDefault.isActive = true
    }

    /// Install a width = height × imageAspect constraint on
    /// `titleLogoImageView` so the view bounds tightly wrap the
    /// visible image pixels. Without this, `.scaleAspectFit` would
    /// center the scaled image inside an artificially-wide view and
    /// the glyphs would float right of the metadata's leading edge.
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

    /// Repaint only the watch-derived hero bits from a re-fetched copy of the
    /// SAME item (issue #228: the hero kept showing the pre-playback state
    /// after the player dismissed).
    ///
    /// Deliberately NOT `self.item = refreshed`: that `didSet` runs the full
    /// `applyItem()`, which tears down and rebuilds the action row — and the
    /// Play pill is very often the focused view when the player dismisses back
    /// onto the hero. Only the watched glyph and the Next Up / Resume label
    /// depend on watch state, so both are updated in place.
    func refreshWatchState(from refreshed: MediaItem) {
        guard let current = item, current.ref == refreshed.ref else { return }
        // Keep the stored item current so a later toggle/Play reads fresh state.
        isRefreshingWatchState = true
        item = refreshed
        isRefreshingWatchState = false

        heroWatched = refreshed.isWatched
        updateWatchedIcon()
        setPlayTarget(refreshed)

        // Shows/seasons: the "Next Up: S1E3 · Title" line moves to the next
        // unwatched episode. Clear it first so a show that just finished isn't
        // left promising the episode the user has now watched.
        nextUpLabel.isHidden = true
        nextUpLabel.text = nil
        resolveNextUpLabel(for: refreshed, token: loadToken)
    }

    /// Set while `refreshWatchState` swaps the re-fetched item in, so the
    /// `item` `didSet` skips the full rebuild.
    private var isRefreshingWatchState = false

    private func applyItem() {
        loadToken &+= 1
        let token = loadToken

        titleLogoImageView.image = nil
        titleFallbackLabel.text = nil
        descriptionLabel.text = nil
        descriptionLabel.attributedText = nil
        resolvedGenres = []
        genreRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        qualityRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        nextUpLabel.isHidden = true
        nextUpLabel.text = nil
        clearSeasonPoster()

        guard let item = item else { return }

        // Season pages: the season's poster, large, indenting the text column.
        // Memory-cache probe first for a flash-free frame 0, like the logo.
        if item.kind == .season, let posterURL = item.artwork.poster ?? item.artwork.thumbnail {
            seasonPosterView.isHidden = false
            chromeLeadingDefault.isActive = false
            chromeLeadingWithPoster.isActive = true
            if let cached = ImageCacheManager.shared.cachedImage(for: posterURL) {
                seasonPosterView.image = cached
            } else {
                Task { [weak self] in
                    let image = await ImageCacheManager.shared.image(for: posterURL)
                    await MainActor.run {
                        guard let self, self.loadToken == token, let image else { return }
                        self.seasonPosterView.image = image
                    }
                }
            }
        }

        rebuildGenreRow(item: item, detail: nil)
        rebuildQualityRow(item: item, detail: nil)
        rebuildActionButtons(item: item)
        resolveNextUpLabel(for: item, token: token)

        // Clear any aspect constraint from the previous item — a stale
        // ratio would size the new image wrong while it's loading.
        if let prev = logoAspectConstraint {
            prev.isActive = false
            logoAspectConstraint = nil
        }

        // Logo: probe the memory cache synchronously first. If the
        // logo is already cached (which it nearly always is when the
        // chrome is being shown in the expanded detail — the carousel
        // cell underneath has already loaded it), render the image on
        // frame 0 with no fallback-text flash. Otherwise show the
        // fallback label and start the async load.
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
                Task { [weak self] in
                    let image = await ImageCacheManager.shared.image(for: logoURL)
                    await MainActor.run {
                        guard let self else { return }
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
                Task { [weak self] in
                    guard let logoURL = await TMDBLogoCache.shared.logoURL(tmdbId: tmdbID, type: type) else { return }
                    let image = await ImageCacheManager.shared.image(for: logoURL)
                    await MainActor.run {
                        guard let self else { return }
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
        Task { [weak self] in
            guard let self, let fetched = await Self.fetchDetail(item.ref) else { return }
            // An episode's own detail has no genres — fall back to the parent
            // show's genres (same as the episode detail page).
            var genres = fetched.genres
            if genres.isEmpty, item.kind == .episode, let showRef = item.grandparentRef,
               let showDetail = await Self.fetchDetail(showRef) {
                genres = showDetail.genres
            }
            await MainActor.run {
                guard self.loadToken == token else { return }
                self.detail = fetched
                self.resolvedGenres = genres
                self.applyDetail(item: item, detail: fetched)
            }
        }
    }

    private var resolvedGenres: [String] = []

    /// Resolve the episode Play will start on a show/season card and show it as
    /// "Next Up: S1E3 · Title" (or "Resume:" mid-episode). Uses the same
    /// `EpisodePicker.resolvePlayTarget` the Play button does, so the label can
    /// never promise a different episode than the one that plays.
    private func resolveNextUpLabel(for item: MediaItem, token: UInt64) {
        guard item.kind == .show || item.kind == .season else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID),
                  let episode = await EpisodePicker.resolvePlayTarget(for: item, provider: provider),
                  self.loadToken == token
            else { return }
            // The pill tracks the episode Play will start, not the show — a show
            // has no runtime of its own, so this is also where its pill stops
            // saying "Play" and starts saying how long that episode runs.
            self.setPlayTarget(episode)
            guard let text = EpisodePicker.nextUpLabel(for: episode) else { return }
            self.nextUpLabel.text = text
            self.nextUpLabel.isHidden = false
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
                .font: UIFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: color])
            attr.append(NSAttributedString(string: overview, attributes: [
                .font: UIFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: color]))
            descriptionLabel.attributedText = attr
        } else if let tagline = detail.tagline, !tagline.isEmpty {
            descriptionLabel.text = tagline
            descriptionLabel.font = UIFont.italicSystemFont(ofSize: 24)
        } else if let overview = detail.item.overview, !overview.isEmpty {
            descriptionLabel.text = overview
            descriptionLabel.font = .systemFont(ofSize: 24, weight: .regular)
        }
        let topCast = detail.cast.prefix(3).map { $0.name }
        if !topCast.isEmpty {
            castLabel.text = "Starring \(topCast.joined(separator: ", "))"
        } else {
            castLabel.text = nil
        }
    }

    // MARK: - Row builders

    private func rebuildActionButtons(item: MediaItem) {
        actionButtonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Metadata-only items (TMDB/Discover, unmatched watchlist entries)
        // have no playback route — no provider is registered for their ref,
        // so Play / Watched / provider-watchlist would all silently no-op.
        // Their primary action is the Watchlist toggle instead.
        if item.isMetadataOnly {
            rebuildMetadataOnlyActions(item: item)
            return
        }

        // Carousel-stable button set (agreed in perf-spike commits up to
        // bc127a9): Play pill + Watched + Watchlist + Info. The SwiftUI
        // source has a wider set (Trailer, Audio, Subs) that's gated by
        // detail content — we don't surface those in the carousel.
        let play = makePlayPill(item: item)
        play.onPrimaryAction = { [weak self] in self?.onPlay?() }
        // Movie/episode: the item's own progress and runtime. Show/season: reads
        // "Play" with an empty bar until the Play target resolves async in
        // `resolveNextUpLabel`, which sets it from that episode.
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
        info.onPrimaryAction = { [weak self] in
            guard let self, let detail = self.detail else { return }
            self.onShowFullDescription?(detail)
        }

        actionButtonsStack.addArrangedSubview(play)
        actionButtonsStack.addArrangedSubview(watched)
        actionButtonsStack.addArrangedSubview(watchlist)
        actionButtonsStack.addArrangedSubview(info)
        playButton = play
    }

    /// Metadata-only (TMDB) action row: Watchlist pill + Info. The pill
    /// toggles the Plex Discover watchlist via the tmdb guid (the provider
    /// registry has no entry for TMDB refs). No Watched circle — external
    /// items carry no watch state.
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
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.textColor = .white

        let contentStack = UIStackView(arrangedSubviews: [icon, label])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 12

        pill.addSubview(contentStack)
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: Self.actionPillWidth),
            pill.heightAnchor.constraint(equalToConstant: Self.actionButtonHeight),
            contentStack.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: pill.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: pill.trailingAnchor, constant: -18),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20)
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
    private var heroWatched = false
    private var heroOnWatchlist = false

    private func toggleWatched(_ item: MediaItem) {
        heroWatched.toggle()
        updateWatchedIcon()
        let target = heroWatched
        Task {
            guard let p = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
            if target { try? await p.markPlayed(item.ref) } else { try? await p.markUnplayed(item.ref) }
            // Issue #270: the glyph was the only thing that moved. This is the
            // same repaint the player posts on dismissal, so the hero's Next Up
            // line, the episode rail, and Home's Continue Watching row all
            // re-read the state this toggle just changed.
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

        var parts: [String] = []
        parts.append(Self.kindLabel(item.kind))
        // resolvedGenres includes the parent show's genres for episodes (an
        // episode's own detail has none).
        for genre in resolvedGenres.prefix(2) {
            parts.append(genre)
        }
        parts.removeAll(where: { $0.isEmpty })

        for (i, part) in parts.enumerated() {
            if i > 0 {
                genreRow.addArrangedSubview(Self.makeCaptionLabel("·", alpha: 0.5, bold: true))
            }
            genreRow.addArrangedSubview(Self.makeCaptionLabel(part, alpha: 0.85, bold: true))
        }

        if let contentRating = detail?.contentRating, !contentRating.isEmpty {
            genreRow.addArrangedSubview(Self.makeContentRatingBadge(contentRating))
        }
    }

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

        for (i, part) in parts.enumerated() {
            if i > 0 {
                qualityRow.addArrangedSubview(Self.makeCaptionLabel("·", alpha: 0.7, bold: true))
            }
            qualityRow.addArrangedSubview(Self.makeCaptionLabel(part, alpha: 1, bold: true))
        }

        if let rating = detail?.rating {
            let star = UIImageView(image: UIImage(systemName: "star.fill"))
            star.tintColor = .systemYellow
            star.contentMode = .scaleAspectFit
            star.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                star.widthAnchor.constraint(equalToConstant: 20),
                star.heightAnchor.constraint(equalToConstant: 20)
            ])
            let ratingLabel = Self.makeCaptionLabel(String(format: "%.1f", rating), alpha: 1, bold: true)
            let starStack = UIStackView(arrangedSubviews: [star, ratingLabel])
            starStack.axis = .horizontal
            starStack.spacing = 4
            starStack.alignment = .center
            qualityRow.addArrangedSubview(starStack)
        }

        if let badges = detail?.mediaSources.first?.qualityBadges(), !badges.isEmpty {
            for badge in badges {
                qualityRow.addArrangedSubview(Self.makeQualityBadge(badge))
            }
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

        let timeLabel = UILabel()
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        timeLabel.textColor = .white
        // Text is set by `setPlayTarget`, called right after this returns (and
        // again on every refresh) — building it here too would just be a second
        // rule to keep in sync.
        playTimeLabel = timeLabel

        let progressTrack = UIView()
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        progressTrack.layer.cornerRadius = 1.5
        progressTrack.clipsToBounds = true

        let progressFill = UIView()
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = .white
        progressTrack.addSubview(progressFill)
        let fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        playProgressFillWidth = fillWidth

        // Content is centered in the pill (not leading-anchored) so a
        // hardcoded pill width wider than the content doesn't leave it
        // stranded on the left.
        let contentStack = UIStackView(arrangedSubviews: [playIcon, progressTrack, timeLabel])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 12

        pill.addSubview(contentStack)

        // Pill width is hardcoded (Self.actionPillWidth), shared with the
        // hero's play pill — not derived from icon/progress/label content.
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: Self.actionPillWidth),
            pill.heightAnchor.constraint(equalToConstant: Self.actionButtonHeight),

            contentStack.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: pill.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: pill.trailingAnchor, constant: -18),

            playIcon.widthAnchor.constraint(equalToConstant: 20),
            playIcon.heightAnchor.constraint(equalToConstant: 20),

            progressTrack.heightAnchor.constraint(equalToConstant: 3),
            progressTrack.widthAnchor.constraint(equalToConstant: Self.playProgressTrackWidth),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillWidth
        ])

        pill.invertOnFocus = [playIcon, timeLabel]
        pill.invertBackgroundOnFocus = [progressTrack]
        pill.invertFillOnFocus = [progressFill]
        return pill
    }

    /// Point the Play pill at what pressing it would actually play: `item` is the
    /// hero item for a movie/episode, and the resolved Next Up / Resume episode
    /// for a show.
    ///
    /// The bar: the track always stays — unstarted, watched and finished all show
    /// the empty stub; only the fill comes and goes. Same 0 < fraction < 1 render
    /// rule the episode cells use (see `WatchProgressPolicy`: the DISPLAY
    /// question, not the resume decision), so a finished item reads as empty
    /// rather than full.
    ///
    /// The label: REMAINING time on a part-watched item, total runtime otherwise.
    /// It used to be total runtime unconditionally, so a movie 8 minutes in read
    /// "1h 38m" on the detail while its Continue Watching tile read "1h 30m"
    /// beside it (issue #279). The tile's rule is the one to match — it is the
    /// same question asked of the same item.
    private func setPlayTarget(_ item: MediaItem) {
        let fraction = item.watchProgress
        let partial = (fraction.map { $0 > 0 && $0 < 1 }) ?? false

        if let fillWidth = playProgressFillWidth {
            fillWidth.constant = partial
                ? Self.playProgressTrackWidth * CGFloat(fraction ?? 0)
                : 0
        }

        playTimeLabel?.text = Self.playPillTime(
            runtime: item.runtime,
            viewOffset: item.userState.viewOffset,
            partiallyWatched: partial)
    }

    /// The Play pill's readout. Pure, so the rule is unit-testable without
    /// building a view.
    static func playPillTime(runtime: TimeInterval?, viewOffset: TimeInterval, partiallyWatched: Bool) -> String {
        guard let runtime, runtime > 0 else { return "Play" }
        guard partiallyWatched else { return formatRuntime(runtime) }
        let remaining = max(0, runtime - viewOffset)
        // A sub-minute remainder formats as "0m", which reads as broken; the
        // total is the honest fallback there.
        return formatRuntime(remaining >= 60 ? remaining : runtime)
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
        case .person: return "Person"
        case .unknown: return ""
        }
    }

    private static func makeCaptionLabel(_ text: String, alpha: CGFloat, bold: Bool = false) -> UILabel {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = text
        l.font = bold ? .systemFont(ofSize: 24, weight: .bold) : .systemFont(ofSize: 24, weight: .regular)
        l.textColor = UIColor.white.withAlphaComponent(alpha)
        return l
    }

    private static func makeContentRatingBadge(_ text: String) -> UIView {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        container.layer.cornerRadius = 4
        container.layer.cornerCurve = .continuous
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2)
        ])
        return container
    }

    private static func makeQualityBadge(_ text: String) -> UIView {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 21, weight: .bold)
        label.textColor = .white
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        container.layer.cornerRadius = 4
        container.layer.cornerCurve = .continuous
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2)
        ])
        return container
    }
}
