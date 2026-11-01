// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The carousel's below-fold detail, above the hero chrome. In the carousel it shows the
//  centred card's episode peek, cascading with the chrome; Down scrolls it up over the hero.
//  The VC owns the blur and chrome fade, driven from `onScrollProgress`.

import UIKit

final class ExpandedDetailContainerView: UIView {

    // MARK: - Choreography clock

    private(set) var scrollOffset: CGFloat = 0

    /// Distance over which the hero fades complete: most of the ~800 pt episode slide.
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
    private static let peekTopGap: CGFloat = 75
    /// Vertical slack inside the season-pill scroller so a focused pill's 1.05
    /// scale isn't clipped by the scroller's bounds.
    private static let seasonPillFocusPad: CGFloat = 8
    /// Small title logo box and the pills below it (measured on device, tvOS 27): the pills sit 64 under the logo.
    private static let smallLogoTop: CGFloat = 45
    private static let smallLogoHeight: CGFloat = 100
    static let seasonPillTop: CGFloat = smallLogoTop + smallLogoHeight + 64
    private static let peekLeadingCarousel = PreviewCarouselGeometry.centeredHorizontalInset
    private static let peekTrailingCarousel = PreviewCarouselGeometry.centeredHorizontalInset
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

    /// The full season items behind the pills, so a pill's Select can open
    /// that season's own page.
    private var seasonItems: [MediaItem] = []

    /// Which row of the details has focus. The VC sets this before requesting a
    /// focus update so `belowFoldFocusEnvironment` routes to the right place.
    enum DetailsFocusTarget { case episodes, pills }
    var detailsFocusTarget: DetailsFocusTarget = .episodes {
        didSet { applyPillFocusability() }
    }

    /// Pills are focusable only while targeted, so Up from the episodes cannot land on
    /// the wrong pill; the Up handler targets them and focuses the selected one.
    private func applyPillFocusability() {
        let on = detailsFocusTarget == .pills
        for pill in seasonPills where pill.focusEnabled != on { pill.focusEnabled = on }
    }
    /// True while a season pill (not an episode) holds focus. Drives the VC's
    /// Up/Down handling (Up from a pill collapses; Down from a pill → episodes).
    private(set) var focusIsOnPills = false
    var hasSeasonPills: Bool { !seasonPills.isEmpty }

    /// True while focus is on the top (episodes) row, the only row Up lifts to the pills from.
    var focusIsOnEpisodes: Bool { belowFoldCollection.focusIsOnEpisodes }

    /// Re-arm focus inside a shelf-host row (Related) after a modal. No-op
    /// unless focus was in such a row when the modal went up.
    func restoreShelfRowFocusIfNeeded(requestingFocus: Bool = true) {
        belowFoldCollection.restoreShelfRowFocusIfNeeded(requestingFocus: requestingFocus)
    }

    /// Release the one-shot shelf-restore target after the focus update, so it
    /// can't hijack a later focus resolution.
    func clearArmedShelfRestore() {
        belowFoldCollection.clearArmedShelfRestore()
    }

    /// True briefly after the episode thumb took focus, so the Up that landed there does not lift further.
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
    var onEpisodeMenu: ((MediaItem, CGRect) -> Void)? {
        get { belowFoldCollection.onEpisodeMenu }
        set { belowFoldCollection.onEpisodeMenu = newValue }
    }
    var onSelectPerson: ((MediaPerson) -> Void)? {
        get { belowFoldCollection.onSelectPerson }
        set { belowFoldCollection.onSelectPerson = newValue }
    }
    /// Season pill Select → open that season's own detail page. Unwired, the pill
    /// falls back to re-affirming the season in the rail.
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

