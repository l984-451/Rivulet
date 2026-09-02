// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PosterCell.swift
//  Rivulet
//
//  Poster-style hub cell (Recently Added rows, Personalized Recommendations).
//  Wraps `TVPosterView` for native tvOS focus motion (parallax, scale, glow).
//
//  Caption (`title` / `subtitle`) is intentionally nil. When set,
//  `TVPosterView` reserves bottom space for the on-focus caption block
//  even while the caption is hidden, which compresses the image area and
//  visibly crops the bottom of 2:3 Plex posters. SwiftUI MediaPosterCard
//  doesn't render a caption either; the title surfaces in the preview
//  overlay / detail view instead.
//
//  Overlay subviews (watched badge, in-progress info bar, failure icon)
//  live in a sibling `overlayContainer` view that:
//    * matches the poster's 260x390 frame
//    * applies its own 16pt corner mask so the watched corner-tag clips
//      to the same rounded edge as the poster image
//    * tracks the cell's focus state and applies the same scale
//      transform `TVPosterView` uses for the image (so overlays grow
//      with the poster instead of staying static during focus zoom)
//
//  Earlier attempts to host overlays inside `posterView.contentView` or
//  `posterView.imageView` either produced invisible badges (Apple's
//  internal layout doesn't render subviews on the imageView) or didn't
//  inherit clipping correctly. The sibling-with-matching-transform
//  approach is reliable on both counts.
//
//  In-progress composition matches Continue Watching exactly (per user
//  direction): a MediaProgressInfoBar (play.fill icon + 44pt capsule
//  progress + "S1, E2 . 35m" info text) directly over the art — no dark
//  gradient/scrim behind it (removed 2026-06-10; it read as a bad shadow).
//  Only renders when `0 < item.watchProgress < 1`. Watched and
//  unwatched items show no bottom bar.
//

import UIKit
import TVUIKit

@MainActor
final class PosterCell: UICollectionViewCell {
    static let reuseID = "PosterCell"

    private let posterView = TVPosterView()

    /// Sibling of `posterView` that hosts overlays. Has its own rounded
    /// mask so the corner-tag clips to the same shape as the poster; its
    /// transform is kept in sync with the posterView's focus zoom in
    /// `didUpdateFocus`.
    private let overlayContainer = UIView()

    private let watchedBadge = PosterWatchedBadge()
    private let failureIcon = UIImageView()
    private let progressInfoBar = MediaProgressInfoBar()

    /// Apple-style "watched" indicator, bottom-left (same slot as the play
    /// icon + progress bar). Replaces the old top-trailing corner checkmark.
    private let watchedGlyph = WatchedGlyphView()

    /// Glass card shown in place of the bare `TVPosterView` gray while the
    /// artwork loads (and on a genuine load failure, with the faint type icon
    /// on top). Plain view, not a blur — a UIVisualEffectView per cell is a
    /// measured perf cost (see `bottomInfoBlur`).
    private let placeholderPanel = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    /// Delays the spinner so a fast cache hit doesn't flash it on scroll.
    private var spinnerDelayTask: Task<Void, Never>?
    /// ATV+ legibility band: bottom-quarter blur under the info bar.
    /// Toggled together with `progressInfoBar` (in-progress items only).
    /// LAZY: a UIVisualEffectView per cell was a measured chunk of the
    /// 5s launch dataSource.apply (40-60 instances realized per apply);
    /// most posters are not in-progress and never need one.
    private var bottomInfoBlur: BottomInfoBlurView?

