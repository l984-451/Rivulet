// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  An episode (or trailer) card: thumbnail with duration, progress and watched overlays
//  over a description block. An episode has two focus stops: the thumb plays, the description opens details.

import UIKit
import TVUIKit

/// Which sub-target of an episode card currently holds focus. Episodes split
/// into two focus stops (thumb = play, description = details); trailers stay
/// single-target (`.thumb` only).
enum EpisodeFocusKind { case none, thumb, description }

/// A TVCardView thumbnail that reports focus. Select comes from EpisodeCell's
/// tap recognizer, which waits out the hold that opens the episode menu; the
/// presses still reach TVCardView for its native press-down motion.
final class EpisodeThumbCardView: TVCardView {
    /// (isFocused, nextFocusedView, coordinator)
    var onFocusChange: ((Bool, UIView?, UIFocusAnimationCoordinator) -> Void)?

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChange?(context.nextFocusedView === self, context.nextFocusedView, coordinator)
    }
}

/// The metadata block as the SECOND episode focus stop. Focusable only when
/// `isFocusEligible` (true for episodes, false for trailers — trailers keep a
/// single thumb stop). Select opens the episode detail page.
final class EpisodeDescriptionView: UIView {
    /// Focusable only while this episode holds focus, so Up from below lands on the thumb.
    var isFocusEligible = false
    var onSelect: (() -> Void)?
    /// (isFocused, context, coordinator)
    var onFocusChange: ((Bool, UIFocusUpdateContext, UIFocusAnimationCoordinator) -> Void)?

    /// Side by side, the description sits beside its thumb and is always a stop.
    var isAlwaysFocusable = false
    override var canBecomeFocused: Bool { isAlwaysFocusable || isFocusEligible }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChange?(context.nextFocusedView === self, context, coordinator)
    }

    // Consume the Select press in BOTH began/ended so the focused block owns the
    // press cycle (mirrors AboutCardControl) — required for reliable delivery.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { onSelect?(); return }
        super.pressesEnded(presses, with: event)
    }
}

final class EpisodeCell: UIView {

    /// `.stacked` puts the description under the thumb (the show page's rail);
    /// `.sideBySide` puts it to the thumb's right (the season page's list).
    enum Layout { case stacked, sideBySide }
    private let layout: Layout

    // MARK: - Focus callbacks (wired by EpisodeCollectionCell)

    /// Thumb Select → play this episode. (Episodes only.)
    var onPlay: (() -> Void)?
    /// Description Select → open the episode detail page. (Episodes only.)
    var onShowDetails: (() -> Void)?
    /// Held Select on the thumb or description, with the thumb's window frame. (Episodes only.)
    var onLongPress: ((CGRect) -> Void)?
    /// Reports which sub-target is focused on every focus change (thumb /
    /// description / none). Drives season-pill tracking and the Up handler's
    /// "description → thumb, thumb → pills" decision.
    var onFocusKindChanged: ((EpisodeFocusKind) -> Void)?

    // Four across on the grid. The cell is the resting artwork's width; the
    // thumbnail card overhangs it by its focus reserve on both sides, so the
    // focus engine lands cell edges, and with them the artwork, on the margin.
    static let cardWidth = MediaRowMetrics.gridWidth(columns: 4)
    /// The card's frame, reserve included: 16:9 artwork (measured on device, tvOS 27).
    static let thumbHeight: CGFloat = (cardWidth * 9 / 16).rounded() + MediaRowMetrics.focusGrowth
    /// A trailer's frame: 410 x 278 artwork with the title inside it.
    static let trailerThumbHeight: CGFloat = 278 + MediaRowMetrics.focusGrowth
    private static let cornerRadius: CGFloat = 16
    /// The Apple TV app's episode artwork radius on tvOS 27 (VideosUI `EpisodeLockupLayout.borderRadii`).
    private static let artworkRadius: CGFloat = 20
    /// The text under a stacked card: four summary lines end about 232 below the artwork, plus Apple's 30 focus drop.
    static let textBlockHeight: CGFloat = 262
    /// Apple's summary line pitch under an episode card.
    private static let summaryLineHeight: CGFloat = 30

    // MARK: - Subviews

    /// TVUIKit card around the thumbnail — gives Apple's native tvOS focus
    /// treatment (parallax tilt + scale + specular EDGE SHEEN), like the
    /// home-screen cards. Image + overlays live in `thumbnailCard.contentView`.
    private let thumbnailCard = EpisodeThumbCardView()
    private let thumbnailImageView = UIImageView()

