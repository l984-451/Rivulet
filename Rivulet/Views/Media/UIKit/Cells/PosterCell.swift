// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Poster hub cell wrapping `TVPosterView` for native focus motion.
// Caption stays nil: a set caption reserves bottom space even while hidden and crops 2:3 posters.
// Everything that sits on the artwork (badges, watched pill and glyph, progress row, the focused
// score) lives in `artOverlay`, inside `posterView.imageView.overlayContentView`: plain subviews of
// `posterView.imageView` do not render, the overlay content view does, and it moves with the
// artwork's tilt and parallax. The loading and failure states stay in a sibling `overlayContainer`
// that copies the poster's mask and focus scale.

import UIKit
import TVUIKit

@MainActor
final class PosterCell: UICollectionViewCell {
    static let reuseID = "PosterCell"

    private let posterView = TVPosterView()

    /// Hosts the loading and failure states; its transform follows the poster's focus zoom in
    /// `didUpdateFocus`.
    private let overlayContainer = UIView()
    /// Hosts what sits on the artwork (badges, watched pill and glyph, progress row) inside the
    /// image's `overlayContentView`, so it tilts and shifts with the poster.
    private let artOverlay = UIView()
    /// How the image stack carries `overlayContentView`, read from its layers on tvOS 27.2: the
    /// overlay floats `depth` points in front of the picture under the stack's perspective
    /// (1/`viewer`), and the stack scales everything `overscan` past the visible edge so parallax
    /// never shows a gap. Tilting turns the stack by asin(`tilt`) per unit of touch, which moves
    /// the floating overlay `depth * tilt` points across the picture. `artOverlay` undoes both, so
    /// what sits on it stays glued to the artwork and keeps the size and spot it has at rest.
    private enum FocusStack {
        static let depth: CGFloat = 19.0189
        static let viewer: CGFloat = 900
        static let overscan: CGFloat = 1.015
        static let tilt = CGSize(width: 0.070827, height: 0.053559)
        static var counterScale: CGFloat { (viewer - depth) / viewer / overscan }
    }

    private let watchedBadge = PosterWatchedBadge()
    private let sourceBadge = SourceBadgeView(style: .onArtwork)
    /// Plex edition ("Director's Cut"), so two editions sharing a poster tell apart.
    private let editionBadge = SourceBadgeView(style: .onArtwork)
    /// Top-leading column: server badge, then edition badge.
    private let topBadges = UIStackView()
    /// The chosen score, shown only while the poster has focus (Settings > Appearance > Rating).
    /// Created on the first qualifying focus, like `bottomInfoBlur`.
    private var ratingBadge: PosterRatingBadge?
    /// The item's list scores; the chosen source is picked on focus, so a Settings change applies.
    private var ratings: [MediaRating] = []
    private let failureIcon = UIImageView()
    /// The title on the failure card, so an item with no artwork is still named.
    private let failureTitle = UILabel()
    private let progressInfoBar = MediaProgressInfoBar()

    /// Apple-style watched glyph, bottom-left (the progress bar's slot).
    private let watchedGlyph = WatchedGlyphView()

    /// Glass card shown in place of the bare `TVPosterView` gray while the
    /// artwork loads (and on a genuine load failure, with the faint type icon
    /// on top). Plain view, not a blur — a UIVisualEffectView per cell is a
    /// measured perf cost (see `bottomInfoBlur`).
    private let placeholderPanel = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    /// Delays the spinner so a fast cache hit doesn't flash it on scroll.
    private var spinnerDelayTask: Task<Void, Never>?
    /// Bottom-quarter blur under the info bar, in-progress items only. Created lazily:
    /// a UIVisualEffectView per cell was a measured part of the launch snapshot apply.
    private var bottomInfoBlur: BottomInfoBlurView?

