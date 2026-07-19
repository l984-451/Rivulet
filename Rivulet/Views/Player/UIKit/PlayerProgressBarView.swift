// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerProgressBarView.swift
//  Rivulet
//
//  Transport scrubber styled after AVPlayerViewController (tvOS 15+):
//  a thin rounded white bar with a 26pt circular knob — the fill edge is
//  the playhead. While scrubbing, the bar keeps its REST geometry (no
//  ribbon/strip morph) — only the existing scrub/focus emphasis treatment
//  (thicker track, larger knob, brighter ring) marks the state. An
//  oversized readout (chapter eyebrow + large timecode) tracks the seek x
//  ~12pt above the bar, and a single trickplay thumbnail card (288×162)
//  floats 12pt above the readout — both clamped to the bar's own
//  horizontal bounds, visible only while scrubbing. Time remaining sits
//  below the right end, with an "Ends at" clock-time label beside it.
//  Plex markers (intro/credits) tint their range on the bar.
//
//  The view's own height covers only the track + label band; the
//  thumb/readout overhangs above it (clipsToBounds = false) so the
//  transport bar doesn't reserve blank space when they're hidden.
//
//  One-clock rule: any show/hide animation for the readout/thumb rides
//  the SAME `UIView.animate` block in `update(...)` that already animates
//  `trackHeightConstraint` + `layoutIfNeeded`. Their position is frame
//  assignment in `layoutScrubOverlay(...)`, not a new animator. No second
//  animator, no CABasicAnimation, no separate CADisplayLink.
//

import UIKit