    @discardableResult
    private func ensureBottomInfoBlur() -> BottomInfoBlurView {
        if let existing = bottomInfoBlur { return existing }
        let blur = BottomInfoBlurView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        // Under the info bar in z-order.
        overlayContainer.insertSubview(blur, belowSubview: progressInfoBar)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor),
            blur.heightAnchor.constraint(equalTo: overlayContainer.heightAnchor, multiplier: 0.25)
        ])
        bottomInfoBlur = blur
        return blur
    }

    private var imageLoadTask: Task<Void, Never>?
    private var currentURL: URL?

    private let cornerRadius: CGFloat = 16
    private let posterWidth: CGFloat = MediaRowMetrics.posterWidth
    private let posterHeight: CGFloat = MediaRowMetrics.posterHeight

    /// Swappable so music tiles render 1:1 square (height == width) instead of
    /// the 2:3 poster ratio. Set per item in `configure(...)`.
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

        // No resting drop shadow: the ATV+ reference (Docs/atv_ref/
        // below_home_hero_ref.md) floats cards directly over the page
        // background — focus chrome is image-bound, no dark halo.

        posterView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(posterView)

        // Overlay container clipped to the same rounded rect as the poster.
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.isUserInteractionEnabled = false
        overlayContainer.clipsToBounds = true
        overlayContainer.layer.cornerRadius = cornerRadius
        overlayContainer.layer.cornerCurve = .continuous
        contentView.addSubview(overlayContainer)

        // Glass placeholder (backmost): covers TVPosterView's bare gray while
        // the artwork loads, and hosts the failure icon on a genuine miss. A
        // neutral dark fill (slightly above the page background) + a hairline
        // edge reads as a calm card, not Apple's lighter empty-poster gray.
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
        overlayContainer.addSubview(progressInfoBar)

        // Watched badge: top-trailing, 10pt inset (mirrors SwiftUI `.padding(10)`).
        watchedBadge.translatesAutoresizingMaskIntoConstraints = false
        watchedBadge.isHidden = true
        overlayContainer.addSubview(watchedBadge)

        // Failure icon: centred. Hidden by default; visible only when the
        // image load fails or the source URL is missing.
        failureIcon.translatesAutoresizingMaskIntoConstraints = false
        failureIcon.contentMode = .scaleAspectFit
        failureIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        failureIcon.isHidden = true
        overlayContainer.addSubview(failureIcon)

        // Watched glyph: bottom-left, same slot as the progress bar / play icon.
        watchedGlyph.isHidden = true
        overlayContainer.addSubview(watchedGlyph)

        posterHeightConstraint = posterView.heightAnchor.constraint(equalToConstant: posterHeight)
        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: contentView.topAnchor),
            posterView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            posterView.widthAnchor.constraint(equalToConstant: posterWidth),
            posterHeightConstraint,

            // Pin to TVPosterView's IMAGE surface, not its outer frame:
            // TVPosterView can reserve a footer strip below the picture (the
            // on-focus caption area), so a bottom-pinned overlay on the outer
            // frame hangs below the visible poster — the in-progress blur
            // band made this obvious ("blur coming off the poster").
            overlayContainer.topAnchor.constraint(equalTo: posterView.imageView.topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: posterView.imageView.bottomAnchor),
            overlayContainer.leadingAnchor.constraint(equalTo: posterView.imageView.leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: posterView.imageView.trailingAnchor),

            // Info bar pinned to the bottom of the overlay container
            // (= bottom of the poster). Insets match ContinueWatchingCell
            // (16 leading / 15 bottom) so the two read identically. The blur
            // band's constraints live in ensureBottomInfoBlur (lazy).
            progressInfoBar.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor, constant: 16),
            progressInfoBar.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -16),
            progressInfoBar.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor, constant: -15),

            watchedBadge.topAnchor.constraint(equalTo: overlayContainer.topAnchor, constant: 10),
            watchedBadge.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -10),

            failureIcon.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            failureIcon.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),
            failureIcon.widthAnchor.constraint(equalToConstant: 32),
            failureIcon.heightAnchor.constraint(equalToConstant: 32),

            // Glass placeholder fills the image surface; spinner centered on it.
            placeholderPanel.topAnchor.constraint(equalTo: overlayContainer.topAnchor),
            placeholderPanel.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor),
            placeholderPanel.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor),
            placeholderPanel.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),

            // Watched glyph shares the progress bar's bottom-left anchor.
            watchedGlyph.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor, constant: 16),
            watchedGlyph.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor, constant: -15)
        ])
    }

    // MARK: - Focus zoom sync

    /// `TVPosterView` applies its own focus scale transform to the image
    /// (via `focusSizeIncrease`) that doesn't propagate to our sibling
    /// `overlayContainer`. We mirror it here so overlays grow with the
    /// poster instead of staying static. The 1.1 scale is the published
    /// default for `TVPosterView` at standard contentSize (260x390); it's
    /// close enough that the visual offset is imperceptible.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let nowFocused = context.nextFocusedView === self
                      || context.nextFocusedView?.isDescendant(of: self) == true
        coordinator.addCoordinatedAnimations({
            self.overlayContainer.transform = nowFocused
                ? CGAffineTransform(scaleX: 1.1, y: 1.1)
                : .identity
        }, completion: { [weak self] in
            guard let self, !nowFocused else { return }
            // TVPosterView owns its focus scale and shrinks via its own
            // coordinated unfocus animation — which sometimes does NOT reset
            // (the poster stays enlarged with the engine reporting it
            // unfocused, so no further event will fix it). Once the focus
            // animation settles, enforce the unfocused end state ourselves.
            self.resetStaleFocusAppearance()
        })
    }

    /// Force-clear a stale focused appearance. TVPosterView owns its focus
    /// scale and the remote-tilt motion effects; both are torn down by its own
    /// coordinated unfocus animation, which sometimes never runs (e.g. focus
    /// left the whole collection into a presented carousel) — the poster
    /// strands enlarged AND keeps parallax-wiggling with the remote while the
    /// engine reports it unfocused, so no further event will fix it. Clear any
    /// leftover scale transform and strip motion effects from the poster's
    /// view tree directly. No-ops if the cell is (or became) focused — the
    /// unfocus-completion trigger can land after focus has already returned to
    /// this cell, and must not wipe a live focused appearance.
    func resetStaleFocusAppearance() {
        guard !isFocused else { return }
        func clear(_ v: UIView) {
            if !v.transform.isIdentity { v.transform = .identity }
            if !CATransform3DIsIdentity(v.layer.transform) { v.layer.transform = CATransform3DIdentity }
            v.motionEffects.forEach { v.removeMotionEffect($0) }
            v.subviews.forEach(clear)
        }
        clear(posterView)
        overlayContainer.transform = .identity
    }

    // MARK: - Configure

    func configure(item: PlexMetadata) {
        setSquare(["artist", "album", "track"].contains(item.type ?? ""))
        let url = posterURL(for: item)
        loadImage(from: url, item: item)
        configureProgressBar(item: item)
        configureWatchedBadge(item: item)
    }

    /// MediaItem path. All artwork URLs are already resolved — no serverURL/token needed.
    func configure(item: MediaItem) {
        setSquare(item.isMusic == true)
        // Episodes prefer the grandparent (show) poster so hub rows render
        // show art instead of letterboxed episode stills, matching the Plex path.
        let url = item.grandparentArtwork?.poster ?? item.artwork.poster
        loadImage(from: url, failureKind: item.kind)
        configureProgressBar(item: item)
        configureWatchedBadge(item: item)
    }

    /// Music tiles are 1:1 square; everything else keeps the 2:3 poster ratio.
    private func setSquare(_ square: Bool) {
        let height = square ? MediaRowMetrics.musicHeight : posterHeight
        if posterHeightConstraint.constant != height {
            posterHeightConstraint.constant = height
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetContent()
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
        posterView.image = nil
        progressInfoBar.isHidden = true; bottomInfoBlur?.isHidden = true
        progressInfoBar.reset()
        watchedBadge.isHidden = true
        watchedGlyph.isHidden = true
        failureIcon.isHidden = true
        failureIcon.image = nil
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
            posterView.image = nil
            currentURL = nil
            showPlaceholderFailure(failureIcon)
            return
        }
        if currentURL == url, posterView.image != nil {
            hidePlaceholder()
            return
        }
        currentURL = url
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
                    self.hidePlaceholder()
                } else {
                    self.posterView.image = nil
                    self.showPlaceholderFailure(failureIcon)
                }
            }
        }
    }

    /// Glass panel + (delayed) spinner while the artwork loads/retries.
    private func showPlaceholderLoading() {
        placeholderPanel.isHidden = false
        failureIcon.isHidden = true
        // Delay the spinner so a fast cache hit doesn't flash it on scroll.
        cancelSpinnerDelay()
        spinnerDelayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.placeholderPanel.isHidden, self.posterView.image == nil {
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
    }

    /// Artwork resolved — tear the placeholder down.
    private func hidePlaceholder() {
        cancelSpinnerDelay()
        loadingSpinner.stopAnimating()
        placeholderPanel.isHidden = true
        failureIcon.isHidden = true
    }

    private func cancelSpinnerDelay() {
        spinnerDelayTask?.cancel()
        spinnerDelayTask = nil
    }

    /// Full Plex-type failure icon switch, including music types.
    /// Mirror of SwiftUI `MediaPosterCard.iconForType` (all types).
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

    /// Mirror of SwiftUI `MediaPosterCard.isFullyWatched`.
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
        // MediaItem has no audio kind equivalent; only person/collection are
        // "no progress" -- treat anything without a runtime as suppressed.
        guard item.kind != .person, item.kind != .collection else {
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

/// Top-trailing blue pill showing the unwatched-episode count for an in-progress
/// TV show. The fully-watched state is now shown by a bottom-left rewatch glyph
/// (`WatchedGlyphView`), Apple-style — not by this badge.
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