    /// On expand the below-fold shifts left by this so the rail meets the expanded metadata;
    /// the collection is this much wider on the right so content still reaches the edge.
    private static var belowFoldExpandPull: CGFloat {
        BelowFoldCollectionView.rowLeading - PreviewCarouselGeometry.expandedChromeInset
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

        // A fixed overlay at the screen top that the rows scroll under, as Apple's does.
        smallTitleLogo.translatesAutoresizingMaskIntoConstraints = false
        smallTitleLogo.contentMode = .scaleAspectFit
        smallTitleLogo.alpha = 0
        addSubview(smallTitleLogo)

        // Season pills: fixed overlay under the logo, above the episodes (ATV+).
        seasonsHeader.translatesAutoresizingMaskIntoConstraints = false
        seasonsHeader.alpha = 0
        addSubview(seasonsHeader)
        // A scroll view makes pills past the screen edge (~8 fit) focus candidates.
        seasonPillScroll.translatesAutoresizingMaskIntoConstraints = false
        seasonPillScroll.showsHorizontalScrollIndicator = false
        // `revealSeasonPill` scrolls instead: the engine's minimal scroll leaves the next pill off-window.
        seasonPillScroll.isScrollEnabled = false
        seasonsHeader.addSubview(seasonPillScroll)
        seasonPillRow.translatesAutoresizingMaskIntoConstraints = false
        seasonPillRow.axis = .horizontal
        seasonPillRow.spacing = 8
        seasonPillRow.alignment = .center
        seasonPillScroll.addSubview(seasonPillRow)
        let pillContent = seasonPillScroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            seasonPillScroll.topAnchor.constraint(equalTo: seasonsHeader.topAnchor),
            seasonPillScroll.bottomAnchor.constraint(equalTo: seasonsHeader.bottomAnchor),
            seasonPillScroll.leadingAnchor.constraint(equalTo: seasonsHeader.leadingAnchor),
            seasonPillScroll.trailingAnchor.constraint(equalTo: seasonsHeader.trailingAnchor),
            seasonPillScroll.heightAnchor.constraint(equalTo: pillContent.heightAnchor),
            // The margin is padding inside the content, not `contentInset`, so the resting offset stays 0.
            seasonPillRow.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor, constant: PreviewCarouselGeometry.expandedChromeInset),
            seasonPillRow.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -PreviewCarouselGeometry.expandedChromeInset),
            // Vertical pad keeps the pills' 1.05 focus scale off the clip edge;
            // the header's top constant backs it out.
            seasonPillRow.topAnchor.constraint(equalTo: pillContent.topAnchor, constant: Self.seasonPillFocusPad),
            seasonPillRow.bottomAnchor.constraint(equalTo: pillContent.bottomAnchor, constant: -Self.seasonPillFocusPad),
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
            smallTitleLogo.topAnchor.constraint(equalTo: topAnchor, constant: Self.smallLogoTop),
            smallTitleLogo.centerXAnchor.constraint(equalTo: centerXAnchor),
            smallTitleLogo.heightAnchor.constraint(equalToConstant: Self.smallLogoHeight),
            smallTitleLogo.widthAnchor.constraint(lessThanOrEqualToConstant: 546),

            // Episode peek: card-height clipped window, top tracks the reserve.
            episodesTopConstraint,
            episodesLeadingConstraint,
            episodesTrailingConstraint,
            episodesClip.heightAnchor.constraint(equalToConstant: 203),

            // Four thumbs centred in the card; expanding widens the clip to the n−1 / n+1 edges.
            episodesRow.centerXAnchor.constraint(equalTo: episodesClip.centerXAnchor),
            episodesRow.topAnchor.constraint(equalTo: episodesClip.topAnchor),
            episodesRow.bottomAnchor.constraint(equalTo: episodesClip.bottomAnchor),

            // Seasons header: pills 64 below the logo, left-aligned with the episodes.
            seasonsHeader.topAnchor.constraint(equalTo: topAnchor, constant: Self.seasonPillTop - Self.seasonPillFocusPad),
            // Edge to edge, so the pills bleed off the screen like the episode rows.
            seasonsHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            seasonsHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            // No fixed height/width — the pill row hugs the header (equality pins
            // below), so the chunky pills define both. They were crushed to 44pt.
        ])

        buildPlaceholderSections()

        // The collection is the one rail in both states; this placeholder stays hidden.
        episodesClip.isHidden = true

        // Card width in the carousel, full screen on expand; the rail inside never moves.
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

    /// Gates the hero fade, so the collection's settling scrolls during reveal do not flash the metadata out.
    private var belowFoldScrollActive = false

    /// Enable/disable the below-fold → hero-fade coupling. The VC enables it on
    /// Down (entering the below-fold) and disables it on return/collapse,
    /// snapping the hero back to full.
    func setBelowFoldScrollActive(_ active: Bool) {
        belowFoldScrollActive = active
        if !active { applyHeroProgress(fromOffset: 0) }
    }

    /// Fans the collection's scroll progress out to the hero fades; unlike `apply()` it moves no content.
    func driveScrollProgress(fromCollectionOffset off: CGFloat) {
        guard belowFoldScrollActive else { return }
        applyHeroProgress(fromOffset: off)
    }

    private func applyHeroProgress(fromOffset off: CGFloat) {
        scrollOffset = off
        smallTitleLogo.alpha = belowFoldTitleOpacity
        seasonsHeader.alpha = scrollProgress
        // The logo and pills ride the rail's offset past its details rest, inside the scroll animation.
        let dy = belowFoldCollection.detailsRestOff - off
        let scroll = CGAffineTransform(translationX: 0, y: dy)
        seasonsHeader.transform = scroll
        smallTitleLogo.transform = scroll
        onScrollProgress?(scrollProgress)
    }

    /// After the expand morph: loads cast and related. Stays non-interactive so Down
    /// from the action row reaches the VC; `setBelowFoldInteractive` enables it on entry.
    func revealBelowFoldCollection() {
        guard let item else { return }
        setBelowFoldScrollActive(false)
        belowFoldCollection.onEpisodesApplied = nil
        belowFoldCollection.alpha = 1
        // Before configure, which fires it: the loader's season fetch feeds the pills.
        belowFoldCollection.onSeasonsLoaded = { [weak self] seasons, selectedIndex in
            self?.applySeasons(seasons, selectedIndex: selectedIndex)
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

    // MARK: - Expand inset (driven by the VC during the morph)

    /// Widens the episode clip from card width to full bleed. Called inside the morph animator.
    func setExpanded(_ expanded: Bool) {
        // Follows the metadata's pull to `expandedChromeInset`.
        belowFoldCollection.transform = expanded
            ? CGAffineTransform(translationX: -Self.belowFoldExpandPull, y: 0) : .identity

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
        onScrollProgress?(scrollProgress)
    }

    // MARK: - Episode-peek cascade (chrome-synced; page changes, not scroll)

    /// Fades the episode peek in with the chrome's 0.5 s cascade, or snaps it out after paging away.
    func setCurrent(_ current: Bool, animated: Bool) {
        cascadeToken &+= 1
        let token = cascadeToken
        belowFoldCollection.layer.removeAllAnimations()
        belowFoldCollection.onEpisodesApplied = nil

        if !current {
            belowFoldCollection.alpha = 0
            return
        }
        if !animated {
            belowFoldCollection.alpha = 1
            return
        }
        belowFoldCollection.alpha = 0
        let fadeIn = { [weak self] in
            guard let self, self.cascadeToken == token else { return }
            UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                self.belowFoldCollection.alpha = 1
            }
        }
        // Episodes still loading: hold at 0 and fade once they are applied, so
        // the rail arrives as one piece instead of fading in empty.
        if belowFoldCollection.isLoadingEpisodes {
            belowFoldCollection.onEpisodesApplied = fadeIn
        } else {
            fadeIn()
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

    /// Stores a re-fetched copy of the same item without the `didSet` rail rebuild.
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
        // Clear the old show's pills; onSeasonsLoaded refills them on reveal.
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
        // Six 16:9 thumbs centred in the card clip, so only the middle four show.
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

    /// Armed across the VC's Down-from-pills focus update, so it lands on the selected season's first episode.
    func armPillEntryFocus() { belowFoldCollection.pillEntryArmed = true }
    func disarmPillEntryFocus() { belowFoldCollection.pillEntryArmed = false }

    /// Applies the loader's seasons, with the one to open on already resolved.
    func applySeasons(_ seasons: [MediaItem], selectedIndex: Int) {
        seasonItems = seasons
        setSeasonPills(seasons.map { SeasonPillView.seasonLabel(for: $0) },
                       seasonRefIDs: seasons.map { $0.ref.itemID },
                       selectedIndex: selectedIndex)
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
                // Only a change of season scrolls the rail; returning to the current one leaves it.
                guard i != self.selectedSeasonIndex else { return }
                self.selectSeasonPill(i)   // highlight + current season follow focus
                if i < self.seasonRefIDs.count {
                    self.belowFoldCollection.scrollEpisodesToSeason(seasonRefID: self.seasonRefIDs[i])
                }
            }
            // Select opens the season's page; unwired, it re-affirms the season in the rail.
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
        // While focus is in the row the engine scrolls the pill in itself; don't
        // run a second scroll against it. This covers the other direction — the
        // pill following the focused episode's season.
        if !focusIsOnPills { revealSeasonPill(index, animated: true) }
    }

    /// Scrolls a pill on-window with both neighbours, or a sideways move can pick an episode below (#261).
    private func revealSeasonPill(_ index: Int, animated: Bool) {
        guard index >= 0, index < seasonPills.count else { return }
        layoutIfNeeded()
        let lo = max(0, index - 1)
        let hi = min(seasonPills.count - 1, index + 1)
        // Include the content margin, so an end pill's 1.05 focus scale is not shaved at the screen edge.
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

    /// Left/Right on the pills never leaves the row; at the row's ends the engine would pick an episode (#261).
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
