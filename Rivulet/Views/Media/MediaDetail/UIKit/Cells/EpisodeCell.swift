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
    /// (isFocused, nextFocusedView, coordinator)
    var onFocusChange: ((Bool, UIView?, UIFocusAnimationCoordinator) -> Void)?

    /// Side by side, the description sits beside its thumb and is always a stop.
    var isAlwaysFocusable = false
    override var canBecomeFocused: Bool { isAlwaysFocusable || isFocusEligible }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChange?(context.nextFocusedView === self, context.nextFocusedView, coordinator)
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

    // MARK: - Subviews

    /// TVUIKit card around the thumbnail — gives Apple's native tvOS focus
    /// treatment (parallax tilt + scale + specular EDGE SHEEN), like the
    /// home-screen cards. Image + overlays live in `thumbnailCard.contentView`.
    private let thumbnailCard = EpisodeThumbCardView()
    private let thumbnailImageView = UIImageView()

    private var thumbHeightConstraint: NSLayoutConstraint!
    private let trailerScrim = TrailerScrimView()
    private let trailerTitleLabel = UILabel()

    private let durationBadge = UIView()
    private let durationIcon = UIImageView()
    private let durationLabel = UILabel()

    /// Subtype icon shown top-trailing on trailer/extra tiles (film, camera, etc.).
    private let subtypeIcon = UIImageView()

    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressFillWidth: NSLayoutConstraint!

    private let watchedGlyph = WatchedGlyphView()

    private let descriptionBlock = EpisodeDescriptionView()
    /// Episode mode (two focus stops: thumb + description). False for trailers
    /// (single thumb stop, with the old whole-card frosted-panel focus look).
    private var splitFocus = false
    private var thumbFocused = false
    private var descFocused = false
    /// Liquid-glass focus highlight behind the metadata (ATV+ uses glass, not a
    /// white outline). Effect is nil until focused.
    private let descriptionGlass = UIVisualEffectView(effect: nil)
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
        thumbnailCard.contentView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        let hold = TileLongPress.makeRecognizer(target: self, action: #selector(handleHold(_:)))
        addGestureRecognizer(hold)
        thumbnailCard.addGestureRecognizer(
            TileLongPress.makeSelectTap(target: self, action: #selector(handleThumbSelect), yieldingTo: hold))
        thumbnailCard.onFocusChange = { [weak self] focused, next, coordinator in
            guard let self else { return }
            self.thumbFocused = focused
            self.applyReachability(next: next)
            self.updateDescriptionGlass(coordinator)
            self.notifyFocusKind()
        }
        addSubview(thumbnailCard)

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true
        thumbnailCard.contentView.addSubview(thumbnailImageView)

        // A trailer's title rides inside the artwork, over a scrim.
        trailerScrim.translatesAutoresizingMaskIntoConstraints = false
        trailerScrim.isHidden = true
        thumbnailCard.contentView.addSubview(trailerScrim)
        trailerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        trailerTitleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        trailerTitleLabel.textColor = .white
        trailerTitleLabel.isHidden = true
        thumbnailCard.contentView.addSubview(trailerTitleLabel)

        // Duration badge (bottom-leading)
        durationBadge.translatesAutoresizingMaskIntoConstraints = false
        durationBadge.backgroundColor = .clear
        durationBadge.layer.cornerRadius = 0
        durationBadge.layer.cornerCurve = .continuous
        durationBadge.isHidden = true
        thumbnailCard.contentView.addSubview(durationBadge)

        durationIcon.translatesAutoresizingMaskIntoConstraints = false
        durationIcon.image = UIImage(systemName: "play.fill")
        durationIcon.tintColor = .white
        durationIcon.contentMode = .scaleAspectFit
        durationIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        durationBadge.addSubview(durationIcon)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        durationLabel.textColor = .white
        durationBadge.addSubview(durationLabel)

        // Watch-progress bar (bottom)
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        progressTrack.isHidden = true
        thumbnailCard.contentView.addSubview(progressTrack)

        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        progressTrack.addSubview(progressFill)

        // Watched tag (top-trailing)
        watchedGlyph.isHidden = true
        thumbnailCard.contentView.addSubview(watchedGlyph)

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
        descriptionBlock.onFocusChange = { [weak self] focused, next, coordinator in
            guard let self else { return }
            self.descFocused = focused
            self.applyReachability(next: next)
            self.updateDescriptionGlass(coordinator)
            self.notifyFocusKind()
        }
        addSubview(descriptionBlock)

        // Glass highlight behind the metadata (added before the labels so it sits
        // behind them). Pinned to fill the description block; rounded + clipped.
        descriptionGlass.translatesAutoresizingMaskIntoConstraints = false
        descriptionGlass.isUserInteractionEnabled = false
        descriptionGlass.clipsToBounds = true
        descriptionGlass.layer.cornerRadius = Self.cornerRadius
        descriptionGlass.layer.cornerCurve = .continuous
        descriptionBlock.addSubview(descriptionGlass)
        NSLayoutConstraint.activate([
            descriptionGlass.topAnchor.constraint(equalTo: descriptionBlock.topAnchor),
            descriptionGlass.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor),
            descriptionGlass.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor),
            descriptionGlass.bottomAnchor.constraint(equalTo: descriptionBlock.bottomAnchor),
        ])

        episodeLabel.translatesAutoresizingMaskIntoConstraints = false
        episodeLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        episodeLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        descriptionBlock.addSubview(episodeLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        descriptionBlock.addSubview(titleLabel)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 21, weight: .medium)
        summaryLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        summaryLabel.numberOfLines = layout == .sideBySide ? 3 : 2
        descriptionBlock.addSubview(summaryLabel)

        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.axis = .horizontal
        footerRow.alignment = .center
        footerRow.spacing = 8
        descriptionBlock.addSubview(footerRow)

        dateLabel.font = .systemFont(ofSize: 21, weight: .medium)
        dateLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        footerRow.addArrangedSubview(dateLabel)

        ratingBadge.font = .systemFont(ofSize: 12, weight: .bold)
        ratingBadge.textColor = UIColor.white.withAlphaComponent(0.86)
        ratingBadge.insets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        ratingBadge.layer.cornerRadius = 3
        ratingBadge.layer.cornerCurve = .continuous
        ratingBadge.layer.borderWidth = 1
        ratingBadge.layer.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        ratingBadge.clipsToBounds = true
        footerRow.addArrangedSubview(ratingBadge)

        progressFillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        thumbHeightConstraint = thumbnailCard.heightAnchor.constraint(equalToConstant: Self.thumbHeight)

        let episodeLeading = episodeLabel.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: 20)
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: 20)
        let summaryLeading = summaryLabel.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: 20)
        let footerLeading = footerRow.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: 20)

        let reserve = MediaRowMetrics.focusGrowth / 2
        switch layout {
        case .stacked:
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: Self.cardWidth),
                thumbnailCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: reserve),
                // The block's edge sits on the thumbnail's leading; its text is padded inside.
                descriptionBlock.topAnchor.constraint(equalTo: thumbnailCard.bottomAnchor, constant: 8),
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
            trailerTitleLabel.leadingAnchor.constraint(equalTo: durationBadge.leadingAnchor),
            trailerTitleLabel.trailingAnchor.constraint(equalTo: thumbnailCard.contentView.trailingAnchor, constant: -16),
            trailerTitleLabel.bottomAnchor.constraint(equalTo: durationBadge.topAnchor, constant: -2),

            thumbnailImageView.topAnchor.constraint(equalTo: thumbnailCard.contentView.topAnchor),
            thumbnailImageView.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: thumbnailCard.contentView.trailingAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: thumbnailCard.contentView.bottomAnchor),

            // Duration badge: 8pt inset from bottom-leading; 8/4 inner padding.
            durationBadge.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor, constant: 12),
            durationBadge.bottomAnchor.constraint(equalTo: thumbnailCard.contentView.bottomAnchor, constant: -10),
            durationIcon.leadingAnchor.constraint(equalTo: durationBadge.leadingAnchor),
            durationIcon.centerYAnchor.constraint(equalTo: durationBadge.centerYAnchor),
            durationLabel.leadingAnchor.constraint(equalTo: durationIcon.trailingAnchor, constant: 4),
            durationLabel.trailingAnchor.constraint(equalTo: durationBadge.trailingAnchor),
            durationLabel.topAnchor.constraint(equalTo: durationBadge.topAnchor),
            durationLabel.bottomAnchor.constraint(equalTo: durationBadge.bottomAnchor),

            // Progress bar: full width, 3pt, pinned bottom.
            progressTrack.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: thumbnailCard.contentView.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: thumbnailCard.contentView.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 3),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressFillWidth,

            // Watched tag: top-trailing.
            // Bottom-left, same spot as the runtime badge (the two are
            // mutually exclusive — watched hides the runtime badge).
            watchedGlyph.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor, constant: 12),
            watchedGlyph.bottomAnchor.constraint(equalTo: thumbnailCard.contentView.bottomAnchor, constant: -10),

            // Subtype icon: top-leading corner of the thumbnail.
            subtypeIcon.leadingAnchor.constraint(equalTo: thumbnailCard.contentView.leadingAnchor, constant: 10),
            subtypeIcon.topAnchor.constraint(equalTo: thumbnailCard.contentView.topAnchor, constant: 10),
            subtypeIcon.widthAnchor.constraint(equalToConstant: 22),
            subtypeIcon.heightAnchor.constraint(equalToConstant: 22),

            descriptionBlock.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Block HUGS its content (top-aligned): short descriptions sit right
            // under the title instead of vertical-centering in a fixed box.
            episodeLabel.topAnchor.constraint(equalTo: descriptionBlock.topAnchor, constant: 12),
            episodeLeading,
            episodeLabel.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor, constant: -20),

            titleLabel.topAnchor.constraint(equalTo: episodeLabel.bottomAnchor, constant: 2),
            titleLeading,
            titleLabel.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor, constant: -20),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            summaryLeading,
            summaryLabel.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor, constant: -20),

            footerRow.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 5),
            footerLeading,
            footerRow.trailingAnchor.constraint(lessThanOrEqualTo: descriptionBlock.trailingAnchor, constant: -20),
            descriptionBlock.bottomAnchor.constraint(equalTo: footerRow.bottomAnchor, constant: 14),
        ])
    }

    // MARK: - Configure

    func configure(episode: MediaItem, showSeasonPrefix: Bool = false) {
        // The description starts unfocusable; see applyReachability.
        setTrailerLayout(false)
        subtypeIcon.isHidden = true
        splitFocus = true
        descriptionBlock.isFocusEligible = false
        episodeLabel.text = Self.episodeLabel(for: episode, showSeasonPrefix: showSeasonPrefix).uppercased()
        titleLabel.text = episode.title.isEmpty ? "Episode" : episode.title
        summaryLabel.text = episode.overview
        summaryLabel.isHidden = (episode.overview ?? "").isEmpty
        dateLabel.text = Self.displayDate(for: episode)
        dateLabel.isHidden = dateLabel.text == nil
        ratingBadge.text = episode.contentRating
        ratingBadge.isHidden = (episode.contentRating ?? "").isEmpty

        // A resume point outranks the watched glyph, as in Plex.
        let inProgress = (episode.watchProgress.map { $0 > 0 && $0 < 1 }) ?? false
        let showGlyph = episode.isWatched && !inProgress

        watchedGlyph.isHidden = !showGlyph

        if showGlyph {
            durationBadge.isHidden = true
            progressTrack.isHidden = true
        } else {
            // Runtime badge (when we have a duration).
            if let duration = episode.durationFormatted {
                durationLabel.text = duration
                durationBadge.isHidden = false
            } else {
                durationBadge.isHidden = true
            }

            // In-progress bar at the very bottom edge.
            if inProgress, let progress = episode.watchProgress {
                progressTrack.isHidden = false
                // Track spans the full card width; fill is that fraction of it.
                progressFillWidth.constant = Self.cardWidth * CGFloat(progress)
            } else {
                progressTrack.isHidden = true
            }
        }

        // Thumbnail (async)
        imageToken &+= 1
        let token = imageToken
        // A memory hit paints in this pass (no pop after the rail's fade).
        let url = episode.artwork.thumbnail ?? episode.artwork.poster
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

    /// The same card with only thumbnail, title and duration, so both rows read as one design.
    func configure(trailer: BelowFoldTrailer) {
        // Trailers keep a single focus stop on the thumb (no description target).
        splitFocus = false
        setTrailerLayout(true)
        descriptionBlock.isFocusEligible = false
        episodeLabel.text = nil
        episodeLabel.isHidden = true
        trailerTitleLabel.text = trailer.title
        titleLabel.text = trailer.title
        summaryLabel.text = nil
        summaryLabel.isHidden = true
        dateLabel.isHidden = true
        ratingBadge.isHidden = true

        if let duration = trailer.durationFormatted {
            durationLabel.text = duration
            durationBadge.isHidden = false
        } else {
            durationBadge.isHidden = true
        }

        progressTrack.isHidden = true
        watchedGlyph.isHidden = true

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
    }

    // MARK: - Focus visuals

    /// Metadata box: full glass when the description (or a trailer's thumb) is focused,
    /// a faint tint for an episode's focused thumb, clear otherwise.
    private func updateDescriptionGlass(_ coordinator: UIFocusAnimationCoordinator?) {
        let apply = { [self] in
            if descFocused {
                descriptionGlass.backgroundColor = UIColor.white.withAlphaComponent(0.18)
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
            coordinator.addCoordinatedAnimations({ apply() }, completion: nil)
        } else {
            apply()
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
        thumbFocused = false
        descFocused = false
        descriptionBlock.isFocusEligible = false
        descriptionGlass.backgroundColor = .clear
        descriptionGlass.effect = nil
    }

    // MARK: - Episode label (mirrors EpisodeCard.episodeLabel)

    private static func episodeLabel(for episode: MediaItem, showSeasonPrefix: Bool) -> String {
        // ATV+ shows "EPISODE N" (the season is conveyed by the pills + the
        // larger between-season gap), not "S01E01".
        if let n = episode.episodeNumber { return "Episode \(n)" }
        return episode.episodeString ?? "Episode"
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
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
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
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
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
