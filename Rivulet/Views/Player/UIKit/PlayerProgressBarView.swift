// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerProgressBarView.swift
//  Rivulet
//
//  Transport bar cloned from AVPlayerViewController's tvOS 26 scrubber. Every
//  metric was read from AVKit's live view tree on a 1080p simulator (DEBUG
//  `AVKitScrubProbe`, RIVULET_SCRUBPROBE=states). The track's center line is
//  fixed and the track grows around it (14 rest, 18 scrubbing, 20 ring jog);
//  labels, needle, ring and thumbnail are laid out from that line.
//
//  Frame-driven. A state change (scrub, ring) animates on AVKit's measured
//  spring; time ticks use a short linear move. One animator per call.
//

import UIKit

final class PlayerProgressBarView: UIView {

    // MARK: - Metrics (AVKit tvOS 26, 1080p)

    private enum Metrics {
        static let restHeight: CGFloat = 14
        static let scrubHeight: CGFloat = 18
        static let ringHeight: CGFloat = 20
        /// Track center below the view's top; the tallest track starts at 0.
        static let centerY: CGFloat = 10
        static let viewHeight: CGFloat = 72
        /// Labels sit this far below the track; in ring mode, this far below its center.
        static let labelGap: CGFloat = 8
        static let ringLabelOffset: CGFloat = 33
        static let remainingInset: CGFloat = 3
        static let glyphGap: CGFloat = 10
        /// Scan level number beside its glyph.
        static let scanNumberGap: CGFloat = 8
        /// AVKit's scan and skip glyph frames (symbol pointSize 29 semibold).
        static let circleGlyph = CGSize(width: 36, height: 36)
        static let skipGlyph = CGSize(width: 36, height: 39)
        static let marker = CGSize(width: 2, height: 17)
        static let thumbnail = CGSize(width: 400, height: 225)
        static let thumbnailRadius: CGFloat = 16
        /// Thumbnail bottom above the track center while scrubbing / ring jogging.
        static let thumbnailLift: CGFloat = 31
        static let ringThumbnailLift: CGFloat = 44
        /// Scrub needle bottom below the track center.
        static let needleDrop: CGFloat = 11
        static let ring: CGFloat = 52
        static let ringBand: CGFloat = 10
        static let ringPointer: CGFloat = 18
        static let ringDot: CGFloat = 7
        static let ringDotOrbit: CGFloat = 21
        static let ringHole: CGFloat = 32
        static let elapsedRing: CGFloat = 20
        static let eyebrowGap: CGFloat = 8
    }

    /// AVKit's transport bar spring (mass 1, stiffness 380, damping 29).
    private static func stateSpring() -> UIViewPropertyAnimator {
        let spring = UISpringTimingParameters(mass: 1, stiffness: 380, damping: 29, initialVelocity: .zero)
        return UIViewPropertyAnimator(duration: 0.528, timingParameters: spring)
    }

    // Track composite fitted to AVKit's pixels: its material reads as this gray
    // over any video, and the elapsed fill is white 0.45 on top of it.
    private static let trackColor = UIColor(white: 0.352, alpha: 0.398)
    /// AVKit's bar with focus elsewhere: fill hidden, track and time labels dimmed.
    private static let dimmedTrackColor = UIColor(white: 0.331, alpha: 0.213)
    private static let dimmedLabelColor = UIColor.white.withAlphaComponent(0.5)
    private static let skeletonTrackColor = UIColor.white.withAlphaComponent(0.08)
    private static let fillColor = UIColor.white.withAlphaComponent(0.45)
    private static let ghostColor = UIColor.white.withAlphaComponent(0.2)
    private static let labelColor = UIColor.white
    private static let skeletonColor = UIColor.white.withAlphaComponent(0.22)

