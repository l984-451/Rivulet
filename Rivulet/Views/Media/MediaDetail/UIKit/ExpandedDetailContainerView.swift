// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ExpandedDetailContainerView.swift
//  Rivulet
//
//  The below-fold detail surface for the UIKit preview carousel. Owned by
//  `PreviewCarouselViewController`, it sits above the collection view (which
//  holds the hero chrome) and below nothing else.
//
//  P2 lifecycle: this surface is active in BOTH carousel-stable and expanded
//  states. In carousel-stable it shows the episode PEEK for the centered card
//  (cascading in WITH the chrome/metadata, snapping out + re-cascading as you
//  page). Expanding just grows the hero above it; the peek stays put (its
//  bottom is already at the screen bottom in both states). Pressing Down then
//  scrolls the below-fold up, fading the hero and revealing the seasons header.
//
//  Layers it owns: the content translation, the header-reserve growth, the
//  episode-peek cascade, the seasons-header + small-logo crossfades. Layers it
//  does NOT own (the backdrop blur + hero chrome fade) live in the VC and are
//  driven from `onScrollProgress`.
//
//  Single clock (UIKIT_FOUNDATIONS §6): `scrollOffset` is the only scroll
//  timeline; `apply()` fans it out in one pass. The episode-peek cascade is a
//  separate, chrome-synced timeline (page changes, not scroll).
//
//  This session: TV route with INERT placeholders (episode card row + season
//  pill bar). Real cells + focus-driven scrolling come later. See
//  docs/superpowers/specs/2026-06-01-uikit-expanded-detail-belowfold-design.md.
//

import UIKit

final class ExpandedDetailContainerView: UIView {

    // MARK: - Choreography clock

    private(set) var scrollOffset: CGFloat = 0

    /// Distance over which the hero→details fades complete (SwiftUI parity).
    // The episode slide travels ~800pt (peek → details). Scale progress over
    // most of that so the blur/fade/logo ride the whole movement, not just the
    // first fraction of it.
    static let reserveDistance: CGFloat = 600

    /// Down-press target: scroll past saturation to bring the below-fold up.
    /// Tuning constant, dialed on-device.
    static let detailsRest: CGFloat = 420

    var scrollProgress: CGFloat { min(1, max(0, scrollOffset / Self.reserveDistance)) }
    // Logo fades in mid-slide (off 300→550), after the carousel metadata has
    // cleared (~off 230), so they don't overlap.
    private var belowFoldTitleOpacity: CGFloat { min(1, max(0, (scrollOffset - 300) / 250)) }

    /// Called each `apply()` so the VC can drive the layers it owns (blur + chrome).
    var onScrollProgress: ((CGFloat) -> Void)?
    /// Forwarded up to the host VC to present the About popups.
    var onSelectSynopsis: ((MediaItemDetail) -> Void)?
    var onSelectAdvisory: ((ContentAdvisory) -> Void)?

    private(set) var maxScrollOffset: CGFloat = 0

    // MARK: - Layout constants

    /// Fixed below-fold page height (scroll room). Screen-independent: combined
    /// with the `screen − shelfPeek` spacer it yields a constant max scroll.
    private static let belowFoldHeight: CGFloat = 700
    /// Gap from the hero shelf to the top of the episode peek at rest. Larger
    /// gap = thinner/lower peek (visible peek ≈ shelfPeek − peekTopGap), without
    /// moving the metadata. Tuned so episodes show as a shallow bottom strip.
    private static let peekTopGap: CGFloat = 70
    /// Episode-peek horizontal insets. Carousel-stable aligns to the inset card
    /// (left with the metadata, right clipped at the card edge); expanded goes
    /// near-full-bleed. The inset animates on expand (driven by the VC, Step 3).
    /// Carousel-stable: clip spans the card width (card edge = 88) so the 4
    /// thumbs center within the card.
    /// Vertical slack inside the season-pill scroller so a focused pill's 1.05
    /// scale isn't clipped by the scroller's bounds.
    private static let seasonPillFocusPad: CGFloat = 8
    private static let peekLeadingCarousel: CGFloat = 88
    private static let peekTrailingCarousel: CGFloat = 88
    private static let peekLeadingExpanded: CGFloat = 0
    private static let peekTrailingExpanded: CGFloat = 0

    /// Episode thumb width: carousel vs expanded (elongates slightly on expand).
    private static let thumbWidthCarousel: CGFloat = 360
    private static let thumbWidthExpanded: CGFloat = 370

    // MARK: - Input

    var item: MediaItem? {
        didSet {
            guard item != oldValue else { return }
            guard !isSwappingItemInPlace else { return }
            applyItem()
        }
    }

    /// Set while `updateItemInPlace` swaps a re-fetched copy of the current
    /// item in, so the `didSet` skips the full rail rebuild.
    private var isSwappingItemInPlace = false

    // MARK: - Subviews

    private let contentView = UIView()
    private let spacer = UIView()
    private let belowFoldPage = UIView()

    private let smallTitleLogo = UIImageView()
    /// Season pill bar — the scrolled-in header. Lives in the reserve gap above
    /// the episodes; fades in with `scrollProgress` (invisible at rest).
    private let seasonsHeader = UIView()
    private let seasonPillScroll = UIScrollView()
    private let seasonPillRow = UIStackView()
    private var seasonPills: [SeasonPillView] = []
    private var seasonRefIDs: [String] = []   // parallel to seasonPills (pill → season ref.itemID)
    private var selectedSeasonIndex = 0

    /// Season info strip — poster + counts + summary for the season the pills
    /// are tracking, between the pill row and the episode rail. Display-only and
    /// never focusable: it follows pill selection and the rail's episode
    /// tracking, so it adds no focus surface to reason about.
    private let seasonInfoStrip = UIView()
    private let stripPoster = UIImageView()
    private let stripMeta = UILabel()
    private let stripSummary = UILabel()
    private static let seasonStripHeight: CGFloat = 132
    /// The full season items behind the pills. The pills only ever needed the
    /// labels, so the poster/summary/progress used to be discarded at build.
    private var seasonItems: [MediaItem] = []
    private var stripPosterToken: UInt64 = 0
    /// The season the strip is currently showing (nil = hidden). `selectSeasonPill`
    /// fires on every episode focus move as the rail tracks seasons, so without a
    /// same-season no-op the poster load would restart on each one and flicker.
    private var stripSeasonID: String?
    /// Watched counts recomputed from the rail's own episodes after a watch-state
    /// change, keyed by season ref itemID. `seasonItems` comes from the seasons
    /// fetch, which only re-runs on a full `configure` — so without this the strip
    /// kept saying "3 watched" while the episode cell directly below it had
    /// already picked up its watched glyph.
    private var seasonProgressOverrides: [String: ChildProgress] = [:]