/// Horizontal accent gradient used for the progress fill. A
/// `CAGradientLayer`-backed view resizes its layer automatically via
/// `layerClass`, so it stays a drop-in frame-driven replacement for the
/// plain white `progressFill` view laid out by `update(...)`'s animate block.
final class AccentGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let g = layer as! CAGradientLayer
        g.colors = [
            UIColor(red: 0x7f/255, green: 0xb8/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xb9/255, green: 0xa3/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xff/255, green: 0xce/255, blue: 0x93/255, alpha: 1).cgColor,
            UIColor(red: 0x8f/255, green: 0xe9/255, blue: 0xd4/255, alpha: 1).cgColor,
        ]
        g.locations = [0, 0.45, 0.8, 1]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        layer.cornerRadius = 5
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class PlayerProgressBarView: UIView {

    // MARK: - Metrics (AVPlayerViewController-matched)

    private enum Metrics {
        static let trackHeight: CGFloat = 10
        static let scrubTrackHeight: CGFloat = 14
        static let labelBandSpacing: CGFloat = 14
        static let thumbnailWidth: CGFloat = 288
        static let thumbnailHeight: CGFloat = 162
        static let thumbnailGap: CGFloat = 20
        static let thumbnailReadoutGap: CGFloat = 12
        static let endsAtGap: CGFloat = 24
        static let wheelRingDiameter: CGFloat = 44
        static let wheelRingBorderWidth: CGFloat = 3
        static let wheelDotDiameter: CGFloat = 6
        static let wheelRingGap: CGFloat = 16
    }

    // MARK: - Marker coloring

    static func color(for marker: PlexMarker) -> UIColor {
        if marker.isIntro {
            return .systemBlue
        } else if marker.isCredits {
            return .systemPurple
        } else {
            return .systemYellow
        }
    }

    // MARK: - Subviews

    private let trackBackground = UIView()
    private let currentPositionGhost = UIView()
    private let progressFill = AccentGradientView()
    private let handleView = UIView()          // white core
    private let handleRing = UIView()          // ring behind it
    private let markersContainer = UIView()
    private let currentTimeLabel = UILabel()
    private let remainingTimeLabel = UILabel()
    private let endsAtLabel = UILabel()
    private let scrubStepLabel = UILabel()
    private let thumbnailImageView = UIImageView()
    private let thumbnailContainer = UIView()

    /// Oversized scrub readout: replaces the old `PaddedChipLabel` chip.
    /// `readoutContainer` is a small frame-driven container (a sibling of
    /// `trackBackground` on `self`, positioned/clamped above the bar's own
    /// rest geometry) holding a small-caps chapter eyebrow above a large
    /// timecode. The eyebrow hides when the playhead isn't inside a named
    /// chapter, leaving just the timecode.
    private let readoutContainer = UIView()
    private let readoutEyebrowLabel = UILabel()
    private let readoutTimecodeLabel = UILabel()

    // Jog wheel indicator: shown beside the readout only while a circular
    // clickpad rotation is actively driving the scrub (`isWheelScrubbing`).
    // Frame-driven like readoutContainer, positioned in
    // `layoutScrubOverlay(...)`.
    private let wheelRing = UIView()
    private let wheelDot = UIView()
    private var isWheelScrubbing = false

    private var lastChapters: [PlexChapter] = []

    private var duration: TimeInterval = 0
    /// Cached from the last `update(...)` call so `resetFilmstrip()` can
    /// redraw the marker band without losing state.
    private var lastMarkers: [PlexMarker] = []

    private var trackHeightConstraint: NSLayoutConstraint!
    private var endsAtTrailingConstraint: NSLayoutConstraint!
    private var endsAtPlayheadConstraint: NSLayoutConstraint!

    /// Loading placeholder mode; see `setSkeleton(_:)`.
    private var isSkeleton = false
    /// Set when the skeleton clears so the next `update(...)` applies
    /// without animation — the first real fill position after loading
    /// must jump into place, not sweep out from zero.
    private var snapNextUpdate = false

    /// Paused presentation: the accent fill dims while paused (2a spec).
    /// Stored and folded into update()'s alpha computation; applied
    /// immediately here because time ticks stop while the player is paused.
    private var isPausedDim = false

    /// True while the scrubber focus proxy (`ScrubberFocusProxyView`, in
    /// PlayerContainerViewController) holds focus. Folded into the same
    /// grow-and-brighten emphasis computation as `isScrubbing` — see
    /// `scrubEmphasis` in `update(...)` — so a down-press from any rail
    /// button reads as "the scrubber has focus" the same way entering seek
    /// mode does. Stored (not applied via `update(...)` alone) because
    /// focus can change while time ticks are paused.
    private var focusEmphasis = false

    private static let endsAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        clipsToBounds = false

        trackBackground.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        trackBackground.layer.cornerCurve = .continuous
        trackBackground.clipsToBounds = true

        // Actual playback position while previewing elsewhere.
        currentPositionGhost.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        currentPositionGhost.isHidden = true

        handleRing.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        handleView.backgroundColor = .white
        handleView.layer.shadowColor = UIColor.black.cgColor
        handleView.layer.shadowOpacity = 0.5
        handleView.layer.shadowRadius = 16
        handleView.layer.shadowOffset = CGSize(width: 0, height: 4)

        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        currentTimeLabel.textColor = UIColor.white.withAlphaComponent(0.82)

        remainingTimeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        remainingTimeLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        remainingTimeLabel.textAlignment = .right

        endsAtLabel.font = .systemFont(ofSize: 17, weight: .medium)
        endsAtLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        endsAtLabel.textAlignment = .right

        scrubStepLabel.font = .systemFont(ofSize: 20, weight: .medium)
        scrubStepLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        scrubStepLabel.isHidden = true

        // Single trickplay thumb card: floats above the readout while
        // scrubbing, centered on the seek x. Plain dim fill (no
        // spinner/skeleton) shows until the first `scrubThumbnail` lands;
        // `thumbnailImageView` keeps whatever frame it last had while the
        // next one loads (see `update(...)`'s image assignment).
        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true
        thumbnailImageView.backgroundColor = UIColor.white.withAlphaComponent(0.06)

        thumbnailContainer.isHidden = true
        thumbnailContainer.layer.cornerRadius = 14
        thumbnailContainer.layer.cornerCurve = .continuous
        thumbnailContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        thumbnailContainer.layer.borderWidth = 1
        thumbnailContainer.layer.shadowColor = UIColor.black.cgColor
        thumbnailContainer.layer.shadowOpacity = 0.5
        thumbnailContainer.layer.shadowRadius = 24
        thumbnailContainer.layer.shadowOffset = CGSize(width: 0, height: 10)
        thumbnailContainer.clipsToBounds = false
        thumbnailImageView.layer.cornerRadius = 14
        thumbnailImageView.layer.cornerCurve = .continuous
        thumbnailContainer.addSubview(thumbnailImageView)

        // Oversized readout: replaces the old pill chip. A small-caps
        // chapter eyebrow above a large monospaced timecode, laid out
        // frame-wise (no constraints — 2a lesson: cross-view constraints
        // must not be introduced inside these frame-driven overlays).
        readoutEyebrowLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        readoutEyebrowLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        readoutEyebrowLabel.textAlignment = .center
        readoutEyebrowLabel.isHidden = true

        readoutTimecodeLabel.font = .monospacedDigitSystemFont(ofSize: 50, weight: .bold)
        readoutTimecodeLabel.textColor = .white
        readoutTimecodeLabel.textAlignment = .center

        readoutContainer.addSubview(readoutEyebrowLabel)
        readoutContainer.addSubview(readoutTimecodeLabel)
        readoutContainer.isHidden = true

        wheelRing.backgroundColor = .clear
        wheelRing.layer.borderWidth = Metrics.wheelRingBorderWidth
        wheelRing.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        wheelRing.layer.cornerRadius = Metrics.wheelRingDiameter / 2
        wheelRing.isHidden = true

        wheelDot.backgroundColor = .white
        wheelDot.layer.cornerRadius = Metrics.wheelDotDiameter / 2
        wheelDot.isHidden = true

        [trackBackground, currentTimeLabel, remainingTimeLabel,
         endsAtLabel, scrubStepLabel, readoutContainer, thumbnailContainer, wheelRing, wheelDot].forEach {
            addSubview($0)
        }
        [currentPositionGhost, progressFill, markersContainer].forEach {
            trackBackground.addSubview($0)
        }
        // Handle views are frame-driven siblings of trackBackground (not
        // children of it — the track clips its contents, which would clip
        // the handle's shadow).
        addSubview(handleRing)
        addSubview(handleView)

        // Thumbnail card is frame-driven, like readoutContainer — it only
        // ever appears while scrubbing, positioned and clamped in
        // `layoutScrubOverlay(...)`.
        thumbnailImageView.frame = thumbnailContainer.bounds
        thumbnailImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        [trackBackground, currentTimeLabel, remainingTimeLabel, endsAtLabel, scrubStepLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        trackHeightConstraint = trackBackground.heightAnchor.constraint(equalToConstant: Metrics.trackHeight)

        endsAtTrailingConstraint = endsAtLabel.trailingAnchor.constraint(
            equalTo: remainingTimeLabel.leadingAnchor,
            constant: -Metrics.endsAtGap
        )
        endsAtPlayheadConstraint = endsAtLabel.centerXAnchor.constraint(equalTo: leadingAnchor)

        NSLayoutConstraint.activate([
            trackBackground.topAnchor.constraint(equalTo: topAnchor),
            trackBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackHeightConstraint,

            // Label band below the track. The elapsed time is pinned to
            // the left (always visible); remaining time is pinned below
            // the right end, with "Ends at" to its left.
            currentTimeLabel.topAnchor.constraint(equalTo: trackBackground.bottomAnchor, constant: Metrics.labelBandSpacing),
            currentTimeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            scrubStepLabel.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            scrubStepLabel.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 16),

            remainingTimeLabel.topAnchor.constraint(equalTo: trackBackground.bottomAnchor, constant: Metrics.labelBandSpacing),
            remainingTimeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            endsAtLabel.centerYAnchor.constraint(equalTo: remainingTimeLabel.centerYAnchor),
            endsAtTrailingConstraint,

            bottomAnchor.constraint(equalTo: currentTimeLabel.bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackBackground.layer.cornerRadius = trackHeightConstraint.constant / 2
        // Keep the shimmer's gradient layer sized to the track (skeleton
        // mode never coexists with scrubbing, so the track stays at its
        // resting height, but width can still change on layout). Disable
        // implicit actions so this frame sync doesn't animate.
        if let shimmerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shimmerLayer.frame = trackBackground.bounds
            CATransaction.commit()
        }
    }

    // MARK: - Update

    func update(
        currentTime: TimeInterval,
        duration: TimeInterval,
        isScrubbing: Bool,
        scrubTime: TimeInterval,
        scrubStepLabelText: String?,
        scrubThumbnail: UIImage?,
        markers: [PlexMarker],
        chapters: [PlexChapter],
        isWheelScrubbing: Bool = false
    ) {
        guard !isSkeleton else { return }

        self.isScrubbing = isScrubbing
        self.isWheelScrubbing = isWheelScrubbing
        self.duration = duration
        self.lastMarkers = markers
        self.lastChapters = chapters

        let displayTime = isScrubbing ? scrubTime : currentTime
        let progress: Double = duration > 0 ? min(1, max(0, displayTime / duration)) : 0

        let width = trackBackground.bounds.width
        let currentProgress: Double = duration > 0 ? min(1, max(0, currentTime / duration)) : 0

        // Seek-focus emphasis: true while the scrubber focus proxy holds
        // focus (`focusEmphasis`) even when not actively scrubbing — a
        // down-press from any rail button lands on the proxy, and it must
        // read as "the scrubber has focus" the same grow-and-brighten way
        // entering seek mode does.
        let scrubEmphasis = isScrubbing || focusEmphasis
        let trackHeight: CGFloat = scrubEmphasis ? Metrics.scrubTrackHeight : Metrics.trackHeight

        currentPositionGhost.isHidden = !isScrubbing
        trackHeightConstraint.constant = trackHeight

        // Paused dim only applies at rest — never while actively scrubbing
        // (setPausedDim's own guard already prevents that combination from
        // being set in the first place, but the emphasis state below is
        // re-derived from the current isScrubbing local on every call, so
        // this stays consistent even if that ever changes). Focus emphasis
        // also rules it out: a down-press that lands the proxy in focus
        // must win over the paused-at-rest knob shrink, so the "scrubber
        // has focus" grow-and-brighten is never undercut by the smaller
        // paused knob.
        let pausedAtRest = self.isPausedDim && !isScrubbing && !focusEmphasis

        // First paint after loading snaps into place: animating the fill
        // from zero out to a resume position reads as a sweep, not a jump.
        let animationDuration: TimeInterval = snapNextUpdate ? 0 : 0.15
        snapNextUpdate = false

        UIView.animate(withDuration: animationDuration) {
            self.progressFill.alpha = pausedAtRest ? 0.78 : 1
            self.progressFill.frame = CGRect(x: 0, y: 0, width: width * progress, height: trackHeight)
            if isScrubbing {
                self.currentPositionGhost.frame = CGRect(
                    x: 0, y: 0,
                    width: width * currentProgress,
                    height: trackHeight
                )
            }

            // Handle: a plain circle at rest. Grows 26 → 32 and its ring
            // brightens 0.14 → 0.35 while scrubbing OR while the scrubber
            // focus proxy holds focus (both fold into `scrubEmphasis`), so
            // seek focus and down-press focus both read instantly (tvOS's
            // own grow-and-brighten grammar). While paused at rest (not
            // scrubbing, NOT focus-emphasized) it instead shrinks 26 → 22
            // and its ring alpha drops to 0 (no glow) per the 3a
            // paused-dim spec. `scrubEmphasis` takes priority over the
            // paused shrink in both ternaries below — checked first — and
            // `pausedAtRest`'s own `!focusEmphasis` term rules out the
            // combination existing in the first place; focused always wins
            // over paused-at-rest. Frame-driven, positioned at the fill
            // edge and vertically centered on the track — a sibling of
            // trackBackground so it isn't clipped by the track's own
            // clipsToBounds.
            let handleDiameter: CGFloat = scrubEmphasis ? 32 : (pausedAtRest ? 22 : 26)
            let handleSize = CGSize(width: handleDiameter, height: handleDiameter)
            let ringInset: CGFloat = 6
            let handleX = width * CGFloat(progress)
            let trackMidY = self.trackBackground.frame.minY + trackHeight / 2
            self.handleView.frame = CGRect(x: handleX - handleSize.width / 2, y: trackMidY - handleSize.height / 2,
                                           width: handleSize.width, height: handleSize.height)
            self.handleView.layer.cornerRadius = handleSize.width / 2
            self.handleRing.frame = self.handleView.frame.insetBy(dx: -ringInset, dy: -ringInset)
            self.handleRing.layer.cornerRadius = self.handleRing.frame.width / 2
            self.handleRing.backgroundColor = UIColor.white.withAlphaComponent(
                scrubEmphasis ? 0.35 : (pausedAtRest ? 0 : 0.14)
            )

            // Readout + thumb: fade with the same clock as the rest of
            // this block (one-clock rule) — no strip morph left to gate
            // them on, just the scrubbing state itself.
            self.readoutContainer.alpha = isScrubbing ? 1 : 0
            self.thumbnailContainer.alpha = isScrubbing ? 1 : 0

            self.layoutIfNeeded()
        }

        renderMarkers(markers, duration: duration, trackWidth: width, trackHeight: trackHeight)

        if isScrubbing {
            layoutScrubOverlay(progress: progress, width: width)
        }

        // The elapsed time label is static and left-pinned — always
        // visible, showing the live/scrub position (no playhead-following
        // or clamping needed; the oversized readout above the bar covers
        // the scrub-position readout while scrubbing).
        currentTimeLabel.text = Self.formatTime(displayTime)

        remainingTimeLabel.text = "-\(Self.formatTime(max(0, duration - displayTime)))"

        let endsAt = Date().addingTimeInterval(max(0, duration - displayTime))
        endsAtLabel.text = "Ends at \(Self.endsAtFormatter.string(from: endsAt))"
        endsAtLabel.isHidden = duration <= 0 || isScrubbing

        scrubStepLabel.isHidden = !isScrubbing || scrubStepLabelText == nil
        scrubStepLabel.text = scrubStepLabelText

        // Trickplay thumb card: only ever shown while scrubbing
        // (position/frame assigned in `layoutScrubOverlay`). The image is
        // set whenever a new one lands — never waited on — so the last
        // frame stays visible while the next scrub tick's fetch is still
        // in flight; before the first frame arrives the plain dim fill set
        // on `thumbnailImageView`'s background shows through.
        thumbnailContainer.isHidden = !isScrubbing
        if let scrubThumbnail {
            thumbnailImageView.image = scrubThumbnail
        }

        readoutContainer.isHidden = !isScrubbing

        let showWheelIndicator = isScrubbing && isWheelScrubbing
        wheelRing.isHidden = !showWheelIndicator
        wheelDot.isHidden = !showWheelIndicator
    }

    /// Live TV keeps the progress bar's existing geometry and fill treatment,
    /// but labels the programme window with wall-clock times. The current clock
    /// time follows the playhead instead of occupying either edge.
    func updateLiveTimeline(startTime: Date, currentTime: Date, endTime: Date) {
        let duration = endTime.timeIntervalSince(startTime)
        guard duration > 0 else { return }

        let elapsed = min(max(0, currentTime.timeIntervalSince(startTime)), duration)
        update(
            currentTime: elapsed,
            duration: duration,
            isScrubbing: false,
            scrubTime: 0,
            scrubStepLabelText: nil,
            scrubThumbnail: nil,
            markers: [],
            chapters: []
        )

        currentTimeLabel.text = Self.endsAtFormatter.string(from: startTime)
        remainingTimeLabel.text = Self.endsAtFormatter.string(from: endTime)
        endsAtLabel.text = Self.endsAtFormatter.string(from: currentTime)
        endsAtLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        endsAtLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        endsAtLabel.textAlignment = .center
        endsAtLabel.isHidden = false

        endsAtTrailingConstraint.isActive = false
        endsAtPlayheadConstraint.constant = trackBackground.bounds.width * CGFloat(elapsed / duration)
        endsAtPlayheadConstraint.isActive = true
    }

    /// Loading placeholder: keeps the locked geometry and vertical rhythm
    /// while playback starts. update(...) is a no-op while on.
    func setSkeleton(_ on: Bool) {
        guard on != isSkeleton else { return }
        isSkeleton = on
        if !on { snapNextUpdate = true }
        trackBackground.backgroundColor = UIColor.white.withAlphaComponent(on ? 0.08 : 0.16)
        progressFill.isHidden = on
        handleView.isHidden = on
        handleRing.isHidden = on
        endsAtLabel.isHidden = on || duration <= 0
        markersContainer.isHidden = on
        let skeletonColor = UIColor.white.withAlphaComponent(0.22)
        if on {
            currentTimeLabel.text = "--:--"
            remainingTimeLabel.text = "--:--"
            currentTimeLabel.textColor = skeletonColor
            remainingTimeLabel.textColor = skeletonColor
            addSkeletonShimmer()
        } else {
            currentTimeLabel.textColor = UIColor.white.withAlphaComponent(0.82)
            remainingTimeLabel.textColor = UIColor.white.withAlphaComponent(0.55)
            removeSkeletonShimmer()
        }
    }

    /// Dedicated-layer shimmer sanctioned outside the one-clock rule: the
    /// skeleton never coexists with scrubbing (`update(...)` guards on
    /// `isSkeleton` as its very first line), so this `CAGradientLayer` +
    /// `CABasicAnimation` never competes with the UIView-animation clock
    /// that drives `update(...)`. Masked to `trackBackground`'s rounded
    /// bounds so the shimmer stays inside the track.
    private static let shimmerAnimationKey = "skeletonShimmer"
    private var shimmerLayer: CAGradientLayer?

    private func addSkeletonShimmer() {
        removeSkeletonShimmer()
        let layer = CAGradientLayer()
        layer.colors = [UIColor.clear.cgColor,
                        UIColor.white.withAlphaComponent(0.22).cgColor,
                        UIColor.clear.cgColor]
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.locations = [-0.4, -0.2, 0]
        layer.frame = trackBackground.bounds
        trackBackground.layer.addSublayer(layer)
        shimmerLayer = layer

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.4, -0.2, 0] as [NSNumber]
        animation.toValue = [1, 1.2, 1.4] as [NSNumber]
        animation.duration = 1.8
        animation.repeatCount = .infinity
        layer.add(animation, forKey: Self.shimmerAnimationKey)
    }

    private func removeSkeletonShimmer() {
        guard let layer = shimmerLayer else { return }
        layer.removeAnimation(forKey: Self.shimmerAnimationKey)
        layer.removeFromSuperlayer()
        shimmerLayer = nil
    }

    /// Paused presentation: the accent fill dims while paused (2a spec).
    /// Applied immediately here (not via `update(...)`) because time ticks
    /// stop while the player is paused, so no later `update(...)` would
    /// pick up the change. The immediate setter only runs while not
    /// scrubbing and no skeleton, so it never races `update(...)`'s own
    /// animate block or the skeleton's own fill handling (one-clock rule).
    /// Skips the knob shrink while `focusEmphasis` is active — focused wins
    /// over paused-at-rest, same priority rule as `update(...)`'s
    /// `scrubEmphasis`/`pausedAtRest`.
    func setPausedDim(_ dimmed: Bool) {
        guard dimmed != isPausedDim else { return }
        isPausedDim = dimmed
        guard !isSkeleton, !isScrubbing else { return }
        let dimmedAndUnfocused = dimmed && !focusEmphasis
        UIView.animate(withDuration: 0.25) {
            self.progressFill.alpha = dimmedAndUnfocused ? 0.78 : 1
            let handleDiameter: CGFloat = dimmedAndUnfocused ? 22 : 26
            let handleSize = CGSize(width: handleDiameter, height: handleDiameter)
            let center = CGPoint(x: self.handleView.frame.midX, y: self.handleView.frame.midY)
            self.handleView.frame = CGRect(x: center.x - handleSize.width / 2, y: center.y - handleSize.height / 2,
                                           width: handleSize.width, height: handleSize.height)
            self.handleView.layer.cornerRadius = handleSize.width / 2
            let ringInset: CGFloat = 6
            self.handleRing.frame = self.handleView.frame.insetBy(dx: -ringInset, dy: -ringInset)
            self.handleRing.layer.cornerRadius = self.handleRing.frame.width / 2
            self.handleRing.backgroundColor = UIColor.white.withAlphaComponent(dimmedAndUnfocused ? 0 : 0.14)
        }
    }

    /// Focus emphasis: the scrubber focus proxy (`ScrubberFocusProxyView`
    /// in PlayerContainerViewController) reports focus gain/loss here.
    /// Applied immediately (not via `update(...)`) because focus can
    /// change while time ticks are stopped (paused, or between ticks) —
    /// same immediate-apply idiom as `setPausedDim`, same 0.15s duration as
    /// `update(...)`'s own animate block (this is the sanctioned same-clock
    /// idiom, not a new animation system: both this method and `update(...)`
    /// only ever touch the fill/handle/ring properties that the OTHER one
    /// also owns, on the same `UIView.animate` mechanism, never overlapping
    /// in time since each is a discrete, guarded, one-shot call).
    /// Skipped while scrubbing or skeleton — `update(...)`'s own emphasis
    /// computation (`scrubEmphasis`, which folds in `focusEmphasis`) already
    /// owns the knob/track in those states, and the proxy cannot hold focus
    /// while scrubbing (mutually exclusive gating), so this guard is belt
    /// and suspenders, not a real race.
    func setFocusEmphasis(_ focused: Bool) {
        guard focused != focusEmphasis else { return }
        focusEmphasis = focused
        guard !isScrubbing, !isSkeleton else { return }

        // scrubEmphasis reduces to plain focusEmphasis here (guarded above:
        // !isScrubbing) — kept as the same-named local as update(...) for
        // parallel reading.
        let scrubEmphasis = focusEmphasis
        let pausedAtRest = isPausedDim && !focusEmphasis
        trackHeightConstraint.constant = scrubEmphasis ? Metrics.scrubTrackHeight : Metrics.trackHeight

        UIView.animate(withDuration: 0.15) {
            let handleDiameter: CGFloat = scrubEmphasis ? 32 : (pausedAtRest ? 22 : 26)
            let handleSize = CGSize(width: handleDiameter, height: handleDiameter)
            let center = CGPoint(x: self.handleView.frame.midX, y: self.handleView.frame.midY)
            self.handleView.frame = CGRect(x: center.x - handleSize.width / 2, y: center.y - handleSize.height / 2,
                                           width: handleSize.width, height: handleSize.height)
            self.handleView.layer.cornerRadius = handleSize.width / 2
            let ringInset: CGFloat = 6
            self.handleRing.frame = self.handleView.frame.insetBy(dx: -ringInset, dy: -ringInset)
            self.handleRing.layer.cornerRadius = self.handleRing.frame.width / 2
            self.handleRing.backgroundColor = UIColor.white.withAlphaComponent(
                scrubEmphasis ? 0.35 : (pausedAtRest ? 0 : 0.14)
            )
            self.progressFill.alpha = pausedAtRest ? 0.78 : 1
            self.layoutIfNeeded()
        }
    }

    /// Tracked purely so `update(...)` can detect the scrub-start/scrub-
    /// end edge without adding a parameter to every call site.
    private var isScrubbing = false

    // MARK: - Filmstrip reset

    /// Clears cached per-item state (chapters, thumb image) so the next
    /// scrub rebuilds from scratch. Must be called whenever the view model
    /// swaps to a different playable item (e.g. auto-advancing to the next
    /// episode) on this same, reused `PlayerProgressBarView` instance —
    /// otherwise the previous title's last thumbnail frame or chapter
    /// eyebrow would show briefly on the next scrub. Safe to call
    /// mid-scrub: the readout/thumb/wheel indicator are hidden back to the
    /// rest state so nothing is left showing stale content.
    func resetFilmstrip() {
        lastChapters = []

        // Drop the last title's thumbnail frame so a stale image can't
        // flash before the next scrub's first `scrubThumbnail` lands.
        thumbnailImageView.image = nil

        readoutContainer.isHidden = true
        readoutContainer.alpha = 0
        thumbnailContainer.isHidden = true
        thumbnailContainer.alpha = 0
        wheelRing.isHidden = true
        wheelDot.isHidden = true
        currentPositionGhost.isHidden = !isScrubbing
        renderMarkers(lastMarkers, duration: duration, trackWidth: trackBackground.bounds.width,
                      trackHeight: trackHeightConstraint.constant)
    }

    private func layoutScrubOverlay(progress: Double, width: CGFloat) {
        let displayTime = duration > 0 ? Double(progress) * duration : 0
        let playheadX = width * CGFloat(progress)

        // Oversized readout: eyebrow (chapter name, hidden when the
        // playhead isn't inside a named chapter) + large timecode, clamped
        // fully on-screen.
        let eyebrowText = chapterEyebrowText(at: displayTime)
        readoutEyebrowLabel.isHidden = eyebrowText == nil
        if let eyebrowText {
            readoutEyebrowLabel.attributedText = NSAttributedString(
                string: eyebrowText,
                attributes: [.kern: 16 * 0.12]
            )
        }
        readoutTimecodeLabel.text = Self.formatTime(displayTime)

        readoutEyebrowLabel.sizeToFit()
        readoutTimecodeLabel.sizeToFit()
        let readoutWidth = max(readoutEyebrowLabel.bounds.width, readoutTimecodeLabel.bounds.width)
        let readoutSpacing: CGFloat = readoutEyebrowLabel.isHidden ? 0 : 4
        let readoutHeight = (readoutEyebrowLabel.isHidden ? 0 : readoutEyebrowLabel.bounds.height + readoutSpacing)
            + readoutTimecodeLabel.bounds.height
        readoutContainer.bounds = CGRect(x: 0, y: 0, width: readoutWidth, height: readoutHeight)

        readoutEyebrowLabel.center = CGPoint(x: readoutWidth / 2, y: readoutEyebrowLabel.bounds.height / 2)
        readoutTimecodeLabel.center = CGPoint(
            x: readoutWidth / 2,
            y: readoutHeight - readoutTimecodeLabel.bounds.height / 2
        )

        // Readout sits ~12pt above the bar's own rest geometry (never
        // moves — the bar itself no longer changes position while
        // scrubbing), clamped fully inside the bar's horizontal bounds.
        let halfReadout = readoutWidth / 2
        let clampedCenter = min(max(playheadX, halfReadout), max(halfReadout, width - halfReadout))
        readoutContainer.center = CGPoint(x: clampedCenter, y: trackBackground.frame.minY - Metrics.thumbnailGap - readoutHeight / 2)

        // Trickplay thumb card: stacked above the readout with a 12pt gap
        // (the two must never overlap), centered on the seek x and
        // clamped so it never crosses the bar's own horizontal bounds (a
        // separate, wider clamp than the readout's — the card is narrower
        // than most readout widths but shouldn't inherit the readout's
        // clamp, which is sized to the readout's own text).
        let halfThumb = Metrics.thumbnailWidth / 2
        let thumbCenterX = min(max(playheadX, halfThumb), max(halfThumb, width - halfThumb))
        let thumbCenterY = readoutContainer.frame.minY - Metrics.thumbnailReadoutGap - Metrics.thumbnailHeight / 2
        thumbnailContainer.bounds = CGRect(x: 0, y: 0, width: Metrics.thumbnailWidth, height: Metrics.thumbnailHeight)
        thumbnailContainer.center = CGPoint(x: thumbCenterX, y: thumbCenterY)
        // Explicit shadowPath: without one, CA rasterizes the shadow
        // offscreen on every frame the card moves while scrubbing.
        thumbnailContainer.layer.shadowPath = UIBezierPath(
            roundedRect: thumbnailContainer.bounds, cornerRadius: 14).cgPath

        layoutWheelIndicator(progress: progress, calloutCenter: readoutContainer.center, calloutHalfWidth: halfReadout, width: width)
    }

    /// "CHAPTER n · NAME" for the chapter containing `time` (n = 1-based
    /// ordinal, NAME uppercased), or `nil` when there's no chapter at that
    /// time or the chapter has no name — the readout's eyebrow hides in
    /// that case, matching the old chip's suffix-less fallback.
    private func chapterEyebrowText(at time: TimeInterval) -> String? {
        for (index, chapter) in lastChapters.enumerated() {
            guard let startMs = chapter.startTimeOffset else { continue }
            let start = TimeInterval(startMs) / 1000.0
            let end = chapter.endTimeOffset.map { TimeInterval($0) / 1000.0 } ?? duration
            guard time >= start && time < end else { continue }
            guard let tag = chapter.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
                return nil
            }
            return "CHAPTER \(index + 1) · \(tag.uppercased())"
        }
        return nil
    }

    /// Positions the 44pt ring + orbiting 6pt dot beside the readout while
    /// a circular clickpad rotation is driving the scrub. The ring sits to
    /// the right of the readout (or the left, clamped inside the track
    /// bounds, if the readout is pinned to the right edge). The dot orbits
    /// the ring center at `angle = progress * 4 * .pi` — two full laps
    /// across the track — so it visibly advances with scrub progress
    /// rather than just sitting at a fixed rest position.
    private func layoutWheelIndicator(progress: Double, calloutCenter: CGPoint, calloutHalfWidth: CGFloat, width: CGFloat) {
        guard isWheelScrubbing else { return }

        let ringRadius = Metrics.wheelRingDiameter / 2
        let preferredCenterX = calloutCenter.x + calloutHalfWidth + Metrics.wheelRingGap + ringRadius
        let ringCenterX: CGFloat
        if preferredCenterX + ringRadius > width {
            // Callout is pinned near the right edge; place the ring on
            // its left side instead so it stays on-screen.
            ringCenterX = calloutCenter.x - calloutHalfWidth - Metrics.wheelRingGap - ringRadius
        } else {
            ringCenterX = preferredCenterX
        }
        let ringCenter = CGPoint(x: ringCenterX, y: calloutCenter.y)

        wheelRing.frame = CGRect(
            x: ringCenter.x - ringRadius,
            y: ringCenter.y - ringRadius,
            width: Metrics.wheelRingDiameter,
            height: Metrics.wheelRingDiameter
        )

        let angle = CGFloat(progress) * 4 * .pi
        let dotRadius = Metrics.wheelDotDiameter / 2
        let dotCenter = CGPoint(
            x: ringCenter.x + sin(angle) * ringRadius,
            y: ringCenter.y - cos(angle) * ringRadius
        )
        wheelDot.frame = CGRect(
            x: dotCenter.x - dotRadius,
            y: dotCenter.y - dotRadius,
            width: Metrics.wheelDotDiameter,
            height: Metrics.wheelDotDiameter
        )
    }

    private func renderMarkers(_ markers: [PlexMarker], duration: TimeInterval, trackWidth: CGFloat, trackHeight: CGFloat) {
        markersContainer.subviews.forEach { $0.removeFromSuperview() }
        guard duration > 0 else { return }

        for marker in markers {
            let startProgress = max(0, marker.startTimeSeconds / duration)
            let endProgress = min(1, marker.endTimeSeconds / duration)
            guard endProgress > startProgress else { continue }

            let markerView = UIView()
            markerView.backgroundColor = Self.color(for: marker).withAlphaComponent(0.85)
            let x = trackWidth * CGFloat(startProgress)
            let markerWidth = max(4, trackWidth * CGFloat(endProgress - startProgress))
            markerView.frame = CGRect(x: x, y: 0, width: markerWidth, height: trackHeight)
            markersContainer.addSubview(markerView)
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