    private var thumbHeightConstraint: NSLayoutConstraint!
    private let trailerScrim = TrailerScrimView()
    /// The Apple TV app's episode fade: darkening plus a tint from the artwork.
    private let artworkFade = EpisodeArtworkFadeView()
    private let trailerTitleLabel = UILabel()

    /// The Apple TV app's playback status: glyph, an in-progress bar, then the time.
    private let playbackStatus = EpisodePlaybackStatusView()

    /// Subtype icon shown top-trailing on trailer/extra tiles (film, camera, etc.).
    private let subtypeIcon = UIImageView()

    private let descriptionBlock = EpisodeDescriptionView()
    private let descriptionFocusGuide = UIFocusGuide()
    /// Episode mode (two focus stops: thumb + description). False for trailers
    /// (single thumb stop, with the old whole-card frosted-panel focus look).
    private var splitFocus = false
    private var thumbFocused = false
    private var descFocused = false
    /// A stacked card's text top; Apple drops the text 30 while the art is focused, 20 while the text is.
    private var textTop: NSLayoutConstraint?
    private static let textRestOffset: CGFloat = -21
    /// Apple's secondary text, measured on device: 0.53 at rest and on the focused description, 0.6 under focused art.
    private static let secondaryText = UIColor.white.withAlphaComponent(0.53)
    /// Liquid-glass focus highlight behind the metadata (ATV+ uses glass, not a
    /// white outline). Effect is nil until focused.
    private let descriptionGlass = UIVisualEffectView(effect: nil)
    private var glassLeading: NSLayoutConstraint!
    private var glassTrailing: NSLayoutConstraint!
    private let episodeLabel = UILabel()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let footerRow = UIStackView()
    private let dateLabel = UILabel()
    private let ratingBadge = PaddingLabel()

    private var imageToken: UInt64 = 0

    // MARK: - Init

    init(layout: Layout = .stacked) {
        self.layout = layout
        super.init(frame: .zero)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("EpisodeCell is not Storyboard-backed") }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        // No card background, as Apple's; unclipped so the focus scale and metadata box show.
        backgroundColor = .clear
        clipsToBounds = false