    /// Which row of the details has focus. The VC sets this before requesting a
    /// focus update so `belowFoldFocusEnvironment` routes to the right place.
    enum DetailsFocusTarget { case episodes, pills }
    var detailsFocusTarget: DetailsFocusTarget = .episodes {
        didSet { applyPillFocusability() }
    }

    /// Pills are focusable ONLY while the user is in the pill row. When focus is
    /// on the episodes they are non-focusable, so the focus engine's spatial Up
    /// move finds no pill and stays put; the Up handler then sets the target to
    /// .pills (enabling them here) and drives focus straight to the SELECTED
    /// pill — no intermediate wrong-pill landing.
    private func applyPillFocusability() {
        let on = detailsFocusTarget == .pills
        for pill in seasonPills where pill.focusEnabled != on { pill.focusEnabled = on }
    }
    /// True while a season pill (not an episode) holds focus. Drives the VC's
    /// Up/Down handling (Up from a pill collapses; Down from a pill → episodes).
    private(set) var focusIsOnPills = false
    var hasSeasonPills: Bool { !seasonPills.isEmpty }

    /// True while focus is on the episodes (top) row — as opposed to a lower
    /// section (Trailers/Related/Cast/About/Info). The Up handler only routes to
    /// the season pills from the episodes; from a lower row it lets the focus
    /// engine move up one row instead of jumping to the pills.
    var focusIsOnEpisodes: Bool { belowFoldCollection.focusIsOnEpisodes }

    /// Re-arm focus inside a shelf-host row (Related) after a modal. No-op
    /// unless focus was in such a row when the modal went up.
    func restoreShelfRowFocusIfNeeded() {
        belowFoldCollection.restoreShelfRowFocusIfNeeded()
    }

    /// Release the one-shot shelf-restore target after the focus update, so it
    /// can't hijack a later focus resolution.
    func clearArmedShelfRestore() {
        belowFoldCollection.clearArmedShelfRestore()
    }

    /// True briefly after the episode thumb took focus. The Up handler uses this
    /// to keep focus on the thumb when it just landed there (coming up from the
    /// description or a lower row); only a deliberate Up from a resting thumb
    /// lifts to the season pills.
    var episodeThumbJustTookFocus: Bool { belowFoldCollection.episodeThumbJustTookFocus }

    /// True while focus is on an episode description (the VC redirects Left/Right
    /// to the adjacent episode's thumb in this state).
    var episodeDescriptionFocused: Bool { belowFoldCollection.episodeDescriptionFocused }

    /// Arm focus on the adjacent episode's thumb (Left/Right from a description).
    /// The VC drives the focus update; call `clearArmedEpisodeFocus()` after.
    func armAdjacentEpisodeThumb(forward: Bool) -> Bool {
        belowFoldCollection.armAdjacentEpisodeThumb(forward: forward)
    }
    func clearArmedEpisodeFocus() { belowFoldCollection.clearArmedEpisodeFocus() }

    /// Episode Select actions, forwarded to the below-fold collection.
    var onPlayEpisode: ((MediaItem) -> Void)? {
        get { belowFoldCollection.onPlayEpisode }
        set { belowFoldCollection.onPlayEpisode = newValue }
    }
    var onPlayTrailer: ((BelowFoldTrailer) -> Void)? {
        get { belowFoldCollection.onPlayTrailer }
        set { belowFoldCollection.onPlayTrailer = newValue }
    }
    var onShowRelatedDetails: ((MediaItem) -> Void)? {
        get { belowFoldCollection.onShowRelatedDetails }
        set { belowFoldCollection.onShowRelatedDetails = newValue }
    }
    var onShowEpisodeDetails: ((MediaItem) -> Void)? {
        get { belowFoldCollection.onShowEpisodeDetails }
        set { belowFoldCollection.onShowEpisodeDetails = newValue }
    }
    var onSelectPerson: ((MediaPerson) -> Void)? {
        get { belowFoldCollection.onSelectPerson }
        set { belowFoldCollection.onSelectPerson = newValue }
    }
    /// Season pill Select → open that season's own page. Unwired, the pill falls
    /// back to re-affirming the season in the rail.
    var onOpenSeason: ((MediaItem) -> Void)?

    /// True briefly after focus first lands on the episodes row (same-press guard
    /// for the episodes→pills jump).
    var episodesJustTookFocus: Bool { belowFoldCollection.episodesJustTookFocus }

    /// Clipped window for the episode peek. Rectangular (square bottom) — the
    /// row inside overflows the trailing edge so an adjacent card peeks.
    private let episodesClip = UIView()
    private let episodesRow = UIStackView()

    /// The single focus-driven episode rail (Episodes/Related/Cast). Lives in a
    /// card-width clip so edge episodes hide behind the carousel border in
    /// carousel-stable and reveal as the clip widens to full-screen on expand.
    let belowFoldCollection = BelowFoldCollectionView()
    private let belowFoldClip = UIView()
    private var clipLeadingConstraint: NSLayoutConstraint!
    private var clipTrailingConstraint: NSLayoutConstraint!

    /// On expand the whole below-fold is translated left by this `pull` so the
    /// rail's leading lines up with the expanded metadata. That shift would pull
    /// the right edge IN by the same amount, so the collection is made `pull`
    /// wider on the right to compensate — content then reaches the screen edge.
    private static var belowFoldExpandPull: CGFloat {
        PreviewCarouselGeometry.centeredHorizontalInset
            + PreviewCarouselGeometry.carouselChromeInset
            - PreviewCarouselGeometry.expandedChromeInset
    }

    private var spacerHeightConstraint: NSLayoutConstraint!
    /// Episode-peek top inset = `peekTopGap + reserveDistance · scrollProgress`.
    private var episodesTopConstraint: NSLayoutConstraint!
    private var episodesLeadingConstraint: NSLayoutConstraint!
    private var episodesTrailingConstraint: NSLayoutConstraint!

