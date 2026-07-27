// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EpisodeCell.swift
//  Rivulet
//
//  A fixed-width episode card: thumbnail (with duration badge, watch-progress
//  bar, watched tag) over a description block (episode label / title /
//  summary). Reusable standalone UIView with `configure(...)`; can be hosted
//  in the below-fold episode row now and wrapped in a UICollectionViewCell
//  when the below-fold becomes a compositional collection.
//
//  Faithful to the SwiftUI source: cardWidth 340, thumbHeight 192, corner 16,
//  white-0.08 card fill, the duration/progress/watched overlays, and the
//  description typography (label 15 medium uppercase white-0.6, title 20 bold,
//  summary 16 white-0.7 / 3 lines).
//
//  Focus is exposed via setFocused(...): subtle whole-card scale plus built-in
//  liquid-glass surfaces on the thumbnail and metadata. No custom border or
//  hand-drawn reflection is used.
//

import UIKit
import TVUIKit

/// Which sub-target of an episode card currently holds focus. Episodes split
/// into two focus stops (thumb = play, description = details); trailers stay
/// single-target (`.thumb` only).
enum EpisodeFocusKind { case none, thumb, description }

/// The thumbnail card as a first-class focus target. `TVCardView` already gives
/// the native tvOS focus motion (parallax + scale + edge sheen); this subclass
/// adds Select delivery and focus reporting so the thumb can be one of the two
/// episode focus stops. Select on tvOS is caught in `pressesEnded(.select)` (a
/// bare control's `primaryActionTriggered` is unreliable here).
final class EpisodeThumbCardView: TVCardView {
    var onSelect: (() -> Void)?
    /// (isFocused, nextFocusedView, coordinator)
    var onFocusChange: ((Bool, UIView?, UIFocusAnimationCoordinator) -> Void)?

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChange?(context.nextFocusedView === self, context.nextFocusedView, coordinator)
    }

    // Consume the Select press in BOTH began/ended so the focused card owns the
    // press cycle — otherwise pressesEnded(.select) is not reliably delivered
    // (mirrors DetailCardControl).
    // TVCardView cancels the Select press internally between pressesBegan and
    // pressesEnded (the Ended becomes pressesCancelled), so an Ended-based
    // handler never runs. Fire onSelect on pressesBegan — the only event that is
    // reliably delivered to a focused TVCardView.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { onSelect?(); return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }  // handled in pressesBegan
        super.pressesEnded(presses, with: event)
    }
}

/// The metadata block as the SECOND episode focus stop. Focusable only when
/// `isFocusEligible` (true for episodes, false for trailers — trailers keep a
/// single thumb stop). Select opens the episode detail page.
final class EpisodeDescriptionView: UIView {
    /// Gated: focusable only while this episode is the active row (its thumb or
    /// description holds focus), so Up coming from a lower section skips straight
    /// to the thumb instead of landing here. The thumb is the row anchor; the
    /// description is reachable only by pressing Down from the thumb.
    var isFocusEligible = false
    var onSelect: (() -> Void)?
    /// (isFocused, nextFocusedView, coordinator)
    var onFocusChange: ((Bool, UIView?, UIFocusAnimationCoordinator) -> Void)?