        // Image and overlays go in contentView so they ride the card's focus motion.
        thumbnailCard.translatesAutoresizingMaskIntoConstraints = false
        thumbnailCard.contentSize = CGSize(width: Self.cardWidth + MediaRowMetrics.focusGrowth, height: Self.thumbHeight)
        thumbnailCard.contentView.backgroundColor = .clear
        let hold = TileLongPress.makeRecognizer(target: self, action: #selector(handleHold(_:)))
        addGestureRecognizer(hold)
        thumbnailCard.addGestureRecognizer(
            TileLongPress.makeSelectTap(target: self, action: #selector(handleThumbSelect), yieldingTo: hold))
        thumbnailCard.onFocusChange = { [weak self] focused, next, coordinator in
            guard let self else { return }
            self.thumbFocused = focused
            self.applyReachability(next: next)
            let clock: FocusClock = focused ? .artFocusing : .artUnfocusing
            self.updateDescriptionGlass(coordinator, on: clock)
            self.animate(coordinator, on: clock) { self.playbackStatus.showsFocused = focused }
            self.updateTextDrop(coordinator, on: clock)
            self.notifyFocusKind()
        }
        addSubview(thumbnailCard)

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true
        thumbnailImageView.layer.cornerRadius = Self.artworkRadius
        thumbnailImageView.layer.cornerCurve = .continuous
        thumbnailImageView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        thumbnailCard.contentView.addSubview(thumbnailImageView)
        artworkFade.translatesAutoresizingMaskIntoConstraints = false
        thumbnailCard.contentView.addSubview(artworkFade)

        // A trailer's title rides inside the artwork, over a scrim.
        trailerScrim.translatesAutoresizingMaskIntoConstraints = false
        trailerScrim.isHidden = true
        thumbnailCard.contentView.addSubview(trailerScrim)
        trailerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        trailerTitleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        trailerTitleLabel.textColor = .white
        trailerTitleLabel.isHidden = true
        thumbnailCard.contentView.addSubview(trailerTitleLabel)

        playbackStatus.translatesAutoresizingMaskIntoConstraints = false
        playbackStatus.isHidden = true
        thumbnailCard.contentView.addSubview(playbackStatus)

        // Subtype icon (top-leading) — shown on trailer/extra tiles only.
        subtypeIcon.translatesAutoresizingMaskIntoConstraints = false
        subtypeIcon.contentMode = .scaleAspectFit
        subtypeIcon.tintColor = .white
        subtypeIcon.isHidden = true
        thumbnailCard.contentView.addSubview(subtypeIcon)

        // Description block — gets a subtle rounded box only when focused (ATV+).
        descriptionBlock.translatesAutoresizingMaskIntoConstraints = false
        descriptionBlock.layer.cornerRadius = Self.cornerRadius
        descriptionBlock.layer.cornerCurve = .continuous
        descriptionBlock.layer.borderWidth = 0
        descriptionBlock.layer.borderColor = UIColor.clear.cgColor
        descriptionBlock.onSelect = { [weak self] in self?.onShowDetails?() }
        descriptionBlock.isAlwaysFocusable = layout == .sideBySide
        descriptionBlock.onFocusChange = { [weak self] focused, context, coordinator in
            guard let self else { return }
            self.descFocused = focused
            self.applyReachability(next: context.nextFocusedView)
            // A move to or from the art animates from the art's handler, on the art's clock.
            let other = focused ? context.previouslyFocusedView : context.nextFocusedView
            if other !== self.thumbnailCard {
                self.updateDescriptionGlass(coordinator)
                self.updateTextDrop(coordinator)
            }
            self.notifyFocusKind()
        }
        addSubview(descriptionBlock)

        addLayoutGuide(descriptionFocusGuide)
        descriptionFocusGuide.preferredFocusEnvironments = [thumbnailCard]
        descriptionFocusGuide.isEnabled = false
        NSLayoutConstraint.activate([
            descriptionFocusGuide.topAnchor.constraint(equalTo: descriptionBlock.topAnchor),
            descriptionFocusGuide.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor),
            descriptionFocusGuide.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor),
            descriptionFocusGuide.bottomAnchor.constraint(equalTo: descriptionBlock.bottomAnchor),
        ])

        // Glass highlight behind the metadata (added before the labels so it sits
        // behind them). Pinned to fill the description block; rounded + clipped.
        descriptionGlass.translatesAutoresizingMaskIntoConstraints = false
        descriptionGlass.isUserInteractionEnabled = false
        descriptionGlass.clipsToBounds = true
        descriptionGlass.layer.cornerRadius = Self.cornerRadius
        descriptionGlass.layer.cornerCurve = .continuous
        descriptionBlock.addSubview(descriptionGlass)
        glassLeading = descriptionGlass.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor)
        glassTrailing = descriptionGlass.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor)
        NSLayoutConstraint.activate([
            descriptionGlass.topAnchor.constraint(equalTo: descriptionBlock.topAnchor),
            glassLeading,
            glassTrailing,
            descriptionGlass.bottomAnchor.constraint(equalTo: descriptionBlock.bottomAnchor),
        ])

        episodeLabel.translatesAutoresizingMaskIntoConstraints = false
        episodeLabel.font = .systemFont(ofSize: 21, weight: .medium)
        episodeLabel.textColor = Self.secondaryText
        descriptionBlock.addSubview(episodeLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 25, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        descriptionBlock.addSubview(titleLabel)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 23, weight: .medium)
        summaryLabel.textColor = Self.secondaryText
        summaryLabel.numberOfLines = layout == .sideBySide ? 3 : 4
        descriptionBlock.addSubview(summaryLabel)

        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.axis = .horizontal
        footerRow.alignment = .center
        footerRow.spacing = 8
        descriptionBlock.addSubview(footerRow)

        dateLabel.font = .systemFont(ofSize: 23, weight: .medium)
        dateLabel.textColor = Self.secondaryText
        footerRow.addArrangedSubview(dateLabel)

        // Apple's outlined rating box: 67 x 22 for "TV-MA", in the date's gray.
        ratingBadge.font = .systemFont(ofSize: 16, weight: .semibold)
        ratingBadge.textColor = Self.secondaryText
        ratingBadge.insets = UIEdgeInsets(top: 1.5, left: 6, bottom: 1.5, right: 6)
        ratingBadge.layer.cornerRadius = 4
        ratingBadge.layer.cornerCurve = .continuous
        ratingBadge.layer.borderWidth = 1.5
        ratingBadge.layer.borderColor = Self.secondaryText.cgColor
        ratingBadge.clipsToBounds = true
        footerRow.addArrangedSubview(ratingBadge)

        thumbHeightConstraint = thumbnailCard.heightAnchor.constraint(equalToConstant: Self.thumbHeight)

        // Apple's text sits 18 in from the card under an episode, as its artwork padding does.
        let inset: CGFloat = layout == .stacked ? 18 : 20
        // Apple's platter, measured: 23.5 above the EPISODE caps and 20 below the footer at rest.
        let topPad: CGFloat = layout == .stacked ? 18 : 12
        let bottomPad: CGFloat = layout == .stacked ? 18 : 14
        let episodeLeading = episodeLabel.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: inset)
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: inset)
        let summaryLeading = summaryLabel.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: inset)
        let footerLeading = footerRow.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: inset)

        let reserve = MediaRowMetrics.focusGrowth / 2
        if layout == .stacked {
            textTop = descriptionBlock.topAnchor.constraint(equalTo: thumbnailCard.bottomAnchor, constant: Self.textRestOffset)
        }
        switch layout {
        case .stacked:
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: Self.cardWidth),
                thumbnailCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: reserve),
                // The block's edge sits on the thumbnail's leading; its text is padded inside.
                // Apple's EPISODE baseline sits 38 below the resting artwork.
                textTop!,
                descriptionBlock.leadingAnchor.constraint(equalTo: leadingAnchor),
            ])
        case .sideBySide:
            NSLayoutConstraint.activate([
                thumbnailCard.widthAnchor.constraint(equalToConstant: Self.cardWidth + MediaRowMetrics.focusGrowth),
                bottomAnchor.constraint(equalTo: thumbnailCard.bottomAnchor),
                // The box's top meets the resting artwork's top, one grid gap to its right.
                descriptionBlock.topAnchor.constraint(equalTo: thumbnailCard.topAnchor, constant: reserve),
                descriptionBlock.leadingAnchor.constraint(equalTo: thumbnailCard.trailingAnchor,
                                                          constant: MediaRowMetrics.tileGap - reserve),
                descriptionBlock.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            thumbnailCard.topAnchor.constraint(equalTo: topAnchor),
            thumbnailCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -reserve),
            thumbHeightConstraint,

            trailerScrim.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor),
            trailerScrim.trailingAnchor.constraint(equalTo: thumbnailCard.contentView.trailingAnchor),
            trailerScrim.bottomAnchor.constraint(equalTo: thumbnailCard.contentView.bottomAnchor),
            trailerScrim.heightAnchor.constraint(equalToConstant: 120),
            trailerTitleLabel.leadingAnchor.constraint(equalTo: playbackStatus.leadingAnchor),
            trailerTitleLabel.trailingAnchor.constraint(equalTo: thumbnailCard.contentView.trailingAnchor, constant: -16),
            trailerTitleLabel.bottomAnchor.constraint(equalTo: playbackStatus.topAnchor, constant: -2),

            thumbnailImageView.topAnchor.constraint(equalTo: thumbnailCard.contentView.topAnchor),
            thumbnailImageView.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: thumbnailCard.contentView.trailingAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: thumbnailCard.contentView.bottomAnchor),
            artworkFade.topAnchor.constraint(equalTo: thumbnailCard.contentView.topAnchor),
            artworkFade.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor),
            artworkFade.trailingAnchor.constraint(equalTo: thumbnailCard.contentView.trailingAnchor),
            artworkFade.bottomAnchor.constraint(equalTo: thumbnailCard.contentView.bottomAnchor),

            // Apple's padding: 18 from the leading edge, the time's baseline 18 above the bottom.
            playbackStatus.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor, constant: 18),
            playbackStatus.trailingAnchor.constraint(lessThanOrEqualTo: thumbnailCard.contentView.trailingAnchor, constant: -18),
            playbackStatus.lastBaselineAnchor.constraint(equalTo: thumbnailCard.contentView.bottomAnchor, constant: -18),

            // Subtype icon: top-leading corner of the thumbnail.
            subtypeIcon.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor, constant: 10),
            subtypeIcon.topAnchor.constraint(equalTo: thumbnailCard.contentView.topAnchor, constant: 10),
            subtypeIcon.widthAnchor.constraint(equalToConstant: 22),
            subtypeIcon.heightAnchor.constraint(equalToConstant: 22),

            descriptionBlock.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Block HUGS its content (top-aligned): short descriptions sit right
            // under the title instead of vertical-centering in a fixed box.
            episodeLabel.topAnchor.constraint(equalTo: descriptionBlock.topAnchor, constant: topPad),
            episodeLeading,
            episodeLabel.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor, constant: -20),

            titleLabel.topAnchor.constraint(equalTo: episodeLabel.bottomAnchor, constant: 2),
            titleLeading,
            titleLabel.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor, constant: -20),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            summaryLeading,
            summaryLabel.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor, constant: -20),

            footerRow.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 5),
            footerLeading,
            footerRow.trailingAnchor.constraint(lessThanOrEqualTo: descriptionBlock.trailingAnchor, constant: -20),
            descriptionBlock.bottomAnchor.constraint(equalTo: footerRow.bottomAnchor, constant: bottomPad),
        ])
    }

    // MARK: - Configure

    func configure(episode: MediaItem, showSeasonPrefix: Bool = false) {
        // The description starts unfocusable; see applyReachability.
        setTrailerLayout(false)
        subtypeIcon.isHidden = true
        splitFocus = true
        descriptionBlock.isFocusEligible = false
        descriptionFocusGuide.isEnabled = layout == .stacked
        episodeLabel.text = Self.episodeLabel(for: episode, showSeasonPrefix: showSeasonPrefix).uppercased()
        titleLabel.text = episode.title.isEmpty ? String(localized: "Episode") : episode.title
        summaryLabel.attributedText = episode.overview.map(Self.summaryText)
        summaryLabel.isHidden = (episode.overview ?? "").isEmpty
        dateLabel.text = Self.displayDate(for: episode)
        dateLabel.isHidden = dateLabel.text == nil
        ratingBadge.text = episode.contentRating
        ratingBadge.isHidden = (episode.contentRating ?? "").isEmpty

        // A resume point outranks the watched state, as in Plex.
        let progress = episode.watchProgress.flatMap { $0 > 0 && $0 < 1 ? $0 : nil }
        if let progress {
            playbackStatus.state = .inProgress(progress, remaining: episode.remainingFormatted ?? episode.durationFormatted)
        } else if let duration = episode.durationFormatted {
            playbackStatus.state = episode.isWatched ? .watched(duration) : .unwatched(duration)
        } else {
            playbackStatus.state = nil
        }

        loadThumbnail(episode.artwork.thumbnail ?? episode.artwork.poster)
    }

    /// Search's tile: the rail's card as one focus stop, its label naming the season and the
    /// footer the show, since no show page surrounds it. A season shows the show's backdrop.
    func configure(searchResult item: MediaItem) {
        configure(episode: item)
        splitFocus = false
        descriptionFocusGuide.isEnabled = false
        let show = item.seriesTitle
        if item.kind == .season {
            episodeLabel.text = show?.uppercased()
            loadThumbnail(item.parentArtwork?.backdrop ?? item.artwork.backdrop ?? item.artwork.thumbnail
                          ?? item.artwork.poster)
        } else if let season = item.seasonNumber, let episode = item.episodeNumber {
            episodeLabel.text = (season == 0
                ? String(localized: "Specials · Episode \(episode)")
                : String(localized: "Season \(season) · Episode \(episode)")).uppercased()
        }
        let footer = [item.kind == .episode ? show : nil, Self.displayDate(for: item)].compactMap { $0 }
        dateLabel.text = footer.joined(separator: " · ")
        dateLabel.isHidden = footer.isEmpty
    }

    /// Search's row focuses the whole cell, not the thumb, so the cell drives the focused look.
    /// The panel widens with the thumb's focus growth, so the two read as one card.
    func setWholeCardFocused(_ focused: Bool, coordinator: UIFocusAnimationCoordinator) {
        thumbFocused = focused
        updateDescriptionGlass(coordinator)
        coordinator.addCoordinatedAnimations({ self.playbackStatus.showsFocused = focused }, completion: nil)
        updateTextDrop(coordinator)
        let reserve = focused ? MediaRowMetrics.focusGrowth / 2 : 0
        glassLeading.constant = -reserve
        glassTrailing.constant = reserve
        coordinator.addCoordinatedAnimations({ self.descriptionBlock.layoutIfNeeded() }, completion: nil)
    }

    /// The thumbnail's artwork and its focus-free corner radius, for the carousel's entry morph.
    var artworkView: UIView { thumbnailCard.contentView }
    var artworkLoaded: Bool { thumbnailImageView.image != nil }

    private func loadThumbnail(_ url: URL?) {
        imageToken &+= 1
        let token = imageToken
        // A memory hit paints in this pass (no pop after the rail's fade).
        thumbnailImageView.image = url.flatMap { ImageCacheManager.shared.cachedImage(for: $0) }
        artworkFade.setTint(url.flatMap(ArtworkTint.cached(for:)), animated: false)
        if let url, thumbnailImageView.image == nil || artworkFade.tint == nil {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                guard let self, self.imageToken == token, let image else { return }
                self.thumbnailImageView.image = image
                let tint = await ArtworkTint.color(for: url, image: image)
                guard self.imageToken == token else { return }
                self.artworkFade.setTint(tint, animated: true)
            }
        }
    }

    /// The same card with only thumbnail, title and duration, so both rows read as one design.
    func configure(trailer: BelowFoldTrailer) {
        // Trailers keep a single focus stop on the thumb (no description target).
        splitFocus = false
        setTrailerLayout(true)
        descriptionBlock.isFocusEligible = false
        descriptionFocusGuide.isEnabled = false
        episodeLabel.text = nil
        episodeLabel.isHidden = true
        trailerTitleLabel.text = trailer.title
        titleLabel.text = trailer.title
        summaryLabel.text = nil
        summaryLabel.isHidden = true
        dateLabel.isHidden = true
        ratingBadge.isHidden = true

        playbackStatus.state = trailer.durationFormatted.map { .unwatched($0) }

        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        subtypeIcon.image = UIImage(systemName: trailer.subtype.glyphName, withConfiguration: config)
        subtypeIcon.isHidden = false

        imageToken &+= 1
        let token = imageToken
        let url = trailer.artworkURL
        thumbnailImageView.image = url.flatMap { ImageCacheManager.shared.cachedImage(for: $0) }
        if let url, thumbnailImageView.image == nil {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                await MainActor.run {
                    guard let self, self.imageToken == token else { return }
                    self.thumbnailImageView.image = image
                }
            }
        }
    }

    /// A trailer is a taller thumb with its title inside and no description block below.
    private func setTrailerLayout(_ trailer: Bool) {
        let height = trailer ? Self.trailerThumbHeight : Self.thumbHeight
        thumbHeightConstraint.constant = height
        thumbnailCard.contentSize = CGSize(width: Self.cardWidth + MediaRowMetrics.focusGrowth, height: height)
        trailerScrim.isHidden = !trailer
        trailerTitleLabel.isHidden = !trailer
        descriptionBlock.isHidden = trailer
        artworkFade.isHidden = trailer
    }

    // MARK: - Focus visuals

    /// Metadata box: full glass when the description (or a trailer's thumb) is focused,
    /// a faint tint for an episode's focused thumb, clear otherwise.
    private func updateDescriptionGlass(_ coordinator: UIFocusAnimationCoordinator?, on clock: FocusClock = .shared) {
        let apply = { [self] in
            // Apple brightens the text under focused art; a focused description lifts only its date and rating.
            let secondary = thumbFocused ? UIColor.white.withAlphaComponent(0.6) : Self.secondaryText
            let footer = descFocused ? UIColor.white.withAlphaComponent(0.75) : secondary
            [episodeLabel, summaryLabel].forEach { $0.textColor = secondary }
            [dateLabel, ratingBadge].forEach { $0.textColor = footer }
            ratingBadge.layer.borderColor = footer.cgColor
            if layout == .stacked && splitFocus {
                // Measured on Apple's 4K capture: the platter is the card's width and the whole block
                // scales 1.085, so the text stays about 17 from the platter's edge.
                descriptionBlock.transform = descFocused ? CGAffineTransform(scaleX: 1.085, y: 1.085) : .identity
                descriptionBlock.layoutIfNeeded()
            }
            if descFocused {
                descriptionGlass.backgroundColor = UIColor.white.withAlphaComponent(0.26)
                descriptionGlass.effect = Self.frostedEffect()
            } else if thumbFocused {
                if splitFocus {
                    descriptionGlass.backgroundColor = UIColor.white.withAlphaComponent(0.10)
                    descriptionGlass.effect = nil
                } else {
                    descriptionGlass.backgroundColor = UIColor.white.withAlphaComponent(0.18)
                    descriptionGlass.effect = Self.frostedEffect()
                }
            } else {
                descriptionGlass.backgroundColor = .clear
                descriptionGlass.effect = nil
            }
        }
        if let coordinator {
            animate(coordinator, on: clock, apply)
        } else {
            apply()
        }
    }

    /// Which timing a focus change's text and platter follow. Moving between the art and its description,
    /// they ride the art's own clock, so the platter never reaches the art before it settles (Apple's never touch).
    private enum FocusClock { case shared, artFocusing, artUnfocusing }

    private func animate(_ coordinator: UIFocusAnimationCoordinator, on clock: FocusClock, _ body: @escaping () -> Void) {
        switch clock {
        case .shared: coordinator.addCoordinatedAnimations(body, completion: nil)
        case .artFocusing: coordinator.addCoordinatedFocusingAnimations({ _ in body() }, completion: nil)
        case .artUnfocusing: coordinator.addCoordinatedUnfocusingAnimations({ _ in body() }, completion: nil)
        }
    }

    private static func frostedEffect() -> UIVisualEffect {
        if #available(tvOS 26.0, *) { return UIGlassEffect() }
        return UIBlurEffect(style: .regular)
    }

    /// The description is focusable while this episode holds focus or focus is moving into it;
    /// the second case covers the thumb's loss firing before the description's gain.
    private func applyReachability(next: UIView?) {
        guard splitFocus else { descriptionBlock.isFocusEligible = false; return }
        let stayingInside = next.map { $0.isDescendant(of: self) } ?? false
        descriptionBlock.isFocusEligible = thumbFocused || descFocused || stayingInside
        descriptionFocusGuide.isEnabled = layout == .stacked && !descriptionBlock.isFocusEligible
    }

    private func notifyFocusKind() {
        let kind: EpisodeFocusKind = descFocused ? .description : (thumbFocused ? .thumb : .none)
        onFocusKindChanged?(kind)
    }

    @objc private func handleThumbSelect() { onPlay?() }

    /// Focus asked of the card lands on its thumb.
    override var preferredFocusEnvironments: [UIFocusEnvironment] { [thumbnailCard] }

    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onLongPress?(thumbnailCard.convert(thumbnailCard.bounds, to: nil))
    }

    /// Clear focus visuals + state on reuse.
    func resetFocusVisual() {
        glassLeading.constant = 0
        glassTrailing.constant = 0
        thumbFocused = false
        descFocused = false
        playbackStatus.showsFocused = false
        textTop?.constant = Self.textRestOffset
        descriptionBlock.transform = .identity
        let secondary = Self.secondaryText
        [episodeLabel, summaryLabel, dateLabel, ratingBadge].forEach { $0.textColor = secondary }
        ratingBadge.layer.borderColor = secondary.cgColor
        descriptionBlock.isFocusEligible = false
        descriptionFocusGuide.isEnabled = splitFocus && layout == .stacked
        descriptionGlass.backgroundColor = .clear
        descriptionGlass.effect = nil
    }

    // MARK: - Episode label (mirrors EpisodeCard.episodeLabel)

    private static func episodeLabel(for episode: MediaItem, showSeasonPrefix: Bool) -> String {
        // ATV+ shows "EPISODE N" (the season is conveyed by the pills + the
        // larger between-season gap), not "S01E01".
        if let n = episode.episodeNumber { return String(localized: "Episode \(n)") }
        return episode.episodeString ?? String(localized: "Episode")
    }

    /// Moves a stacked card's text clear of the grown artwork, as Apple's lockup does (VideosUI 26.5 0x4df010).
    private func updateTextDrop(_ coordinator: UIFocusAnimationCoordinator, on clock: FocusClock = .shared) {
        guard textTop != nil else { return }
        // Read inside the animation: the art's and the description's handlers both run before it.
        animate(coordinator, on: clock) { [self] in
            // Apple drops 30 and 20; our artwork grows less, so the focused art's text drops 16 (measured on device).
            let drop: CGFloat = thumbFocused ? 16 : descFocused ? 20 : 0
            textTop?.constant = Self.textRestOffset + drop
            layoutIfNeeded()
        }
    }

    /// The summary on Apple's 30 pt line pitch.
    private static func summaryText(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = summaryLineHeight
        paragraph.maximumLineHeight = summaryLineHeight
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph])
    }

    private static func displayDate(for episode: MediaItem) -> String? {
        guard let raw = episode.releaseDate, !raw.isEmpty else {
            return episode.year.map(String.init)
        }
        if raw.count == 4, Int(raw) != nil { return raw }
        if let date = isoDayFormatter.date(from: raw) {
            return displayDateFormatter.string(from: date)
        }
        return raw
    }

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return formatter
    }()
}