    private var logoLoadToken: UInt64 = 0
    /// Bumped on every `setCurrent`; in-flight cascade blocks no-op if stale.
    private var cascadeToken: UInt64 = 0
    /// Width constraints of the 6 episode thumbs (animated on expand).
    private var thumbWidthConstraints: [NSLayoutConstraint] = []
    /// The 6 peek thumbnail image views (real episode artwork, loaded per item).
    private var peekThumbImageViews: [UIImageView] = []
    private var peekEpisodesToken: UInt64 = 0

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ExpandedDetailContainerView is not Storyboard-backed") }

    private func commonInit() {
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.backgroundColor = .clear
        contentView.addSubview(spacer)

        belowFoldPage.translatesAutoresizingMaskIntoConstraints = false
        belowFoldPage.backgroundColor = .clear
        contentView.addSubview(belowFoldPage)

        // Fixed top overlay (screen top), NOT in the scrolling content — it
        // crossfades in as you enter the details and pins at the top while the
        // episodes/related/cast scroll under it (Apple TV+). Brought to front
        // after the collection is added.
        smallTitleLogo.translatesAutoresizingMaskIntoConstraints = false
        smallTitleLogo.contentMode = .scaleAspectFit
        smallTitleLogo.alpha = 0
        addSubview(smallTitleLogo)

        // Season pills: fixed overlay under the logo, above the episodes (ATV+).
        seasonsHeader.translatesAutoresizingMaskIntoConstraints = false
        seasonsHeader.alpha = 0
        addSubview(seasonsHeader)
        // A show can have more seasons than fit the screen (~8). The scroller is
        // what makes the overflow reachable at all: UIScrollView is a
        // UIFocusItemScrollableContainer, so the engine treats pills outside the
        // visible window as focus candidates and scrolls them in itself.
        seasonPillScroll.translatesAutoresizingMaskIntoConstraints = false
        seasonPillScroll.showsHorizontalScrollIndicator = false
        // We own the focus scroll (same call as the below-fold collection): the
        // engine's own focus-scroll animator only ever does a minimal
        // scroll-to-visible, which leaves the NEXT pill off-window and hands the
        // engine an episode as the best Left/Right candidate. `revealSeasonPill`
        // keeps both neighbours on-window instead.
        seasonPillScroll.isScrollEnabled = false
        seasonsHeader.addSubview(seasonPillScroll)
        seasonPillRow.translatesAutoresizingMaskIntoConstraints = false
        seasonPillRow.axis = .horizontal
        seasonPillRow.spacing = 34
        seasonPillRow.alignment = .center
        seasonPillScroll.addSubview(seasonPillRow)
        let pillContent = seasonPillScroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            seasonPillScroll.topAnchor.constraint(equalTo: seasonsHeader.topAnchor),
            seasonPillScroll.bottomAnchor.constraint(equalTo: seasonsHeader.bottomAnchor),
            seasonPillScroll.leadingAnchor.constraint(equalTo: seasonsHeader.leadingAnchor),
            seasonPillScroll.trailingAnchor.constraint(equalTo: seasonsHeader.trailingAnchor),
            seasonPillScroll.heightAnchor.constraint(equalTo: pillContent.heightAnchor),
            // Full-bleed window (the header spans the screen), so the pills
            // scroll off the real edges like the episode rows do. The content
            // edge is a pad INSIDE the content instead: the first pill rests on
            // the shared content line and the last one ends on it. Keeping it as
            // content — not `contentInset` — leaves the resting offset at 0
            // rather than -inset.
            seasonPillRow.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor, constant: PreviewCarouselGeometry.expandedChromeInset),
            seasonPillRow.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -PreviewCarouselGeometry.expandedChromeInset),
            // Vertical pad keeps the pills' 1.05 focus scale off the clip edge;
            // the header's top constant backs it out.
            seasonPillRow.topAnchor.constraint(equalTo: pillContent.topAnchor, constant: Self.seasonPillFocusPad),
            seasonPillRow.bottomAnchor.constraint(equalTo: pillContent.bottomAnchor, constant: -Self.seasonPillFocusPad),
        ])

        // Season info strip: display-only, under the pills. Hidden until a
        // season is applied; alpha/transform ride the same scroll choreography
        // as the pills.
        seasonInfoStrip.translatesAutoresizingMaskIntoConstraints = false
        seasonInfoStrip.alpha = 0
        seasonInfoStrip.isHidden = true
        addSubview(seasonInfoStrip)
        stripPoster.translatesAutoresizingMaskIntoConstraints = false
        stripPoster.contentMode = .scaleAspectFill
        stripPoster.clipsToBounds = true
        stripPoster.layer.cornerRadius = 10
        stripPoster.layer.cornerCurve = .continuous
        stripPoster.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        seasonInfoStrip.addSubview(stripPoster)
        stripMeta.translatesAutoresizingMaskIntoConstraints = false
        stripMeta.font = .systemFont(ofSize: 26, weight: .semibold)
        stripMeta.textColor = UIColor.white.withAlphaComponent(0.9)
        seasonInfoStrip.addSubview(stripMeta)
        stripSummary.translatesAutoresizingMaskIntoConstraints = false
        stripSummary.font = .systemFont(ofSize: 24)
        stripSummary.textColor = UIColor.white.withAlphaComponent(0.65)
        stripSummary.numberOfLines = 3
        seasonInfoStrip.addSubview(stripSummary)
        NSLayoutConstraint.activate([
            stripPoster.leadingAnchor.constraint(equalTo: seasonInfoStrip.leadingAnchor),
            stripPoster.topAnchor.constraint(equalTo: seasonInfoStrip.topAnchor),
            stripPoster.bottomAnchor.constraint(equalTo: seasonInfoStrip.bottomAnchor),
            stripPoster.widthAnchor.constraint(equalTo: stripPoster.heightAnchor, multiplier: 2.0 / 3.0),
            stripMeta.topAnchor.constraint(equalTo: seasonInfoStrip.topAnchor, constant: 2),
            stripMeta.leadingAnchor.constraint(equalTo: stripPoster.trailingAnchor, constant: 24),
            stripMeta.trailingAnchor.constraint(lessThanOrEqualTo: seasonInfoStrip.trailingAnchor),
            stripSummary.topAnchor.constraint(equalTo: stripMeta.bottomAnchor, constant: 8),
            stripSummary.leadingAnchor.constraint(equalTo: stripMeta.leadingAnchor),
            stripSummary.trailingAnchor.constraint(equalTo: seasonInfoStrip.trailingAnchor),
            stripSummary.bottomAnchor.constraint(lessThanOrEqualTo: seasonInfoStrip.bottomAnchor),
        ])

        episodesClip.translatesAutoresizingMaskIntoConstraints = false
        episodesClip.clipsToBounds = true
        episodesClip.alpha = 0  // cascades in with the chrome via setCurrent()
        belowFoldPage.addSubview(episodesClip)

        episodesRow.translatesAutoresizingMaskIntoConstraints = false
        episodesRow.axis = .horizontal
        episodesRow.spacing = 75
        episodesRow.alignment = .center
        episodesClip.addSubview(episodesRow)

        // Spacer = hero height (screen − shelfPeek). Same constant the carousel
        // cell uses for its chrome bottom inset, so the hero chrome bottom and
        // the below-fold top align by construction.
        spacerHeightConstraint = spacer.heightAnchor.constraint(
            equalTo: heightAnchor,
            constant: -PreviewCarouselGeometry.carouselChromeShelfPeek
        )
        episodesTopConstraint = episodesClip.topAnchor.constraint(
            equalTo: belowFoldPage.topAnchor, constant: Self.peekTopGap
        )
        episodesLeadingConstraint = episodesClip.leadingAnchor.constraint(
            equalTo: belowFoldPage.leadingAnchor, constant: Self.peekLeadingCarousel
        )
        episodesTrailingConstraint = episodesClip.trailingAnchor.constraint(
            equalTo: belowFoldPage.trailingAnchor, constant: -Self.peekTrailingCarousel
        )

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),

            spacer.topAnchor.constraint(equalTo: contentView.topAnchor),
            spacer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            spacer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            spacerHeightConstraint,

            belowFoldPage.topAnchor.constraint(equalTo: spacer.bottomAnchor),
            belowFoldPage.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            belowFoldPage.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            belowFoldPage.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            belowFoldPage.heightAnchor.constraint(equalToConstant: Self.belowFoldHeight),

            // Small title logo: top-centered, slides up with content, crossfades in.
            smallTitleLogo.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            smallTitleLogo.centerXAnchor.constraint(equalTo: centerXAnchor),
            smallTitleLogo.heightAnchor.constraint(equalToConstant: 110),
            smallTitleLogo.widthAnchor.constraint(lessThanOrEqualToConstant: 520),

            // Episode peek: card-height clipped window, top tracks the reserve.
            episodesTopConstraint,
            episodesLeadingConstraint,
            episodesTrailingConstraint,
            episodesClip.heightAnchor.constraint(equalToConstant: 203),

            // Carousel-stable: exactly 4 thumbs, CENTERED in the card (no edge
            // peek). The expanded state (Step 3) widens the clip and shifts the
            // row to reveal the n−1 / n+1 edges.
            episodesRow.centerXAnchor.constraint(equalTo: episodesClip.centerXAnchor),
            episodesRow.topAnchor.constraint(equalTo: episodesClip.topAnchor),
            episodesRow.bottomAnchor.constraint(equalTo: episodesClip.bottomAnchor),

            // Seasons header: in the reserve gap just above the episodes, left-
            // aligned with them. +20pt below the logo (which ends at y150) for a
            // gap between the title logo and the season pills.
            seasonsHeader.topAnchor.constraint(equalTo: topAnchor, constant: 170 - Self.seasonPillFocusPad),
            // The season-pill CAPSULE left edge sits on the shared content edge
            // (same X as the thumbnails / headers / hero metadata). The pill text
            // is naturally indented inside the capsule, matching the ATV+ ref.
            // Edge to edge: the scroller needs a bounded window (without one the
            // row just runs off-screen), and the pills bleed off the real screen
            // edges like the episode rows. Their content edge comes from the
            // row's own leading/trailing pad inside the scroller.
            seasonsHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            seasonsHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            // No fixed height/width — the pill row hugs the header (equality pins
            // below), so the chunky pills define both. They were crushed to 44pt.

            // Season info strip: under the pills, on the shared content edge.
            // Width capped for summary readability. The show-family details
            // landing (BelowFoldCollectionView.showDetailsTopY) is what reserves
            // the vertical room this occupies.
            seasonInfoStrip.topAnchor.constraint(equalTo: seasonsHeader.bottomAnchor, constant: 8),
            seasonInfoStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PreviewCarouselGeometry.expandedChromeInset),
            seasonInfoStrip.widthAnchor.constraint(equalToConstant: 1040),
            seasonInfoStrip.heightAnchor.constraint(equalToConstant: Self.seasonStripHeight),
        ])

        buildPlaceholderSections()

        // The real episode collection is the SINGLE rail (unified): it shows in
        // BOTH carousel-stable (episodes peeking, non-interactive) and expanded
        // (focusable). Alpha is cascade-driven like the chrome. The old grey
        // placeholder peek is retired (kept hidden so the morph code compiles).
        episodesClip.isHidden = true

        // Card-width clip around the rail. The collection inside is pinned to
        // SELF (full-screen), so the episodes keep their screen position; only
        // the clip changes — card width in carousel-stable (edge episodes
        // hidden behind the card border), full-screen on expand (revealed).
        belowFoldClip.translatesAutoresizingMaskIntoConstraints = false
        belowFoldClip.clipsToBounds = true
        addSubview(belowFoldClip)

        belowFoldCollection.translatesAutoresizingMaskIntoConstraints = false
        belowFoldCollection.isHidden = false
        belowFoldCollection.alpha = 0
        belowFoldClip.addSubview(belowFoldCollection)

        let cardInset = PreviewCarouselGeometry.centeredHorizontalInset
        clipLeadingConstraint = belowFoldClip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: cardInset)
        clipTrailingConstraint = belowFoldClip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -cardInset)
        NSLayoutConstraint.activate([
            belowFoldClip.topAnchor.constraint(equalTo: topAnchor),
            belowFoldClip.bottomAnchor.constraint(equalTo: bottomAnchor),
            clipLeadingConstraint,
            clipTrailingConstraint,
            // Collection pinned to SELF (grandparent) → full-screen inside the clip.
            belowFoldCollection.topAnchor.constraint(equalTo: topAnchor),
            belowFoldCollection.leadingAnchor.constraint(equalTo: leadingAnchor),
            // Extend `pull` past the right edge so the -pull expand translation
            // lands the content's right edge exactly at the screen edge.
            belowFoldCollection.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Self.belowFoldExpandPull),
            belowFoldCollection.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        belowFoldCollection.onScroll = { [weak self] off in
            self?.driveScrollProgress(fromCollectionOffset: off)
        }
        belowFoldCollection.onSelectSynopsis = { [weak self] d in self?.onSelectSynopsis?(d) }
        belowFoldCollection.onSelectAdvisory = { [weak self] a in self?.onSelectAdvisory?(a) }

        // Logo + season pills sit ABOVE the collection (content scrolls under).
        bringSubviewToFront(smallTitleLogo)
        bringSubviewToFront(seasonsHeader)
    }

    // MARK: - Below-fold collection (real content, expanded state)

    /// Only drive the hero fade while the user is actually scrolling INSIDE the
    /// below-fold. The collection emits transient scroll events while it's being
    /// revealed/laid out (content inset + offset settling), and those must NOT
    /// fade the chrome — otherwise the metadata flashes out during the expand.
    private var belowFoldScrollActive = false

    /// Enable/disable the below-fold → hero-fade coupling. The VC enables it on
    /// Down (entering the below-fold) and disables it on return/collapse,
    /// snapping the hero back to full.
    func setBelowFoldScrollActive(_ active: Bool) {
        belowFoldScrollActive = active
        if !active { applyHeroProgress(fromOffset: 0) }
    }

    /// Drive the hero choreography from the collection's scroll offset. The
    /// collection owns its own scrolling, so unlike `apply()` this does NOT
    /// translate the content or grow the reserve — it only fans the progress
    /// out to the hero fades (blur + chrome via `onScrollProgress`, small logo,
    /// seasons header).
    func driveScrollProgress(fromCollectionOffset off: CGFloat) {
        guard belowFoldScrollActive else { return }
        applyHeroProgress(fromOffset: off)
    }

    private func applyHeroProgress(fromOffset off: CGFloat) {
        scrollOffset = off
        smallTitleLogo.alpha = belowFoldTitleOpacity
        seasonsHeader.alpha = scrollProgress
        seasonInfoStrip.alpha = scrollProgress
        // The title logo + season pills + info strip are overlays, but should
        // scroll WITH the rail rather than float in place: translate them by the
        // rail's offset past the details-rest position, so they ride up and out
        // as the user scrolls into the lower rows (and follow the episodes down
        // on entry/collapse). This runs synchronously inside the scroll
        // animation, so it animates in sync with the rail.
        let dy = belowFoldCollection.detailsRestOff - off
        let scroll = CGAffineTransform(translationX: 0, y: dy)
        seasonsHeader.transform = scroll
        seasonInfoStrip.transform = scroll
        smallTitleLogo.transform = scroll
        onScrollProgress?(scrollProgress)
    }

    /// Reveal the real below-fold for the current item, cross-fading from the
    /// placeholder peek. Called from the expand-morph completion (post-morph,
    /// so it never rides the morph clock — §6).
    /// On expand completion: keep the rail visible + load cast/related (episodes
    /// were loaded in carousel-stable). It stays NON-interactive in expanded-hero
    /// so Down from the action row bubbles to the VC's pressesBegan
    /// (→ enterBelowFold); interactivity is enabled in setBelowFoldInteractive
    /// once the user actually enters. No cross-fade — it's the same rail.
    func revealBelowFoldCollection() {
        guard let item else { return }
        setBelowFoldScrollActive(false)
        belowFoldCollection.alpha = 1
        // Installed BEFORE configure, which is what fires it: the loader's own
        // season fetch now feeds the pills and the info strip, where
        // populateSeasonPills used to run a second /children of its own.
        belowFoldCollection.onSeasonsLoaded = { [weak self] seasons, selectedIndex in
            self?.applySeasons(seasons, selectedIndex: selectedIndex)
        }
        // The watch-state refresh reconfigures episode cells only; the strip's
        // counts come from the seasons fetch, which it does not re-run. Take the
        // recomputed counts off the refreshed episodes instead.
        belowFoldCollection.onSeasonProgressRefreshed = { [weak self] progress in
            guard let self, !progress.isEmpty else { return }
            self.seasonProgressOverrides.merge(progress) { _, new in new }
            self.refreshSeasonStripMeta()
        }
        belowFoldCollection.configure(item: item, detail: nil)
        // Entering details starts on the episodes; the selected pill tracks the
        // focused episode's season (set when an episode takes focus).
        detailsFocusTarget = .episodes
        focusIsOnPills = false
        belowFoldCollection.onEpisodeFocused = { [weak self] episode in
            // Only a real episode taking focus flips us off the pills — focus
            // *leaving* the collection (nil) must not clobber a pill that just
            // took focus in the same update (didUpdateFocus order isn't defined).
            guard let self, let episode else { return }
            self.focusIsOnPills = false
            self.detailsFocusTarget = .episodes
            self.selectSeasonPill(forEpisode: episode)
        }
    }

    /// Toggle the below-fold's focusability. Off in expanded-hero (Down from the
    /// action row bubbles to the VC); on once the user enters the details.
    func setBelowFoldInteractive(_ active: Bool) {
        isUserInteractionEnabled = active
    }

    /// On collapse: make the rail non-interactive again + reset its scroll to
    /// the peek rest. It stays visible (carousel-stable peek).
    func hideBelowFoldCollection() {
        setBelowFoldScrollActive(false)
        belowFoldCollection.resetScroll()
        isUserInteractionEnabled = false
    }

    /// Focus environment for the below-fold — only when expanded (interactive);
    /// in carousel-stable the rail is non-focusable so paging stays on the
    /// carousel anchor.
    var belowFoldFocusEnvironment: UIFocusEnvironment? {
        guard isUserInteractionEnabled else { return nil }
        if detailsFocusTarget == .pills, let pill = seasonPillsFocusEnvironment { return pill }
        return belowFoldCollection
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        maxScrollOffset = max(0, contentView.bounds.height - bounds.height)
    }

    // MARK: - Expand inset (driven by the VC during the morph — Step 3)

    /// Morph the episode peek between carousel and expanded. Carousel: clip =
    /// card width, the 6-thumb row centered so only the middle 4 show. Expand:
    /// clip widens to full-bleed (the outer thumbs' edges peek in as n-1/n+1)
    /// and the thumbs elongate slightly. The morph controller calls this inside
    /// its animator + layoutIfNeeded so it rides the one clock.
    func setExpanded(_ expanded: Bool) {
        // The episode rail tracks the metadata pull on expand: shift left so its
        // leading (128 = card 88 + chrome inset 40) lines up with the expanded
        // metadata (expandedChromeInset). Rides the morph animator (the morph
        // controller calls this inside its UIViewPropertyAnimator), so it's a
        // smooth coordinated pull — not a jump.
        belowFoldCollection.transform = expanded
            ? CGAffineTransform(translationX: -Self.belowFoldExpandPull, y: 0)
            : .identity

        // Widen the card-width clip to full-screen, revealing the edge episodes.
        // The morph controller calls this inside its animator + layoutIfNeeded,
        // so the clip change animates on the single morph clock.
        let cardInset = PreviewCarouselGeometry.centeredHorizontalInset
        clipLeadingConstraint.constant = expanded ? 0 : cardInset
        clipTrailingConstraint.constant = expanded ? 0 : -cardInset
    }

    // MARK: - Choreography

    func setScrollOffset(_ offset: CGFloat) {
        scrollOffset = max(0, min(offset, maxScrollOffset == 0 ? offset : maxScrollOffset))
        apply()
    }

    /// Reset the scroll to the rest (peek) state. Keeps the surface visible and
    /// the episode-peek cascade alpha intact — only the scroll is zeroed.
    func reset() {
        scrollLink?.invalidate()
        scrollLink = nil
        scrollAnim = nil
        scrollOffset = 0
        apply()
    }

    private func apply() {
        contentView.transform = CGAffineTransform(translationX: 0, y: -scrollOffset)
        episodesTopConstraint.constant = Self.peekTopGap + Self.reserveDistance * scrollProgress
        layoutIfNeeded()  // keep the reserve push locked to the translation (§6)
        smallTitleLogo.alpha = belowFoldTitleOpacity
        seasonsHeader.alpha = scrollProgress
        seasonInfoStrip.alpha = scrollProgress
        onScrollProgress?(scrollProgress)
    }

    // MARK: - Episode-peek cascade (chrome-synced; page changes, not scroll)

    /// Cascade the episode peek in/out to match the centered card. The VC calls
    /// this alongside the cell chrome cascade: `true` on page-settle (cascade
    /// in), `false` on page-start (snap out). Mirrors the chrome's 0.21s/0.48s
    /// timing so the episodes "load in with the metadata".
    func setCurrent(_ current: Bool, animated: Bool) {
        cascadeToken &+= 1
        let token = cascadeToken
        belowFoldCollection.layer.removeAllAnimations()

        if !current {
            belowFoldCollection.alpha = 0
            return
        }
        if !animated {
            belowFoldCollection.alpha = 1
            return
        }
        belowFoldCollection.alpha = 0
        UIView.animate(withDuration: 0.48, delay: 0.21, options: [.curveEaseOut, .allowUserInteraction]) { [weak self] in
            guard let self, self.cascadeToken == token else { return }
            self.belowFoldCollection.alpha = 1
        }
    }

    // MARK: - Scroll animation (CADisplayLink — same mechanism as horizontal paging)

    private var scrollLink: CADisplayLink?
    private struct ScrollAnim {
        let start: CGFloat
        let end: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let completion: () -> Void
    }
    private var scrollAnim: ScrollAnim?

    func animateScroll(to target: CGFloat, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let clampedTarget = max(0, maxScrollOffset > 0 ? min(target, maxScrollOffset) : target)
        scrollLink?.invalidate()
        scrollAnim = ScrollAnim(
            start: scrollOffset, end: clampedTarget,
            startTime: CACurrentMediaTime(), duration: duration, completion: completion
        )
        let link = CADisplayLink(target: self, selector: #selector(tickScroll))
        link.add(to: .main, forMode: .common)
        scrollLink = link
    }

    @objc private func tickScroll(_ link: CADisplayLink) {
        guard let anim = scrollAnim else {
            link.invalidate(); scrollLink = nil; return
        }
        let elapsed = CACurrentMediaTime() - anim.startTime
        let t = min(1, max(0, elapsed / anim.duration))
        let eased = t * t * (3 - 2 * t)  // smoothstep
        setScrollOffset(anim.start + (anim.end - anim.start) * eased)
        if t >= 1 {
            link.invalidate(); scrollLink = nil
            let done = anim.completion
            scrollAnim = nil
            done()
        }
    }

    // MARK: - Item

    /// Refresh the episode rail's watch state in place (issue #228). Repaints
    /// the existing cards rather than re-running `applyItem`, whose full
    /// snapshot rebuild would knock focus out of the rail.
    func refreshWatchState() {
        belowFoldCollection.refreshWatchState()
    }

    /// Swap in a re-fetched copy of the SAME item (new watch state, same ref)
    /// without re-running the episode load. `item`'s `didSet` would otherwise
    /// rebuild the rail from scratch; here only the stored value moves so the
    /// host can hand the fresh item back out (`onSelectSynopsis`, etc.).
    func updateItemInPlace(_ refreshed: MediaItem) {
        guard let current = item, current.ref == refreshed.ref else { return }
        isSwappingItemInPlace = true
        item = refreshed
        isSwappingItemInPlace = false
    }

    private func applyItem() {
        // Load the centered item's episodes into the single rail (episodes-only
        // in carousel-stable; cast/related are added on expand).
        if let item { belowFoldCollection.configureEpisodesOnly(item: item) }
        // The previous item's pills and strip describe a different show; they
        // rebuild from the loader's seasons on reveal (onSeasonsLoaded). The
        // episodes-only peek load does not fetch seasons, so nothing refills
        // them before then.
        applySeasons([], selectedIndex: 0)

        logoLoadToken &+= 1
        let token = logoLoadToken
        smallTitleLogo.image = nil

        guard let item, let logoURL = item.artwork.logo else { return }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: logoURL)
            await MainActor.run {
                guard let self, self.logoLoadToken == token, let image else { return }
                self.smallTitleLogo.image = image
            }
        }
    }

    // MARK: - Peek episode thumbnails

    /// Fetch the show's episodes for the current item and populate the peek
    /// thumbnails. Only shows/episodes have an episode strip; movies clear it.
    /// Token-guarded so a fast pager discards stale loads.
    private func loadPeekEpisodes(for item: MediaItem) {
        let showRef: MediaItemRef?
        switch item.kind {
        case .show: showRef = item.ref
        case .episode: showRef = item.grandparentRef
        default: showRef = nil
        }
        peekEpisodesToken &+= 1
        let token = peekEpisodesToken
        guard let showRef,
              let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            clearPeekThumbs()
            return
        }
        Task { [weak self] in
            let eps = (try? await provider.allEpisodes(of: showRef)) ?? []
            await MainActor.run {
                guard let self, self.peekEpisodesToken == token else { return }
                self.populatePeekThumbs(eps, token: token)
            }
        }
    }

    private func populatePeekThumbs(_ episodes: [MediaItem], token: UInt64) {
        // Thumb 0 is the hidden-left edge (before the first episode); thumbs
        // 1...5 are the first episodes, so the visible centered 4 (thumbs 1–4)
        // are the show's first four.
        for (i, thumb) in peekThumbImageViews.enumerated() {
            let epIndex = i - 1
            if epIndex >= 0, epIndex < episodes.count,
               let url = episodes[epIndex].artwork.thumbnail ?? episodes[epIndex].artwork.poster {
                Task { [weak self, weak thumb] in
                    let image = await ImageCacheManager.shared.image(for: url)
                    await MainActor.run {
                        guard let self, self.peekEpisodesToken == token, let thumb else { return }
                        thumb.image = image
                    }
                }
            } else {
                thumb.image = nil
            }
        }
    }

    private func clearPeekThumbs() {
        peekEpisodesToken &+= 1
        peekThumbImageViews.forEach { $0.image = nil }
    }

    // MARK: - Placeholder sections (TV route, inert)

    private func buildPlaceholderSections() {
        // Episode peek: 6 16:9 thumbs, NO title. The row is centered in the
        // card-width clip; with gap 75 only the MIDDLE 4 (thumbs 2–5) fall
        // inside the clip — thumbs 1 and 6 sit fully outside. So carousel shows
        // 4 centered (first visible thumb at screen-x ~128, the metadata aligns
        // there). On expand the clip widens to full-bleed and thumbs 1/6 peek
        // in as n-1/n+1.
        episodesRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        thumbWidthConstraints.removeAll()
        peekThumbImageViews.removeAll()
        for _ in 0..<6 {
            let thumb = UIImageView()
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            thumb.contentMode = .scaleAspectFill
            thumb.clipsToBounds = true
            thumb.layer.cornerRadius = 12
            thumb.layer.cornerCurve = .continuous
            thumb.layer.borderWidth = 1
            thumb.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
            let widthConstraint = thumb.widthAnchor.constraint(equalToConstant: Self.thumbWidthCarousel)
            thumbWidthConstraints.append(widthConstraint)
            NSLayoutConstraint.activate([
                widthConstraint,
                thumb.heightAnchor.constraint(equalToConstant: 203),
            ])
            episodesRow.addArrangedSubview(thumb)
            peekThumbImageViews.append(thumb)
        }

        // Seasons pill bar (the scrolled-in header). Pills, no title.
    }

    // MARK: - Season pills

    /// Fetch the show's seasons and populate the pill row (real labels, the
    /// current season highlighted). Empty/single-season shows show no pills.
    /// Arm/disarm the below-fold so a Down-from-pills focus update lands on the
    /// SELECTED season's first episode (not the remembered episode / season 1).
    /// Armed only across the synchronous focus update the VC performs on Down.
    func armPillEntryFocus() { belowFoldCollection.pillEntryArmed = true }
    func disarmPillEntryFocus() { belowFoldCollection.pillEntryArmed = false }

    /// Apply the loader's seasons to the pills AND the info strip.
    ///
    /// Called from `onSeasonsLoaded`, which fires as soon as the below-fold
    /// loader has the seasons — it already resolved which one to open on, so
    /// there is nothing to re-derive here and no second `/children` fetch.
    func applySeasons(_ seasons: [MediaItem], selectedIndex: Int) {
        seasonItems = seasons
        // A fresh seasons fetch carries current counts, so the post-playback
        // overrides have nothing left to correct. Also stops a previous item's
        // counts surviving the reset `applySeasons([], …)` on a carousel move.
        seasonProgressOverrides = [:]
        setSeasonPills(seasons.map { SeasonPillView.seasonLabel(for: $0) },
                       seasonRefIDs: seasons.map { $0.ref.itemID },
                       selectedIndex: selectedIndex)
        // The strip shows for ANY season count — a single-season show still gets
        // its summary and progress even though the pills (a chooser) stay hidden.
        updateSeasonStrip(seasons.isEmpty ? nil : min(max(0, selectedIndex), seasons.count - 1))
    }

    /// "Season 3 · 10 episodes · 4 watched". The counts prefer a post-playback
    /// refresh over the seasons fetch's own snapshot: that fetch only re-runs on
    /// a full `configure`, so after finishing an episode it still reports the
    /// pre-playback count (see `seasonProgressOverrides`).
    private func seasonMetaText(for season: MediaItem) -> String {
        var meta = SeasonPillView.seasonLabel(for: season)
        let progress = seasonProgressOverrides[season.ref.itemID] ?? season.childProgress
        if let progress, progress.total > 0 {
            meta += " · \(progress.total) episode\(progress.total == 1 ? "" : "s")"
            if progress.played >= progress.total {
                meta += " · all watched"
            } else if progress.played > 0 {
                meta += " · \(progress.played) watched"
            }
        }
        return meta
    }

    /// Re-render the counts for the season the strip is ALREADY showing. Separate
    /// from `updateSeasonStrip` on purpose: that one is keyed on a season change
    /// and would either no-op here or restart the poster load and flicker.
    private func refreshSeasonStripMeta() {
        guard let id = stripSeasonID,
              let season = seasonItems.first(where: { $0.ref.itemID == id }) else { return }
        stripMeta.text = seasonMetaText(for: season)
    }

    /// Fill the info strip from a season (nil hides it). Display-only; the poster
    /// load is token-guarded like the logo's.
    private func updateSeasonStrip(_ index: Int?) {
        guard let index, index >= 0, index < seasonItems.count else {
            stripSeasonID = nil
            seasonInfoStrip.isHidden = true
            return
        }
        let season = seasonItems[index]
        // Same-season calls no-op: `selectSeasonPill` fires on every episode
        // focus move as the rail tracks seasons, and restarting the poster load
        // on each one would flicker the strip.
        guard stripSeasonID != season.ref.itemID else { return }
        stripSeasonID = season.ref.itemID
        seasonInfoStrip.isHidden = false
        stripMeta.text = seasonMetaText(for: season)
        stripSummary.text = season.overview
        stripPosterToken &+= 1
        let token = stripPosterToken
        stripPoster.image = nil
        guard let url = season.artwork.thumbnail ?? season.artwork.poster else { return }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run {
                guard let self, self.stripPosterToken == token, let image else { return }
                self.stripPoster.image = image
            }
        }
    }

    /// Internal (not private) so the layout test can drive the row without a
    /// provider round-trip — the overflow behaviour is pure Auto Layout.
    func setSeasonPills(_ labels: [String], seasonRefIDs refIDs: [String], selectedIndex: Int) {
        seasonPillRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        seasonPills.removeAll()
        seasonRefIDs = refIDs
        // Only show pills when there's a real choice (2+ seasons).
        guard labels.count > 1 else { return }
        selectedSeasonIndex = min(selectedIndex, labels.count - 1)
        for (i, label) in labels.enumerated() {
            let pill = SeasonPillView()
            pill.configure(label: label, isSelected: i == selectedSeasonIndex)
            // ATV+ switches the season on FOCUS (move), not on press: as the user
            // moves Left/Right across the pills, the episode rail live-scrolls to
            // each season. The focused pill becomes the selected/current season.
            pill.onFocused = { [weak self] in
                guard let self else { return }
                self.focusIsOnPills = true
                // Keep the pill the PREFERRED focus while the user navigates the
                // row (Left/Right), so focus holds on the pills and doesn't get
                // pulled back into the episode collection.
                self.detailsFocusTarget = .pills
                // Every pill focus scrolls the row, season change or not — the
                // next press needs its neighbour already on-window.
                self.revealSeasonPill(i, animated: true)
                // Only a CHANGE of season scrolls the rail. Returning UP to the
                // pill of the season the episodes are ALREADY showing must not yank
                // the rail back to that season's first episode — leave the user
                // where they were. (selectedSeasonIndex tracks the focused episode.)
                guard i != self.selectedSeasonIndex else { return }
                self.selectSeasonPill(i)   // highlight + current season follow focus
                if i < self.seasonRefIDs.count {
                    self.belowFoldCollection.scrollEpisodesToSeason(seasonRefID: self.seasonRefIDs[i])
                }
            }
            // SELECT (press) opens that season's own page: full summary, only its
            // episodes, its extras. Focus already switched the rail's season, so
            // the press was spare. Unwired, it falls back to re-affirming the
            // season in the rail. Entering the episodes is still done with Down.
            pill.onSelected = { [weak self] in
                guard let self else { return }
                if let onOpenSeason = self.onOpenSeason, i < self.seasonItems.count {
                    onOpenSeason(self.seasonItems[i])
                    return
                }
                guard i < self.seasonRefIDs.count else { return }
                self.belowFoldCollection.scrollEpisodesToSeason(seasonRefID: self.seasonRefIDs[i])
            }
            seasonPillRow.addArrangedSubview(pill)
            seasonPills.append(pill)
        }
        applyPillFocusability()   // match the current target (.episodes at build → non-focusable)
        // Open on the current season even when it's past the visible window.
        revealSeasonPill(selectedSeasonIndex, animated: false)
    }

    /// Mark a season pill selected (others deselected). Called when a pill takes
    /// focus, or when the focused episode crosses into a new season.
    func selectSeasonPill(_ index: Int) {
        guard index >= 0, index < seasonPills.count else { return }
        selectedSeasonIndex = index
        for (i, pill) in seasonPills.enumerated() { pill.setSelected(i == index) }
        // The strip follows the selected season, so it is refreshed from the one
        // place that owns selection — whether that came from a pill taking focus
        // or from the rail crossing a season boundary. Keeping it here is what
        // lets the pill's own same-season early return stay as it is: the strip
        // and `selectedSeasonIndex` can only move together.
        updateSeasonStrip(index)
        // While focus is in the row the engine scrolls the pill in itself; don't
        // run a second scroll against it. This covers the other direction — the
        // pill following the focused episode's season.
        if !focusIsOnPills { revealSeasonPill(index, animated: true) }
    }

    /// Scroll a pill into the scroller's window, WITH both neighbours.
    ///
    /// Revealing only the focused pill is not enough: the focus engine picks the
    /// next Left/Right target from what is on-window, so a neighbour sitting
    /// outside the scroller leaves an episode below as the best candidate and a
    /// sideways press drops out of the row (#261). Keeping n±1 on-window means
    /// the engine never has to look outside the pills.
    private func revealSeasonPill(_ index: Int, animated: Bool) {
        guard index >= 0, index < seasonPills.count else { return }
        layoutIfNeeded()
        let lo = max(0, index - 1)
        let hi = min(seasonPills.count - 1, index + 1)
        // Ask for the content margin alongside the pills, so a landing at either
        // end of the row leaves the same `rowLeading` gutter the shelf rows rest
        // on instead of putting the pill flush against the screen edge (where
        // its 1.05 focus scale gets shaved).
        let rect = seasonPillScroll.convert(
            seasonPills[lo].frame.union(seasonPills[hi].frame), from: seasonPillRow
        ).insetBy(dx: -PreviewCarouselGeometry.expandedChromeInset, dy: 0)
        let window = seasonPillScroll.bounds.width
        var x = seasonPillScroll.contentOffset.x
        if rect.minX < x {
            x = rect.minX
        } else if rect.maxX > x + window {
            x = rect.maxX - window
        }
        let limit = max(0, seasonPillScroll.contentSize.width - window)
        seasonPillScroll.setContentOffset(CGPoint(x: min(max(0, x), limit), y: 0), animated: animated)
    }

    /// A Left/Right press on the pills must never leave the row. The engine
    /// resolves a sideways move against whatever is on-window, and at the ends of
    /// the row that can be an episode below — the "focus jumps down even though I
    /// pressed left" report on #261. `revealSeasonPill` keeps a real pill in
    /// range; this refuses the fallback outright.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if focusIsOnPills,
           context.focusHeading == .left || context.focusHeading == .right,
           !(context.nextFocusedView is SeasonPillView) {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    /// Select the pill for a focused episode's parent season (episode-scroll
    /// tracking). Matches by the episode's parentRef (season) itemID because
    /// seasonNumber is unreliable.
    private func selectSeasonPill(forEpisode episode: MediaItem) {
        guard let parentID = episode.parentRef?.itemID,
              let idx = seasonRefIDs.firstIndex(of: parentID) else { return }
        selectSeasonPill(idx)
    }

    /// Focus environment for the season pills (the selected pill), or nil when
    /// there are no pills. Used to route Up-from-episodes focus to the pills.
    var seasonPillsFocusEnvironment: UIFocusEnvironment? {
        guard selectedSeasonIndex < seasonPills.count else { return seasonPills.first }
        return seasonPills[selectedSeasonIndex]
    }
}