    /// AVKit's time label font (`.SFUI-Bold` 23pt, tabular digits).
    private static let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 23, weight: .bold)

    /// Soft tints that sit with the white fill and glass track.
    static func color(for marker: PlexMarker) -> UIColor {
        if marker.isIntro {
            return UIColor(red: 0.58, green: 0.72, blue: 1.0, alpha: 0.5)
        } else if marker.isCredits {
            return UIColor(red: 0.78, green: 0.66, blue: 1.0, alpha: 0.5)
        } else {
            return UIColor(red: 1.0, green: 0.86, blue: 0.52, alpha: 0.5)
        }
    }

    // MARK: - Subviews

    private let track = UIView()
    private let ghost = UIView()
    private let fill = UIView()
    private let markersContainer = UIView()
    private let edgeHighlight = TrackEdgeHighlightView()
    private let trackMask = CAShapeLayer()
    private let playheadMarker = UIView()
    private let scrubNeedle = UIView()
    /// Follows the playhead: elapsed time (VOD) or clock time (live).
    private let elapsedLabel = UILabel()
    /// Live only: programme start at the left end.
    private let leadingLabel = UILabel()
    private let remainingLabel = UILabel()
    private let pauseGlyph = UIImageView()
    /// Scan (forward.circle / backward.circle) or skip (goforward.10) glyph.
    private let indicatorGlyph = UIImageView()
    /// Scan level from 2 up, beside the scan glyph.
    private let scanLevelLabel = UILabel()
    private let thumbnailContainer = UIView()
    private let thumbnailImageView = UIImageView()
    private let eyebrowLabel = UILabel()
    private let ringView = UIView()
    private let ringBand = UIView()
    private let ringPointer = UIView()
    private let ringDot = UIView()
    /// Ring mode marks where playback is with a hollow circle.
    private let elapsedRing = UIView()

    // MARK: - State

    private struct Labels: Equatable {
        var elapsed: String
        var remaining: String
        var leading: String?
    }

    private var currentTime: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var scrubTime: TimeInterval = 0
    private var isScrubbing = false
    private var isWheelScrubbing = false
    private var ghostProgress: Double?
    private var labels = Labels(elapsed: "", remaining: "")
    private var lastChapters: [PlexChapter] = []
    private var lastMarkers: [PlexMarker] = []
    /// Where the jogging finger sits on the wheel, in clockwise turns from 12
    /// o'clock. The ring's dot follows the finger, as AVKit's does.
    private var ringFingerTurns = 0.0
    private var isFocusDimmed = false
    /// Signed shuttle level while scanning; 0 when not.
    private var scanLevel = 0
    private var skipIndicator: SeekIndicator?
    /// Side the indicator glyph was last placed on.
    private var indicatorForward: Bool?
    private var skipClear: DispatchWorkItem?
    private var isSkeleton = false
    /// The first fill position after loading jumps into place instead of sweeping.
    private var snapNextUpdate = false
    private var isPaused = false
    private var isLive = false

    private static let clockFormatter: DateFormatter = {
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

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.viewHeight)
    }

    private func setupViews() {
        clipsToBounds = false

        track.clipsToBounds = true
        ghost.backgroundColor = Self.ghostColor
        ghost.isHidden = true
        fill.backgroundColor = Self.fillColor
        edgeHighlight.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        markersContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        [ghost, fill, markersContainer, edgeHighlight].forEach { track.addSubview($0) }
        trackMask.fillRule = .evenOdd

        styleNeedle(playheadMarker)
        styleNeedle(scrubNeedle)

        for label in [elapsedLabel, leadingLabel, remainingLabel, scanLevelLabel] {
            label.font = Self.timeFont
            Self.applyLabelShadow(label.layer)
        }
        leadingLabel.isHidden = true
        scanLevelLabel.alpha = 0

        pauseGlyph.image = UIImage(systemName: "pause.circle",
                                   withConfiguration: UIImage.SymbolConfiguration(font: Self.timeFont, scale: .large))
        pauseGlyph.alpha = 0
        Self.applyLabelShadow(pauseGlyph.layer)
        indicatorGlyph.contentMode = .center
        indicatorGlyph.alpha = 0
        Self.applyLabelShadow(indicatorGlyph.layer)
        applyAppearanceColors()

        thumbnailContainer.bounds.size = Metrics.thumbnail
        thumbnailContainer.alpha = 0
        thumbnailContainer.layer.cornerRadius = Metrics.thumbnailRadius
        thumbnailContainer.layer.cornerCurve = .continuous
        thumbnailContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        thumbnailContainer.layer.borderWidth = 1
        thumbnailContainer.layer.shadowColor = UIColor.black.cgColor
        thumbnailContainer.layer.shadowOpacity = 0.3
        thumbnailContainer.layer.shadowRadius = 40
        thumbnailContainer.layer.shadowOffset = CGSize(width: 0, height: 12)
        thumbnailContainer.layer.shadowPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: Metrics.thumbnail), cornerRadius: Metrics.thumbnailRadius).cgPath
        thumbnailImageView.frame = CGRect(origin: .zero, size: Metrics.thumbnail)
        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true
        thumbnailImageView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        thumbnailImageView.layer.cornerRadius = Metrics.thumbnailRadius
        thumbnailImageView.layer.cornerCurve = .continuous
        thumbnailContainer.addSubview(thumbnailImageView)

        eyebrowLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        eyebrowLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        eyebrowLabel.textAlignment = .center
        eyebrowLabel.alpha = 0
        Self.applyLabelShadow(eyebrowLabel.layer)

        // Ring jog: AVWheelScrubberView's three views, measured.
        ringView.bounds.size = CGSize(width: Metrics.ring, height: Metrics.ring)
        ringView.alpha = 0
        ringBand.frame = ringView.bounds
        ringBand.layer.cornerRadius = Metrics.ring / 2
        ringBand.layer.borderWidth = Metrics.ringBand
        ringBand.layer.borderColor = UIColor.white.cgColor
        ringBand.layer.shadowColor = UIColor.black.cgColor
        ringBand.layer.shadowOpacity = 0.2
        ringBand.layer.shadowRadius = 2
        ringBand.layer.shadowOffset = .zero
        ringPointer.bounds.size = CGSize(width: Metrics.ringPointer, height: Metrics.ringPointer)
        ringPointer.center = CGPoint(x: Metrics.ring / 2, y: Metrics.ring / 2)
        ringPointer.backgroundColor = .white
        ringPointer.layer.cornerRadius = Metrics.ringPointer / 2
        ringDot.bounds.size = CGSize(width: Metrics.ringDot, height: Metrics.ringDot)
        ringDot.backgroundColor = .black
        ringDot.layer.cornerRadius = Metrics.ringDot / 2
        [ringBand, ringPointer, ringDot].forEach { ringView.addSubview($0) }

        elapsedRing.bounds.size = CGSize(width: Metrics.elapsedRing, height: Metrics.elapsedRing)
        elapsedRing.layer.cornerRadius = Metrics.elapsedRing / 2
        elapsedRing.layer.borderWidth = 2
        elapsedRing.layer.borderColor = UIColor.white.cgColor
        elapsedRing.alpha = 0

        [track, elapsedRing, playheadMarker, scrubNeedle, ringView, thumbnailContainer, eyebrowLabel,
         elapsedLabel, leadingLabel, remainingLabel, pauseGlyph, indicatorGlyph, scanLevelLabel].forEach { addSubview($0) }
    }

    private func styleNeedle(_ view: UIView) {
        view.backgroundColor = .white
        view.layer.cornerRadius = 1
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.2
        view.layer.shadowRadius = 2
        view.layer.shadowOffset = .zero
    }

    private static func applyLabelShadow(_ layer: CALayer) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBar()
        if let shimmerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shimmerLayer.frame = track.bounds
            CATransaction.commit()
        }
    }

    // MARK: - Update

    func update(
        currentTime: TimeInterval,
        duration: TimeInterval,
        isScrubbing: Bool,
        scrubTime: TimeInterval,
        scanLevel: Int = 0,
        scrubThumbnail: UIImage?,
        markers: [PlexMarker],
        chapters: [PlexChapter],
        isWheelScrubbing: Bool = false
    ) {
        isLive = false
        let displayTime = isScrubbing ? scrubTime : currentTime
        render(
            currentTime: currentTime, duration: duration, isScrubbing: isScrubbing, scrubTime: scrubTime,
            isWheelScrubbing: isWheelScrubbing,
            labels: vodLabels(displayTime: displayTime, duration: duration),
            ghostProgress: isScrubbing && duration > 0 ? currentTime / duration : nil,
            scanLevel: scanLevel, scrubThumbnail: scrubThumbnail,
            markers: markers, chapters: chapters
        )
    }

    /// Live TV: the programme's air window, labelled with clock times. Start at
    /// the left, end at the right, and the clock time of the picture on screen
    /// (or the scrub target) following the playhead.
    ///
    /// `liveEdgeTime` is "now" when timeshifted behind it; the buffered stretch
    /// up to it shows in the ghost. `scrubTime` puts a paused, timeshifted
    /// stream in scrub mode.
    func updateLiveTimeline(startTime: Date, currentTime: Date, endTime: Date, liveEdgeTime: Date? = nil,
                            scrubTime: Date? = nil, scrubThumbnail: UIImage? = nil) {
        let duration = endTime.timeIntervalSince(startTime)
        guard duration > 0 else { return }
        isLive = true
        func offset(_ date: Date) -> TimeInterval { min(max(0, date.timeIntervalSince(startTime)), duration) }
        var ghost: Double?
        if scrubTime == nil, let liveEdgeTime, liveEdgeTime.timeIntervalSince(currentTime) > 1 {
            ghost = offset(liveEdgeTime) / duration
        }
        render(
            currentTime: offset(currentTime), duration: duration, isScrubbing: scrubTime != nil,
            scrubTime: scrubTime.map(offset) ?? 0, isWheelScrubbing: false,
            labels: Labels(
                elapsed: Self.clockFormatter.string(from: scrubTime ?? currentTime),
                remaining: Self.clockFormatter.string(from: endTime),
                leading: Self.clockFormatter.string(from: startTime)
            ),
            ghostProgress: ghost, scanLevel: 0, scrubThumbnail: scrubThumbnail,
            markers: [], chapters: []
        )
    }

    private func render(
        currentTime: TimeInterval, duration: TimeInterval, isScrubbing: Bool, scrubTime: TimeInterval,
        isWheelScrubbing: Bool, labels: Labels, ghostProgress: Double?,
        scanLevel: Int, scrubThumbnail: UIImage?,
        markers: [PlexMarker], chapters: [PlexChapter]
    ) {
        guard !isSkeleton else { return }
        let ring = isWheelScrubbing && isScrubbing
        let stateChanged = isScrubbing != self.isScrubbing || ring != self.isWheelScrubbing

        self.currentTime = currentTime
        self.duration = duration
        self.scrubTime = scrubTime
        self.isScrubbing = isScrubbing
        self.isWheelScrubbing = ring
        self.ghostProgress = ghostProgress
        self.labels = labels
        self.lastMarkers = markers
        self.lastChapters = chapters
        if let scrubThumbnail { thumbnailImageView.image = scrubThumbnail }
        self.scanLevel = isScrubbing ? scanLevel : 0
        if isScrubbing { clearSkipIndicator() }

        // Startup reports time and duration separately, zeros first: keep
        // snapping until both are real, so the fill never sweeps up from 0.
        let snap = snapNextUpdate
        if duration > 0, currentTime > 0 { snapNextUpdate = false }
        if snap || window == nil {
            UIView.performWithoutAnimation { layoutBar() }
        } else if stateChanged {
            let animator = Self.stateSpring()
            animator.addAnimations { self.layoutBar() }
            animator.startAnimation()
        } else {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                self.layoutBar()
            }
        }
        renderMarkers()
    }

    /// Every frame in the bar, from the stored state. Runs inside the caller's animation.
    private func layoutBar() {
        let width = bounds.width
        guard width > 0 else { return }
        let ring = isWheelScrubbing
        let height = ring ? Metrics.ringHeight
            : (isScrubbing ? Metrics.scrubHeight : Metrics.restHeight)
        let centerY = Metrics.centerY
        let displayTime = isScrubbing ? scrubTime : currentTime
        let progress = duration > 0 ? min(1, max(0, displayTime / duration)) : 0
        let playheadX = width * CGFloat(progress)
        let currentX = width * CGFloat(duration > 0 ? min(1, max(0, currentTime / duration)) : 0)

        track.frame = CGRect(x: 0, y: centerY - height / 2, width: width, height: height)
        track.layer.cornerRadius = height / 2
        fill.frame = CGRect(x: 0, y: 0, width: playheadX, height: height)
        fill.alpha = isFocusDimmed ? 0 : 1
        ghost.alpha = isFocusDimmed ? 0 : 1
        ghost.isHidden = ghostProgress == nil
        ghost.frame = CGRect(x: 0, y: 0, width: width * CGFloat(ghostProgress ?? 0), height: height)
        updateTrackHoles(ring: ring, playheadX: playheadX, currentX: currentX)

        // Dimmed, AVKit's marker shrinks to a 1pt line inside the track.
        playheadMarker.frame = isFocusDimmed
            ? CGRect(x: playheadX - 1, y: centerY - Metrics.restHeight / 2, width: 1, height: Metrics.restHeight)
            : CGRect(x: playheadX - Metrics.marker.width / 2, y: centerY + 0.5 - Metrics.marker.height / 2,
                     width: Metrics.marker.width, height: Metrics.marker.height)
        playheadMarker.layer.cornerRadius = isFocusDimmed ? 0 : 1
        playheadMarker.alpha = isScrubbing ? 0 : 1

        let needleTop = centerY - (ring ? Metrics.ringThumbnailLift : Metrics.thumbnailLift)
        let needleBottom = ring ? centerY - Metrics.ring / 2 : centerY + Metrics.needleDrop
        scrubNeedle.frame = CGRect(x: playheadX - 1, y: needleTop, width: 2, height: needleBottom - needleTop)
        scrubNeedle.alpha = isScrubbing ? 1 : 0

        ringView.center = CGPoint(x: playheadX, y: centerY)
        ringView.alpha = ring ? 1 : 0
        let angle = CGFloat(ringFingerTurns * 2 * .pi)
        ringDot.center = CGPoint(x: Metrics.ring / 2 + sin(angle) * Metrics.ringDotOrbit,
                                 y: Metrics.ring / 2 - cos(angle) * Metrics.ringDotOrbit)
        elapsedRing.center = CGPoint(x: currentX, y: centerY)
        elapsedRing.alpha = ring ? 1 : 0

        let halfThumb = Metrics.thumbnail.width / 2
        let thumbX = min(max(playheadX, halfThumb), max(halfThumb, width - halfThumb))
        thumbnailContainer.center = CGPoint(x: thumbX, y: needleTop - Metrics.thumbnail.height / 2)
        thumbnailContainer.alpha = isScrubbing ? 1 : 0
        let eyebrow = isScrubbing ? chapterEyebrowText(at: displayTime) : nil
        if let eyebrow {
            eyebrowLabel.attributedText = NSAttributedString(string: eyebrow, attributes: [.kern: 16 * 0.12])
            eyebrowLabel.sizeToFit()
        }
        eyebrowLabel.center = CGPoint(
            x: thumbX, y: thumbnailContainer.frame.minY - Metrics.eyebrowGap - eyebrowLabel.bounds.height / 2)
        eyebrowLabel.alpha = eyebrow == nil ? 0 : 1

        layoutLabels(rowTop: ring ? centerY + Metrics.ringLabelOffset : centerY + height / 2 + Metrics.labelGap,
                     playheadX: playheadX, width: width, ring: ring)
    }

    private func layoutLabels(rowTop: CGFloat, playheadX: CGFloat, width: CGFloat, ring: Bool) {
        elapsedLabel.text = labels.elapsed
        remainingLabel.text = labels.remaining
        leadingLabel.text = labels.leading
        [elapsedLabel, remainingLabel, leadingLabel].forEach { $0.sizeToFit() }

        let half = elapsedLabel.bounds.width / 2 + Metrics.remainingInset
        let elapsedX = min(max(playheadX, half), max(half, width - half))
        elapsedLabel.center = CGPoint(x: elapsedX, y: rowTop + elapsedLabel.bounds.height / 2)
        let rowMidY = elapsedLabel.center.y

        remainingLabel.frame.origin = CGPoint(x: width - Metrics.remainingInset - remainingLabel.bounds.width, y: rowTop)
        leadingLabel.frame.origin = CGPoint(x: 0, y: rowTop)

        var trailingEdge = elapsedLabel.frame.maxX
        var leadingEdge = elapsedLabel.frame.minX
        // AVKit's indicator slot: a scan or skip glyph on the side it moves
        // toward, the scan level beyond it. It replaces the pause glyph.
        let indicator = ring ? nil : currentIndicator()
        let showGlyph = isPaused && !ring && !isLive && indicator == nil
        pauseGlyph.bounds.size = pauseGlyph.image?.size ?? .zero
        pauseGlyph.center = CGPoint(x: trailingEdge + Metrics.glyphGap + pauseGlyph.bounds.width / 2, y: rowMidY + 1)
        pauseGlyph.alpha = showGlyph ? 1 : 0
        if showGlyph { trailingEdge = pauseGlyph.frame.maxX }

        if let indicator {
            // A glyph coming in, or switching sides, is placed outright; the
            // caller's animation would otherwise slide it from its old spot.
            let flipped = indicatorForward != indicator.forward
            indicatorForward = indicator.forward
            let glyphAppearing = indicatorGlyph.alpha == 0 || flipped
            let levelAppearing = scanLevelLabel.alpha == 0 || flipped
            let glyphHalf = indicator.size.width / 2
            // Circle glyphs sit 1pt below the time's midline, numbered skip glyphs 0.5pt above.
            let midY = rowMidY + (indicator.size == Metrics.circleGlyph ? 1 : -0.5)
            if let level = indicator.level { scanLevelLabel.text = level; scanLevelLabel.sizeToFit() }
            let glyphCenter: CGPoint
            let levelOrigin: CGPoint
            if indicator.forward {
                glyphCenter = CGPoint(x: trailingEdge + Metrics.glyphGap + glyphHalf, y: midY)
                levelOrigin = CGPoint(x: glyphCenter.x + glyphHalf + Metrics.scanNumberGap, y: rowTop)
                trailingEdge = indicator.level == nil ? glyphCenter.x + glyphHalf : levelOrigin.x + scanLevelLabel.bounds.width
            } else {
                glyphCenter = CGPoint(x: leadingEdge - Metrics.glyphGap - glyphHalf, y: midY)
                leadingEdge = glyphCenter.x - glyphHalf
                levelOrigin = CGPoint(x: leadingEdge - Metrics.scanNumberGap - scanLevelLabel.bounds.width, y: rowTop)
            }
            let placeGlyph = {
                self.indicatorGlyph.image = UIImage(systemName: indicator.symbol, withConfiguration: Self.indicatorConfig)
                self.indicatorGlyph.bounds.size = indicator.size
                self.indicatorGlyph.center = glyphCenter
            }
            let placeLevel = { self.scanLevelLabel.frame.origin = levelOrigin }
            if glyphAppearing { UIView.performWithoutAnimation(placeGlyph) } else { placeGlyph() }
            if levelAppearing { UIView.performWithoutAnimation(placeLevel) } else { placeLevel() }
        }
        indicatorGlyph.alpha = indicator == nil ? 0 : 1
        scanLevelLabel.alpha = indicator?.level == nil ? 0 : 1

        // The playhead label wins; an end label it would overlap fades.
        let clearance: CGFloat = 12
        leadingLabel.isHidden = labels.leading == nil
        leadingLabel.alpha = leadingEdge < leadingLabel.frame.maxX + clearance ? 0 : 1
        remainingLabel.alpha = trailingEdge + clearance > remainingLabel.frame.minX ? 0 : 1
    }

    /// Ring mode punches the track out under the ring and the hollow playback marker.
    private func updateTrackHoles(ring: Bool, playheadX: CGFloat, currentX: CGFloat) {
        guard ring else {
            track.layer.mask = nil
            return
        }
        let path = UIBezierPath(rect: track.bounds.insetBy(dx: -Metrics.ring, dy: -Metrics.ring))
        let midY = track.bounds.midY
        for (x, diameter) in [(playheadX, Metrics.ringHole), (currentX, Metrics.elapsedRing)] {
            path.append(UIBezierPath(ovalIn: CGRect(x: x - diameter / 2, y: midY - diameter / 2,
                                                    width: diameter, height: diameter)))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackMask.frame = track.bounds
        trackMask.path = path.cgPath
        CATransaction.commit()
        track.layer.mask = trackMask
    }

    /// Loading placeholder: keeps the bar's geometry while playback starts. `update(...)` is a no-op while on.
    func setSkeleton(_ on: Bool) {
        guard on != isSkeleton else { return }
        isSkeleton = on
        if !on { snapNextUpdate = true }
        applyAppearanceColors()
        [fill, playheadMarker, markersContainer].forEach { $0.isHidden = on }
        if on {
            currentTime = 0
            ghostProgress = nil
            isScrubbing = false
            isWheelScrubbing = false
            labels = Labels(elapsed: "--:--", remaining: "--:--")
            layoutBar()
            addSkeletonShimmer()
        } else {
            removeSkeletonShimmer()
        }
    }

    /// Skeleton shimmer: its own layer animation, outside the one-clock rule
    /// because the skeleton never coexists with scrubbing.
    private static let shimmerAnimationKey = "skeletonShimmer"
    private var shimmerLayer: CAGradientLayer?

    private func addSkeletonShimmer() {
        removeSkeletonShimmer()
        let layer = CAGradientLayer()
        layer.colors = [UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.22).cgColor, UIColor.clear.cgColor]
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.locations = [-0.4, -0.2, 0]
        layer.frame = track.bounds
        track.layer.addSublayer(layer)
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

    /// Paused shows AVKit's pause glyph beside the elapsed time.
    func setPausedDim(_ dimmed: Bool) {
        guard dimmed != isPaused else { return }
        isPaused = dimmed
        guard !isSkeleton else { return }
        UIView.animate(withDuration: 0.15) { self.layoutBar() }
    }

    /// The jogging finger's wheel position; nil (finger off the ring) keeps the last.
    func setRingFinger(_ position: Double?) {
        if let position { ringFingerTurns = position }
    }

    /// AVKit's look with focus off the bar (on a tool button or pill): fill
    /// hidden, a thin marker, track and time dimmed.
    func setFocusDimmed(_ dimmed: Bool, coordinator: UIFocusAnimationCoordinator? = nil) {
        guard dimmed != isFocusDimmed else { return }
        isFocusDimmed = dimmed
        let apply = {
            self.applyAppearanceColors()
            if !self.isSkeleton { self.layoutBar() }
        }
        if let coordinator { coordinator.addCoordinatedAnimations(apply) } else { apply() }
    }

    /// AVKit's skip glyph beside the time: fades in over 0.17s and clears 2s
    /// after the press while paused, about 3.3s while playing (both measured).
    func showSkipIndicator(_ indicator: SeekIndicator) {
        skipClear?.cancel()
        let wasShowing = skipIndicator != nil
        skipIndicator = indicator
        guard !isSkeleton else { return }
        if wasShowing {
            UIView.performWithoutAnimation { layoutBar() }
        } else {
            indicatorGlyph.alpha = 0
            UIView.animate(withDuration: 0.17) { self.layoutBar() }
        }
        let clear = DispatchWorkItem { [weak self] in self?.clearSkipIndicator(animated: true) }
        skipClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + (isPaused ? 2 : 3.3), execute: clear)
    }

    func clearSkipIndicator(animated: Bool = false) {
        skipClear?.cancel()
        skipClear = nil
        guard skipIndicator != nil else { return }
        skipIndicator = nil
        guard !isSkeleton else { return }
        if animated {
            UIView.animate(withDuration: 0.17) { self.layoutBar() }
        } else {
            UIView.performWithoutAnimation { layoutBar() }
        }
    }

    private static let indicatorConfig = UIImage.SymbolConfiguration(pointSize: 29, weight: .semibold)

    private struct Indicator {
        let symbol: String
        let size: CGSize
        let forward: Bool
        let level: String?
    }

    /// Scanning wins over a skip; AVKit numbers scan levels from 2.
    private func currentIndicator() -> Indicator? {
        if scanLevel != 0 {
            let forward = scanLevel > 0
            return Indicator(symbol: forward ? "forward.circle" : "backward.circle", size: Metrics.circleGlyph,
                             forward: forward, level: abs(scanLevel) >= 2 ? "\(abs(scanLevel))" : nil)
        }
        guard let skipIndicator else { return nil }
        let forward = if case .forward = skipIndicator { true } else { false }
        return Indicator(symbol: skipIndicator.systemImage, size: Metrics.skipGlyph, forward: forward, level: nil)
    }

    private func applyAppearanceColors() {
        let text = isSkeleton ? Self.skeletonColor : (isFocusDimmed ? Self.dimmedLabelColor : Self.labelColor)
        [elapsedLabel, leadingLabel, remainingLabel, scanLevelLabel].forEach { $0.textColor = text }
        pauseGlyph.tintColor = text
        indicatorGlyph.tintColor = text
        track.backgroundColor = isSkeleton ? Self.skeletonTrackColor
            : (isFocusDimmed ? Self.dimmedTrackColor : Self.trackColor)
    }

    /// Clears per-item state so the next title's first scrub can't flash the
    /// previous title's thumbnail or chapter.
    func resetFilmstrip() {
        lastChapters = []
        thumbnailImageView.image = nil
        isScrubbing = false
        isWheelScrubbing = false
        UIView.performWithoutAnimation { layoutBar() }
        renderMarkers()
    }

    /// "CHAPTER n · NAME" for the chapter containing `time`, or nil.
    private func chapterEyebrowText(at time: TimeInterval) -> String? {
        for (index, chapter) in lastChapters.enumerated() {
            guard let startMs = chapter.startTimeOffset else { continue }
            let start = TimeInterval(startMs) / 1000.0
            let end = chapter.endTimeOffset.map { TimeInterval($0) / 1000.0 } ?? duration
            guard time >= start && time < end else { continue }
            guard let tag = chapter.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else { return nil }
            return "CHAPTER \(index + 1) · \(tag.uppercased())"
        }
        return nil
    }

    private func renderMarkers() {
        markersContainer.subviews.forEach { $0.removeFromSuperview() }
        let trackWidth = track.bounds.width
        guard duration > 0, trackWidth > 0 else { return }
        for marker in lastMarkers {
            let startProgress = max(0, marker.startTimeSeconds / duration)
            let endProgress = min(1, marker.endTimeSeconds / duration)
            guard endProgress > startProgress else { continue }
            let markerView = UIView()
            markerView.backgroundColor = Self.color(for: marker)
            markerView.autoresizingMask = [.flexibleHeight]
            let x = trackWidth * CGFloat(startProgress)
            let markerWidth = max(4, trackWidth * CGFloat(endProgress - startProgress))
            markerView.frame = CGRect(x: x, y: 0, width: markerWidth, height: markersContainer.bounds.height)
            markersContainer.addSubview(markerView)
        }
    }

    // MARK: - Clock times

    /// VOD labels read the time of day instead: now, and when the title ends
    /// from the playhead. The toggle is the touch-surface tap.
    private(set) var showsClockTimes = false
    private var clockTick: Timer?

    func setShowsClockTimes(_ on: Bool) {
        guard on != showsClockTimes else { return }
        showsClockTimes = on
        updateClockTick()
        refreshClockLabels()
    }

    private func vodLabels(displayTime: TimeInterval, duration: TimeInterval) -> Labels {
        let remaining = max(0, duration - displayTime)
        guard showsClockTimes else {
            return Labels(elapsed: Self.formatTime(displayTime), remaining: "-\(Self.formatTime(remaining))")
        }
        let now = Date()
        return Labels(elapsed: Self.clockFormatter.string(from: now),
                      remaining: Self.clockFormatter.string(from: now.addingTimeInterval(remaining)))
    }

    /// Paused, no time ticks arrive, so the clock and the end time go stale
    /// without this.
    private func updateClockTick() {
        clockTick?.invalidate()
        clockTick = nil
        guard showsClockTimes, window != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClockLabels() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTick = timer
    }

    private func refreshClockLabels() {
        guard !isLive, !isSkeleton else { return }
        let next = vodLabels(displayTime: isScrubbing ? scrubTime : currentTime, duration: duration)
        guard next != labels else { return }
        labels = next
        UIView.performWithoutAnimation { layoutBar() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateClockTick()
    }

    /// AVKit's format: "09:46" under an hour, "1:02:03" over.
    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

/// AVKit's track has a faint bright rim, strongest at the top edge (fitted to its
/// pixels). Stops are in points so the rim keeps its thickness as the track grows.
private final class TrackEdgeHighlightView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let white = UIColor.white
        (layer as? CAGradientLayer)?.colors = [
            white.withAlphaComponent(0.33).cgColor, white.withAlphaComponent(0).cgColor,
            white.withAlphaComponent(0).cgColor, white.withAlphaComponent(0.13).cgColor,
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = Double(max(bounds.height, 6))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (layer as? CAGradientLayer)?.locations = [0, NSNumber(value: 2.5 / h), NSNumber(value: 1 - 1.8 / h), 1]
        CATransaction.commit()
    }
}