/// Bottom darkening behind a trailer's in-card title.
private final class TrailerScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let layer = self.layer as! CAGradientLayer
        layer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.6).cgColor]
        layer.cornerRadius = 20
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.cornerCurve = .continuous
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The Apple TV app's episode playback status (VideosUI `PlaybackStatusView`, tvOS 27): play or replay
/// glyph, a 34x6 pill bar while in progress, then the time; secondary white at rest, white when focused.
private final class EpisodePlaybackStatusView: UIStackView {
    enum State: Equatable {
        case unwatched(String)
        case inProgress(Double, remaining: String?)
        case watched(String)
    }

    private let glyph = UIImageView()
    private let track = UIView()
    private let fill = UIView()
    private let label = UILabel()
    private var fillWidth: NSLayoutConstraint!
    private static let barSize = CGSize(width: 34, height: 6)

    var state: State? {
        didSet { apply() }
    }

    var showsFocused = false {
        didSet { applyTint() }
    }

    override var lastBaselineAnchor: NSLayoutYAxisAnchor { label.lastBaselineAnchor }

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .horizontal
        alignment = .center
        spacing = 8
        isUserInteractionEnabled = false
        let font = UIFont.systemFont(ofSize: 21, weight: .medium)
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font, scale: .small)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        label.font = font
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        track.layer.cornerRadius = Self.barSize.height / 2
        track.clipsToBounds = true
        fill.layer.cornerRadius = Self.barSize.height / 2
        track.addSubview(fill)
        fill.translatesAutoresizingMaskIntoConstraints = false
        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            track.widthAnchor.constraint(equalToConstant: Self.barSize.width),
            track.heightAnchor.constraint(equalToConstant: Self.barSize.height),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth
        ])
        [glyph, track, label].forEach(addArrangedSubview)
        setCustomSpacing(11, after: glyph)
        applyTint()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    private func apply() {
        isHidden = state == nil
        switch state {
        case .unwatched(let time), .watched(let time):
            glyph.image = UIImage(systemName: state == .watched(time) ? "arrow.clockwise" : "play.fill")
            label.text = time
            label.isHidden = false
            track.isHidden = true
        case .inProgress(let fraction, let remaining):
            glyph.image = UIImage(systemName: "play.fill")
            label.text = remaining
            label.isHidden = remaining == nil
            track.isHidden = false
            // Apple draws at least 2% so a fresh start still shows.
            fillWidth.constant = Self.barSize.width * CGFloat(min(max(fraction, 0.02), 1))
        case nil:
            break
        }
    }

    private func applyTint() {
        let color = showsFocused ? UIColor.white : UIColor.white.withAlphaComponent(0.55)
        glyph.tintColor = color
        label.textColor = color
        track.backgroundColor = UIColor.white.withAlphaComponent(showsFocused ? 0.35 : 0.25)
        fill.backgroundColor = showsFocused ? .white : UIColor.white.withAlphaComponent(0.6)
    }
}