    @discardableResult
    private func ensureBottomInfoBlur() -> BottomInfoBlurView {
        if let existing = bottomInfoBlur { return existing }
        let blur = BottomInfoBlurView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        // Under the info bar in z-order.
        artOverlay.insertSubview(blur, belowSubview: progressInfoBar)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: artOverlay.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: artOverlay.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: artOverlay.bottomAnchor),
            blur.heightAnchor.constraint(equalTo: artOverlay.heightAnchor, multiplier: 0.25)
        ])
        bottomInfoBlur = blur
        return blur
    }

    private var failureTitleText: String?
    /// The title showing on the failure card (tests).
    var failureTitleShown: String? { failureTitle.isHidden ? nil : failureTitle.text }

    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?
    /// True once real artwork is showing. `posterView.image` is never nil
    /// (see `blankArtwork`), so it cannot answer this.
    private var hasArtwork = false

    /// Stand-in for missing artwork. TVPosterView drops its focus-growth inset with a nil image,
    /// and keeps the geometry it derived from the stand-in when a cover of the same aspect replaces
    /// it, so a small square stand-in left square covers focusing as a sliver (#504). Tile-sized.
    static let blankArtwork = blank(for: MediaRowMetrics.poster)
    private static let blankMusicArtwork = blank(for: MediaRowMetrics.music)

    static func blank(for tile: MediaRowMetrics.Tile) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: tile.art, format: format).image { _ in }
    }

    private var tileBlankArtwork: UIImage { tile.art == MediaRowMetrics.music.art ? Self.blankMusicArtwork : Self.blankArtwork }

    /// The system image corner on tvOS 26.
    private let cornerRadius: CGFloat = 20
    /// The tile the cell shows; the host view is TVUIKit's focused size (`hostSize`).
    private var tile = MediaRowMetrics.poster

    /// Swappable so music tiles render the 1:1 square lockup instead of the
    /// 2:3 poster one. Set per item in `configure(...)`.
    private var posterWidthConstraint: NSLayoutConstraint!
    private var posterHeightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false

        // Stable identifier for focus diagnostics / UI automation.
        accessibilityIdentifier = "hub.poster.cell.9f27c1"

        // No resting drop shadow, matching the Apple TV app.

        posterView.translatesAutoresizingMaskIntoConstraints = false
        posterView.image = Self.blankArtwork
        contentView.addSubview(posterView)

        // Overlay container clipped to the same rounded rect as the poster.
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.isUserInteractionEnabled = false
        overlayContainer.clipsToBounds = true
        overlayContainer.layer.cornerRadius = cornerRadius
        overlayContainer.layer.cornerCurve = .continuous
        contentView.addSubview(overlayContainer)

        artOverlay.translatesAutoresizingMaskIntoConstraints = false
        artOverlay.isUserInteractionEnabled = false
        let art = posterView.imageView.overlayContentView
        art.addSubview(artOverlay)
        NSLayoutConstraint.activate([
            artOverlay.topAnchor.constraint(equalTo: art.topAnchor),
            artOverlay.bottomAnchor.constraint(equalTo: art.bottomAnchor),
            artOverlay.leadingAnchor.constraint(equalTo: art.leadingAnchor),
            artOverlay.trailingAnchor.constraint(equalTo: art.trailingAnchor)
        ])

        // Placeholder (backmost): covers TVPosterView's bare gray while artwork loads.
        placeholderPanel.translatesAutoresizingMaskIntoConstraints = false
        placeholderPanel.isUserInteractionEnabled = false
        placeholderPanel.backgroundColor = UIColor(white: 0.12, alpha: 1.0)
        placeholderPanel.layer.cornerRadius = cornerRadius
        placeholderPanel.layer.cornerCurve = .continuous
        placeholderPanel.layer.borderWidth = 1
        placeholderPanel.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        placeholderPanel.isHidden = true
        overlayContainer.addSubview(placeholderPanel)

        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.color = UIColor.white.withAlphaComponent(0.7)
        loadingSpinner.hidesWhenStopped = true
        overlayContainer.addSubview(loadingSpinner)

        // (The blur band is created lazily — see ensureBottomInfoBlur.)
        progressInfoBar.translatesAutoresizingMaskIntoConstraints = false
        progressInfoBar.isHidden = true; bottomInfoBlur?.isHidden = true
        artOverlay.addSubview(progressInfoBar)

        // Watched badge: top-trailing, 10pt inset.
        watchedBadge.translatesAutoresizingMaskIntoConstraints = false
        watchedBadge.isHidden = true
        artOverlay.addSubview(watchedBadge)

        // Server badge then edition badge: top-leading, 10pt inset. Hidden badges collapse.
        topBadges.translatesAutoresizingMaskIntoConstraints = false
        topBadges.axis = .vertical
        topBadges.alignment = .leading
        topBadges.spacing = 6
        topBadges.addArrangedSubview(sourceBadge)
        topBadges.addArrangedSubview(editionBadge)
        artOverlay.addSubview(topBadges)

        // Failure icon: centred. Hidden by default; visible only when the
        // image load fails or the source URL is missing.
        failureIcon.translatesAutoresizingMaskIntoConstraints = false
        failureIcon.contentMode = .scaleAspectFit
        failureIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        failureIcon.isHidden = true
        overlayContainer.addSubview(failureIcon)

        failureTitle.translatesAutoresizingMaskIntoConstraints = false
        failureTitle.font = .systemFont(ofSize: 24, weight: .medium)
        failureTitle.textColor = UIColor.white.withAlphaComponent(0.6)
        failureTitle.textAlignment = .center
        failureTitle.numberOfLines = 4
        failureTitle.isHidden = true
        overlayContainer.addSubview(failureTitle)

        // Watched glyph: bottom-left, same slot as the progress bar / play icon.
        watchedGlyph.isHidden = true
        artOverlay.addSubview(watchedGlyph)

        posterWidthConstraint = posterView.widthAnchor.constraint(equalToConstant: tile.hostSize.width)
        posterHeightConstraint = posterView.heightAnchor.constraint(equalToConstant: tile.hostSize.height)
        NSLayoutConstraint.activate([
            posterView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterWidthConstraint,
            posterHeightConstraint,

            // Pin to TVPosterView's IMAGE surface, not its outer frame: the
            // frame reserves room for focus growth, so the resting picture is
            // smaller and an overlay on the outer frame hangs off it.
            overlayContainer.topAnchor.constraint(equalTo: posterView.imageView.topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: posterView.imageView.bottomAnchor),
            overlayContainer.leadingAnchor.constraint(equalTo: posterView.imageView.leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: posterView.imageView.trailingAnchor),

            // Same slot as ContinueWatchingCell's status row.
            progressInfoBar.leadingAnchor.constraint(equalTo: artOverlay.leadingAnchor,
                                                     constant: MediaProgressInfoBar.leadingInset),
            progressInfoBar.trailingAnchor.constraint(equalTo: artOverlay.trailingAnchor,
                                                      constant: -MediaProgressInfoBar.leadingInset),
            progressInfoBar.centerYAnchor.constraint(equalTo: artOverlay.bottomAnchor,
                                                     constant: -MediaProgressInfoBar.centerFromBottom),

            watchedBadge.topAnchor.constraint(equalTo: artOverlay.topAnchor, constant: 10),
            watchedBadge.trailingAnchor.constraint(equalTo: artOverlay.trailingAnchor, constant: -10),
            topBadges.topAnchor.constraint(equalTo: artOverlay.topAnchor, constant: 10),
            topBadges.leadingAnchor.constraint(equalTo: artOverlay.leadingAnchor, constant: 10),
            topBadges.trailingAnchor.constraint(lessThanOrEqualTo: artOverlay.trailingAnchor, constant: -10),

            failureIcon.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            failureIcon.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),
            failureIcon.widthAnchor.constraint(equalToConstant: 32),
            failureIcon.heightAnchor.constraint(equalToConstant: 32),
            failureTitle.topAnchor.constraint(equalTo: failureIcon.bottomAnchor, constant: 12),
            failureTitle.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor, constant: 16),
            failureTitle.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -16),

            // Glass placeholder fills the image surface; spinner centered on it.
            placeholderPanel.topAnchor.constraint(equalTo: overlayContainer.topAnchor),
            placeholderPanel.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor),
            placeholderPanel.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor),
            placeholderPanel.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),

            // Watched glyph shares the progress bar's bottom-left anchor.
            watchedGlyph.leadingAnchor.constraint(equalTo: artOverlay.leadingAnchor,
                                                  constant: MediaProgressInfoBar.leadingInset),
            watchedGlyph.centerYAnchor.constraint(equalTo: artOverlay.bottomAnchor,
                                                  constant: -MediaProgressInfoBar.centerFromBottom)
        ])
    }

    // MARK: - Focus zoom sync

    /// The overlay doesn't follow the poster's focus growth, so mirror the tile's
    /// here; the host's own growth is trimmed to the tile's by `focusScale`.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
                      || context.nextFocusedView?.isDescendant(of: self) == true
        let artSize = posterView.imageView.bounds.size
        let longSide = max(artSize.width, artSize.height)
        let scale = longSide > 0 ? 1 + tile.growth.height / longSide : 1.1
        let rating = nowFocused ? focusRating : nil
        if let rating { prepareRatingBadge(rating) }
        // The score fades in as the poster lifts and out as it settles. It sits on the artwork that
        // shrinks in place, so the short fade out leaves no ghost behind the move.
        if let badge = ratingBadge {
            if rating != nil {
                coordinator.addCoordinatedFocusingAnimations({ _ in badge.fade(in: true) }, completion: nil)
            } else if !badge.isHidden {
                coordinator.addCoordinatedUnfocusingAnimations({ _ in badge.fade(in: false) }, completion: nil)
            }
        }
        setArtOverlayMotion(nowFocused)
        coordinator.addCoordinatedAnimations({
            self.artOverlay.transform = nowFocused
                ? CGAffineTransform(scaleX: FocusStack.counterScale, y: FocusStack.counterScale) : .identity
            self.posterView.transform = nowFocused ? self.tile.focusScale : .identity
            self.progressInfoBar.setFocused(nowFocused)
            self.overlayContainer.transform = nowFocused
                ? CGAffineTransform(scaleX: scale, y: scale)
                : .identity
        }, completion: { [weak self] in
            guard let self, !nowFocused else { return }
            // TVPosterView's own unfocus sometimes leaves the poster enlarged; enforce the end state.
            self.resetStaleFocusAppearance()
        })
    }

    /// Moves `artOverlay` against the stack's tilt on the same touch, cancelling the slide its depth
    /// would add, so badges stay put on the picture while the poster tilts.
    private func setArtOverlayMotion(_ focused: Bool) {
        artOverlay.motionEffects.forEach { artOverlay.removeMotionEffect($0) }
        guard focused else { return }
        let across = FocusStack.depth * FocusStack.tilt.width
        let down = FocusStack.depth * FocusStack.tilt.height
        let x = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
        x.minimumRelativeValue = -across
        x.maximumRelativeValue = across
        let y = UIInterpolatingMotionEffect(keyPath: "center.y", type: .tiltAlongVerticalAxis)
        y.minimumRelativeValue = -down
        y.maximumRelativeValue = down
        let group = UIMotionEffectGroup()
        group.motionEffects = [x, y]
        artOverlay.addMotionEffect(group)
    }

    /// Clears a focused look TVPosterView left behind: its unfocus animation sometimes never runs
    /// (focus left into a presented carousel), stranding the scale and parallax. No-op while focused,
    /// since the completion can fire after focus has returned.
    func resetStaleFocusAppearance() {
        guard !isFocused else { return }
        // A fade out still running is the normal unfocus; let it finish rather than cut it.
        if let badge = ratingBadge, !badge.isFading { badge.setMaterialized(false) }
        func clear(_ v: UIView) {
            if !v.transform.isIdentity { v.transform = .identity }
            if !CATransform3DIsIdentity(v.layer.transform) { v.layer.transform = CATransform3DIdentity }
            v.motionEffects.forEach { v.removeMotionEffect($0) }
            v.subviews.forEach(clear)
        }
        clear(posterView)
        overlayContainer.transform = .identity
        artOverlay.transform = .identity
    }

    // MARK: - Configure

    func configure(item: PlexMetadata) {
        sourceBadge.text = nil
        setSquare(["artist", "album", "track"].contains(item.type ?? ""))
        let url = posterURL(for: item)
        failureTitleText = item.title
        setEdition(item.editionTitle)
        setRatings(["movie", "show"].contains(item.type ?? "") ? PlexMediaMapper.ratings(item) : [])
        loadImage(from: url, item: item)
        configureProgressBar(item: item)
        configureWatchedBadge(item: item)
    }

    /// MediaItem path. All artwork URLs are already resolved — no serverURL/token needed.
    func configure(item: MediaItem) {
        sourceBadge.text = nil
        setSquare(item.isMusic == true)
        // Episodes prefer the grandparent (show) poster so hub rows render
        // show art instead of letterboxed episode stills, matching the Plex path.
        let url = item.grandparentArtwork?.poster ?? item.artwork.poster
        failureTitleText = item.title
        setEdition(item.editionTitle)
        setRatings(item.kind == .movie || item.kind == .show ? item.ratings ?? [] : [])
        loadImage(from: url, failureKind: item.kind)
        configureProgressBar(item: item)
        configureWatchedBadge(item: item)
    }

    /// Names the item's server; call after `configure` (which never adds one).
    func setSourceBadge(_ text: String?) { sourceBadge.text = text }

    /// The badge's text while it shows (tests).
    var sourceBadgeText: String? { sourceBadge.isHidden ? nil : sourceBadge.text }

    private func setEdition(_ edition: String?) {
        editionBadge.text = edition?.isEmpty == false ? edition : nil
    }

    /// The edition badge's text while it shows (tests).
    var editionBadgeText: String? { editionBadge.isHidden ? nil : editionBadge.text }

    private func setRatings(_ ratings: [MediaRating]) {
        self.ratings = ratings
        if isFocused, let rating = focusRating {
            // Configured while already focused: no focus animation will form it.
            UIView.performWithoutAnimation {
                prepareRatingBadge(rating)
                ratingBadge?.setMaterialized(true)
            }
        } else {
            ratingBadge?.setMaterialized(false)
        }
    }

    /// The score the badge shows on focus, or nil when the setting is off or the list carries no
    /// named score. Both are read here, on each focus change, so Settings applies on the next move.
    private var focusRating: MediaRating? {
        guard SettingsStore.bool(MediaRating.posterBadgeKey, default: false) else { return nil }
        return MediaRating.posterRating(in: ratings)
    }

    /// The score this poster would show with the setting on (tests).
    var posterRatingLine: String? { MediaRating.posterRating(in: ratings)?.posterLine }

    /// Text and slot settle outside the focus animation; the coordinator then only fades it in.
    private func prepareRatingBadge(_ rating: MediaRating) {
        UIView.performWithoutAnimation {
            let badge = ensureRatingBadge()
            badge.configure(rating)
            artOverlay.layoutIfNeeded()
            let slot = Self.ratingSlot(pill: watchedBadge.isHidden ? nil : watchedBadge.frame,
                                       badges: topBadges.arrangedSubviews.contains { !$0.isHidden } ? topBadges.frame : nil,
                                       typeWidth: badge.typeWidth, overlayWidth: artOverlay.bounds.width)
            badge.setCorner(slot.corner)
            badge.setTopClearance(slot.clearance)
            badge.isHidden = false
            badge.layoutIfNeeded()
        }
    }

    /// Where the score goes beside the watched pill (top trailing) and the server and edition badges
    /// (top leading): the pill holds the trailing corner, so the score takes the leading one, unless
    /// the badges hold that too; then it goes below the pill. The badges alone push it down only when
    /// they would reach it. Frames in `artOverlay`'s space; `clearance` is the top inset it needs.
    static func ratingSlot(pill: CGRect?, badges: CGRect?, typeWidth: CGFloat,
                           overlayWidth: CGFloat) -> (corner: PosterRatingBadge.Corner, clearance: CGFloat) {
        switch (pill, badges) {
        case (_?, nil): return (.topLeading, 0)
        case let (pill?, _?): return (.topTrailing, pill.maxY + 6)
        case let (nil, badges?):
            let typeLeft = overlayWidth - PosterRatingBadge.inset - typeWidth
            return (.topTrailing, badges.maxX + 12 > typeLeft ? badges.maxY + 6 : 0)
        case (nil, nil): return (.topTrailing, 0)
        }
    }

    /// On `artOverlay` with the other badges, so it tilts, shifts and catches the sheen with the art.
    private func ensureRatingBadge() -> PosterRatingBadge {
        if let existing = ratingBadge { return existing }
        let badge = PosterRatingBadge()
        artOverlay.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: artOverlay.topAnchor),
            badge.bottomAnchor.constraint(equalTo: artOverlay.bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: artOverlay.leadingAnchor),
            badge.trailingAnchor.constraint(equalTo: artOverlay.trailingAnchor)
        ])
        ratingBadge = badge
        return badge
    }

    /// Music tiles are 1:1 square; everything else keeps the 2:3 poster ratio.
    private func setSquare(_ square: Bool) {
        tile = square ? MediaRowMetrics.music : MediaRowMetrics.poster
        let host = tile.hostSize
        if posterHeightConstraint.constant != host.height {
            posterWidthConstraint.constant = host.width
            posterHeightConstraint.constant = host.height
        }
        if !hasArtwork { posterView.image = tileBlankArtwork }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetContent()
        contentView.setReorderWiggle(false)
    }

    /// Blank glass card for a library-grid slot whose page has not loaded.
    /// A slot flips to a real item through `reconfigureItems` on the same
    /// cell, and back to this on a sort reset, so clear the previous
    /// occupant here rather than assume `prepareForReuse` ran.
    func configurePlaceholder() {
        resetContent()
        placeholderPanel.isHidden = false
    }

    private func resetContent() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
        cancelSpinnerDelay()
        loadingSpinner.stopAnimating()
        placeholderPanel.isHidden = true
        currentURL = nil
        clearArtwork()
        progressInfoBar.isHidden = true; bottomInfoBlur?.isHidden = true
        progressInfoBar.reset()
        watchedBadge.isHidden = true
        sourceBadge.text = nil
        editionBadge.text = nil
        ratings = []
        ratingBadge?.setMaterialized(false)
        watchedGlyph.isHidden = true
        failureIcon.isHidden = true
        failureIcon.image = nil
        failureTitle.isHidden = true
        failureTitle.text = nil
        // A recycled cell must not inherit a prior occupant's stranded focus
        // (enlarged) appearance — clear any leftover scale transform.
        resetStaleFocusAppearance()
    }

    // MARK: - Image load

    /// PlexMetadata path: resolves the failure icon via the full Plex type
    /// switch (including music types) then delegates to the shared loader.
    private func loadImage(from url: URL?, item: PlexMetadata) {
        loadImage(from: url, failureIcon: failureIconImage(for: item))
    }

    /// MediaItem path: resolves the failure icon via MediaKind then delegates.
    private func loadImage(from url: URL?, failureKind: MediaKind) {
        loadImage(from: url, failureIcon: failureIconImage(for: failureKind))
    }

    private func loadImage(from url: URL?, failureIcon: UIImage?) {
        imageLoadTask?.cancel()
        guard let url else {
            clearArtwork()
            currentURL = nil
            showPlaceholderFailure(failureIcon)
            return
        }
        if currentURL == url, hasArtwork {
            hidePlaceholder()
            return
        }
        currentURL = url
        // Memory hit paints in this pass, so a tile realized for a carousel
        // exit has artwork to fly to.
        if let cached = ImageCacheManager.shared.cachedImage(for: url) {
            posterView.image = cached
            hasArtwork = true
            hidePlaceholder()
            return
        }
        // Glass panel up immediately (covers the bare gray); the load now
        // retries transient failures internally, so the spinner simply rides
        // the single await until the artwork resolves or genuinely fails.
        showPlaceholderLoading()
        let key = url.absoluteString as AnyHashable
        imageLoadTask = Task { [weak self] in
            let image: UIImage? = await Perf.interval(.imageDecode, key: key) {
                await ImageCacheManager.shared.image(for: url)
            }
            await MainActor.run {
                guard let self, self.currentURL == url else { return }
                if let image {
                    self.posterView.image = image
                    self.hasArtwork = true
                    self.hidePlaceholder()
                } else {
                    self.clearArtwork()
                    self.showPlaceholderFailure(failureIcon)
                }
            }
        }
    }

    private func clearArtwork() {
        posterView.image = tileBlankArtwork
        hasArtwork = false
    }

    /// Glass panel + (delayed) spinner while the artwork loads/retries.
    private func showPlaceholderLoading() {
        placeholderPanel.isHidden = false
        failureIcon.isHidden = true
        failureTitle.isHidden = true
        // Delay the spinner so a fast cache hit doesn't flash it on scroll.
        cancelSpinnerDelay()
        spinnerDelayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.placeholderPanel.isHidden, !self.hasArtwork {
                self.loadingSpinner.startAnimating()
            }
        }
    }

    /// Glass panel + faint type icon after a genuine (post-retry) failure.
    private func showPlaceholderFailure(_ icon: UIImage?) {
        cancelSpinnerDelay()
        loadingSpinner.stopAnimating()
        placeholderPanel.isHidden = false
        failureIcon.image = icon
        failureIcon.isHidden = false
        failureTitle.text = failureTitleText
        failureTitle.isHidden = (failureTitleText ?? "").isEmpty
    }

    /// Artwork resolved — tear the placeholder down.
    private func hidePlaceholder() {
        cancelSpinnerDelay()
        loadingSpinner.stopAnimating()
        placeholderPanel.isHidden = true
        failureIcon.isHidden = true
        failureTitle.isHidden = true
    }

    private func cancelSpinnerDelay() {
        spinnerDelayTask?.cancel()
        spinnerDelayTask = nil
    }

    /// Failure icon for every Plex type, music included.
    private func failureIconImage(for item: PlexMetadata) -> UIImage? {
        let name: String
        switch item.type {
        case "movie":   name = "film"
        case "show":    name = "tv"
        case "season":  name = "number.square"
        case "episode": name = "play.rectangle"
        case "artist":  name = "music.mic"
        case "album":   name = "square.stack"
        case "track":   name = "music.note"
        default:        name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }

    /// MediaItem failure icon — maps MediaKind to a system image name.
    private func failureIconImage(for kind: MediaKind) -> UIImage? {
        let name: String
        switch kind {
        case .movie:   name = "film"
        case .show:    name = "tv"
        case .season:  name = "number.square"
        case .episode: name = "play.rectangle"
        case .person:  name = "person"
        default:       name = "photo"
        }
        return UIImage(systemName: name)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .light))
    }

    private func posterURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken
        else { return nil }
        // Episodes prefer the show (grandparent) thumb so Recently-Added
        // episode rows render show posters, not letterboxed episode stills.
        let path: String?
        if item.type == "episode" {
            path = item.grandparentThumb ?? item.parentThumb ?? item.thumb
        } else {
            path = item.thumb
        }
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(token)")
    }

    // MARK: - In-progress bar (CW-style)

    private func configureProgressBar(item: PlexMetadata) {
        // Show the CW-style info bar only when an item is in progress
        // (0 < watchProgress < 1). Audio items (album / artist / track)
        // suppress progress entirely.
        if isAudioItem(item) {
            progressInfoBar.isHidden = true; bottomInfoBlur?.isHidden = true
            progressInfoBar.reset()
            return
        }
        if let progress = item.watchProgress, progress > 0, progress < 1 {
            progressInfoBar.isHidden = false; ensureBottomInfoBlur().isHidden = false
            progressInfoBar.configure(item: item)
        } else {
            progressInfoBar.isHidden = true; bottomInfoBlur?.isHidden = true
            progressInfoBar.reset()
        }
    }

    private func isAudioItem(_ item: PlexMetadata) -> Bool {
        switch item.type {
        case "album", "artist", "track": return true
        default: return false
        }
    }

    // MARK: - Watched badge

    private func configureWatchedBadge(item: PlexMetadata) {
        // Ladder:
        //  1. Audio items: nothing.
        //  2. TV show with leafCount > 0 and unwatched > 0: blue count pill (top-right).
        //  3. Fully watched (show / movie / episode): rewatch glyph (bottom-left).
        if isAudioItem(item) {
            hideWatchedIndicators()
            return
        }
        if item.type == "show", let leafCount = item.leafCount, leafCount > 0 {
            let viewed = item.viewedLeafCount ?? 0
            let unwatched = leafCount - viewed
            if unwatched > 0 {
                showUnwatchedCount(unwatched)
                return
            }
            if viewed >= leafCount {
                showWatchedGlyph()
                return
            }
        }
        if isFullyWatched(item) {
            showWatchedGlyph()
            return
        }
        hideWatchedIndicators()
    }

    private func isFullyWatched(_ item: PlexMetadata) -> Bool {
        guard let viewCount = item.viewCount, viewCount > 0 else { return false }
        if let progress = item.watchProgress, progress > 0, progress < 1 {
            return false
        }
        if let viewOffset = item.viewOffset, let duration = item.duration {
            let remaining = duration - viewOffset
            if remaining > 60_000 { return false }   // >1 minute left
        }
        return true
    }

    // MARK: - MediaItem progress bar

    private func configureProgressBar(item: MediaItem) {
        // MediaItem has no audio kind equivalent; only person/collection/playlist are
        // "no progress" -- treat anything without a runtime as suppressed.
        guard item.kind != .person, item.kind != .collection, item.kind != .playlist else {
            progressInfoBar.isHidden = true; bottomInfoBlur?.isHidden = true
            progressInfoBar.reset()
            return
        }
        let offset = item.userState.viewOffset
        let fraction: Double
        if let rt = item.runtime, rt > 0 {
            fraction = offset / rt
        } else {
            fraction = 0
        }
        if fraction > 0 && fraction < 1 {
            progressInfoBar.isHidden = false; ensureBottomInfoBlur().isHidden = false
            progressInfoBar.configure(item: item)
        } else {
            progressInfoBar.isHidden = true; bottomInfoBlur?.isHidden = true
            progressInfoBar.reset()
        }
    }

    // MARK: - MediaItem watched badge

    private func configureWatchedBadge(item: MediaItem) {
        // Watched is a video concept only. Music (artist/album/track map to
        // .unknown), people, and collections never get a watched indicator.
        switch item.kind {
        case .movie, .show, .season, .episode: break
        default:
            hideWatchedIndicators()
            return
        }
        // Shows: unwatched count pill (top-right), or fully-watched glyph.
        if item.kind == .show, let cp = item.childProgress, cp.total > 0 {
            let unwatched = cp.total - cp.played
            if unwatched > 0 {
                showUnwatchedCount(unwatched)
                return
            }
            showWatchedGlyph()   // all episodes played
            return
        }
        // Movies/episodes: the glyph shows only when watched AND not in progress.
        // An item with an active resume point shows the progress bar instead —
        // Plex shows one or the other, never both.
        if isFullyWatched(item) {
            showWatchedGlyph()
            return
        }
        hideWatchedIndicators()
    }

    /// MediaItem twin of the PlexMetadata `isFullyWatched`. Uses the same
    /// `0 < fraction < 1` in-progress test as `configureProgressBar(item:)`, so
    /// the watched glyph and the progress bar are mutually exclusive.
    private func isFullyWatched(_ item: MediaItem) -> Bool {
        guard item.userState.isPlayed else { return false }
        if let rt = item.runtime, rt > 0 {
            let fraction = item.userState.viewOffset / rt
            if fraction > 0, fraction < 1 { return false }   // in progress → bar wins
        }
        return true
    }

    // MARK: - Watched indicators

    /// Fully watched → Apple-style rewatch glyph, bottom-left (same slot as the
    /// play icon + progress bar). The top-right pill is for *unwatched* shows
    /// only, so it's hidden here. No legibility band — the glyph relies on its
    /// own soft shadow.
    private func showWatchedGlyph() {
        watchedGlyph.isHidden = false
        watchedBadge.isHidden = true
    }

    /// Unwatched TV show → blue count pill, top-right.
    private func showUnwatchedCount(_ count: Int) {
        watchedBadge.setStyle(.unwatchedCount(count))
        watchedBadge.isHidden = false
        watchedGlyph.isHidden = true
    }

    private func hideWatchedIndicators() {
        watchedBadge.isHidden = true
        watchedGlyph.isHidden = true
    }
}