    override var canBecomeFocused: Bool { isFocusEligible }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChange?(context.nextFocusedView === self, context.nextFocusedView, coordinator)
    }

    // Consume the Select press in BOTH began/ended so the focused block owns the
    // press cycle (mirrors DetailCardControl) — required for reliable delivery.
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

    // MARK: - Focus callbacks (wired by EpisodeCollectionCell)

    /// Thumb Select → play this episode. (Episodes only.)
    var onPlay: (() -> Void)?
    /// Description Select → open the episode detail page. (Episodes only.)
    var onShowDetails: (() -> Void)?
    /// Reports which sub-target is focused on every focus change (thumb /
    /// description / none). Drives season-pill tracking and the Up handler's
    /// "description → thumb, thumb → pills" decision.
    var onFocusKindChanged: ((EpisodeFocusKind) -> Void)?

    // ATV+ details rail: 410pt card slots with ~30pt gutters. Keeping the
    // hosted view the same width as the compositional item avoids the airy
    // effective 80pt gaps caused by a narrower inner view.
    static let cardWidth: CGFloat = 436
    static let thumbHeight: CGFloat = 245   // 16:9 at the detail rail width (ATV+ shows ~4 across)
    private static let cornerRadius: CGFloat = 16

    // MARK: - Subviews

    /// TVUIKit card around the thumbnail — gives Apple's native tvOS focus
    /// treatment (parallax tilt + scale + specular EDGE SHEEN), like the
    /// home-screen cards. Image + overlays live in `thumbnailCard.contentView`.
    private let thumbnailCard = EpisodeThumbCardView()
    private let thumbnailImageView = UIImageView()

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

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("EpisodeCell is not Storyboard-backed") }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        // ATV+: no card background — a clean rounded thumbnail over plain
        // metadata; only the FOCUSED episode gets a metadata box (set in
        // setFocused). clipsToBounds stays false so the 1.05 focus scale and the
        // box aren't clipped.
        backgroundColor = .clear
        clipsToBounds = false

        // Thumbnail — TVCardView gives Apple's native tvOS focus motion
        // (parallax + scale + the specular edge sheen). Image + overlays go in
        // card.contentView so they ride the focus motion (same as the home-screen
        // ContinueWatchingCell). The card draws its own rounded shape; the
        // contentView background is the placeholder grey behind the image.
        thumbnailCard.translatesAutoresizingMaskIntoConstraints = false
        thumbnailCard.contentSize = CGSize(width: Self.cardWidth, height: Self.thumbHeight)
        thumbnailCard.contentView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        thumbnailCard.onSelect = { [weak self] in self?.onPlay?() }
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
        summaryLabel.numberOfLines = 2
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

        let episodeLeading = episodeLabel.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: 14)
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: 14)
        let summaryLeading = summaryLabel.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: 14)
        let footerLeading = footerRow.leadingAnchor.constraint(equalTo: descriptionBlock.leadingAnchor, constant: 14)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.cardWidth),

            thumbnailCard.topAnchor.constraint(equalTo: topAnchor),
            thumbnailCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnailCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnailCard.heightAnchor.constraint(equalToConstant: Self.thumbHeight),

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

            // Description block: its LEFT edge (and the focus glass that fills it)
            // sits on the shared content edge = the thumbnail's leading. The text
            // is indented inside by the block's inner padding, like the pill
            // capsule. No left bleed into the margin.
            descriptionBlock.topAnchor.constraint(equalTo: thumbnailCard.bottomAnchor, constant: 8),
            descriptionBlock.leadingAnchor.constraint(equalTo: leadingAnchor),
            descriptionBlock.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Block HUGS its content (top-aligned): short descriptions sit right
            // under the title instead of vertical-centering in a fixed box.
            episodeLabel.topAnchor.constraint(equalTo: descriptionBlock.topAnchor, constant: 12),
            episodeLeading,
            episodeLabel.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor, constant: -14),

            titleLabel.topAnchor.constraint(equalTo: episodeLabel.bottomAnchor, constant: 2),
            titleLeading,
            titleLabel.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor, constant: -14),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            summaryLeading,
            summaryLabel.trailingAnchor.constraint(equalTo: descriptionBlock.trailingAnchor, constant: -14),

            footerRow.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 5),
            footerLeading,
            footerRow.trailingAnchor.constraint(lessThanOrEqualTo: descriptionBlock.trailingAnchor, constant: -14),
            descriptionBlock.bottomAnchor.constraint(equalTo: footerRow.bottomAnchor, constant: 14),
        ])
    }

    // MARK: - Configure

    func configure(episode: MediaItem, showSeasonPrefix: Bool = false) {
        // Episodes have two focus stops: thumb (play) + description (details).
        // The description starts gated OFF; it becomes focusable only once the
        // thumb takes focus (see applyReachability), so the first focus into the
        // row lands on the thumb and Up-from-below skips the description.
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

        // Bottom-left corner state. In-progress takes precedence: an episode
        // with an active resume point shows the progress bar + runtime, never
        // the watched glyph (Plex shows one or the other). Watched-and-finished
        // shows the rewatch glyph in that corner instead of the runtime badge.
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
        thumbnailImageView.image = nil
        if let url = episode.artwork.thumbnail ?? episode.artwork.poster {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                await MainActor.run {
                    guard let self, self.imageToken == token else { return }
                    self.thumbnailImageView.image = image
                }
            }
        }
    }

    /// Trailers reuse the exact same card (TVCardView thumbnail + sheen + glass
    /// focus panel) as episodes so the two rows read as one design. A trailer has
    /// no episode number, summary, date, or rating — those are hidden and the
    /// block hugs thumbnail + title. Duration shows in the same on-thumbnail badge.
    func configure(trailer: BelowFoldTrailer) {
        // Trailers keep a single focus stop on the thumb (no description target).
        splitFocus = false
        descriptionBlock.isFocusEligible = false
        episodeLabel.text = nil
        episodeLabel.isHidden = true
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
        thumbnailImageView.image = nil
        if let url = trailer.artworkURL {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                await MainActor.run {
                    guard let self, self.imageToken == token else { return }
                    self.thumbnailImageView.image = image
                }
            }
        }
    }

    // MARK: - Focus visuals

    /// Drive the metadata glass from the two sub-target focus states. The
    /// THUMBNAIL focus motion (parallax/scale + edge sheen) is owned by the
    /// TVCardView and animates itself; here we only drive the metadata box:
    ///   - description focused  → full frosted glass box (ATV+ "selected" look).
    ///   - thumb focused, episode → subtle companion tint (shows the metadata is
    ///     part of the same card) but NOT the glass.
    ///   - thumb focused, trailer → full frosted box (single-target legacy look).
    ///   - neither focused      → clear.
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

    /// Gate the description's focusability so Up from a lower section skips it
    /// and lands on the thumb. The description is focusable only while this
    /// episode is the active row: its thumb or description holds focus, OR the
    /// focus is moving INTO this cell (next focus target is inside it — this
    /// keeps it eligible across the thumb→description hand-off, avoiding a race
    /// where the thumb's loss callback fires before the description's gain).
    private func applyReachability(next: UIView?) {
        guard splitFocus else { descriptionBlock.isFocusEligible = false; return }
        let stayingInside = next.map { $0.isDescendant(of: self) } ?? false
        descriptionBlock.isFocusEligible = thumbFocused || descFocused || stayingInside
    }

    private func notifyFocusKind() {
        let kind: EpisodeFocusKind = descFocused ? .description : (thumbFocused ? .thumb : .none)
        onFocusKindChanged?(kind)
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

private final class PaddingLabel: UILabel {
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