/// Two static gradients, as the Apple TV app's episode lockup draws them on tvOS 27: the artwork's tint
/// to 90%, under dark gray to 64%, so a light tint still darkens. Colors, stops and locations are Apple's
/// (VideosUI `EpisodeLockupLayout`).
private final class EpisodeArtworkFadeView: UIView {
    private let darkening = CAGradientLayer()
    private let tinted = CAGradientLayer()
    private static let tintAlphas: [CGFloat] = [0, 0.05, 0.18, 0.35, 0.55, 0.72, 0.86, 0.9]

    var tint: UIColor? {
        didSet { applyTint() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        darkening.colors = [0, 0.0256, 0.0832, 0.1664, 0.2688, 0.3712, 0.4736, 0.5568, 0.6144, 0.64]
            .map { UIColor(white: 40 / 255, alpha: $0).cgColor }
        darkening.locations = [0.53, 0.59, 0.65, 0.7, 0.74, 0.79, 0.83, 0.87, 0.91, 1]
        for gradient in [darkening, tinted] {
            gradient.cornerRadius = 20
            gradient.cornerCurve = .continuous
        }
        tinted.locations = [0.66, 0.71, 0.77, 0.81, 0.85, 0.9, 0.94, 1]
        layer.addSublayer(tinted)
        layer.addSublayer(darkening)
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTint(_ color: UIColor?, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        CATransaction.setDisableActions(!animated)
        tint = color
        CATransaction.commit()
    }

    private func applyTint() {
        let color = tint ?? .black
        tinted.colors = Self.tintAlphas.map { color.withAlphaComponent($0).cgColor }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        darkening.frame = bounds
        tinted.frame = bounds
        CATransaction.commit()
    }
}

final class PaddingLabel: UILabel {
    var insets: UIEdgeInsets = .zero { didSet { invalidateIntrinsicContentSize() } }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