// MARK: - Unwatched-count badge

/// Top-trailing blue pill with an in-progress show's unwatched-episode count.
@MainActor
final class PosterWatchedBadge: UIView {
    enum Style {
        case unwatchedCount(Int)
    }

    private let pillLabel = UILabel()
    private let pillBackground = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // Blue capsule with N text.
        pillBackground.translatesAutoresizingMaskIntoConstraints = false
        pillBackground.backgroundColor = .systemBlue
        pillBackground.layer.cornerRadius = 10
        pillBackground.layer.cornerCurve = .continuous
        pillBackground.layer.shadowColor = UIColor.black.cgColor
        pillBackground.layer.shadowOpacity = 0.3
        pillBackground.layer.shadowRadius = 4
        pillBackground.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(pillBackground)

        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = .systemFont(ofSize: 12, weight: .bold)
        pillLabel.textColor = .white
        pillBackground.addSubview(pillLabel)

        NSLayoutConstraint.activate([
            pillLabel.topAnchor.constraint(equalTo: pillBackground.topAnchor, constant: 4),
            pillLabel.bottomAnchor.constraint(equalTo: pillBackground.bottomAnchor, constant: -4),
            pillLabel.leadingAnchor.constraint(equalTo: pillBackground.leadingAnchor, constant: 8),
            pillLabel.trailingAnchor.constraint(equalTo: pillBackground.trailingAnchor, constant: -8),

            pillBackground.topAnchor.constraint(equalTo: topAnchor),
            pillBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            pillBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillBackground.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setStyle(_ style: Style) {
        switch style {
        case .unwatchedCount(let count):
            pillLabel.text = "\(count)"
        }
    }
}

extension PosterCell: PreviewSourceTile {
    var previewArtworkView: UIView { overlayContainer }
    var previewCornerRadius: CGFloat { cornerRadius }
    var previewArtworkLoaded: Bool { hasArtwork }
}
