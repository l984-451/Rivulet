// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CaptionOverlayView.swift
//  Rivulet
//
//  UIKit caption overlay. Renders the cues in `SubtitleModel` (text, styled
//  text, and PGS/DVB bitmaps) for both the Aether VOD player and Live TV.
//  Mounted as a plain subview above the video surface and below the chrome by
//  PlayerContainerViewController and LiveTVAetherPlayerViewController.
//
//  Sizing and placement mirror AVPlayer's own caption rendering:
//  - point size = a fraction of the PRESENTATION height x the system's
//    relative-character-size multiplier
//  - the resting bottom margin is a fraction of the PICTURE height, so a
//    letterboxed film is captioned on the image, not in its black bar
//  - with the rail up, the same margin is measured off the rail's top edge
//    instead, so the caption keeps its distance either way
//
//  There is a margin FLOOR every cue obeys (`placementFloor`), including one
//  that positioned itself: a cue placed into the rail is lifted clear of it.
//  There is a matching no-go zone at each side (`sideSafeFraction`), because
//  AVPlayer will not draw to the picture edge either.
//
//  Within those, a cue that gave an exact position keeps it. Vertically the
//  position names the box's TOP edge (WebVTT's default `line-align: start`),
//  so the box hangs down from it, which is where AVPlayer draws it.
//  Horizontally the cue's own left/centre/right alignment decides which box
//  edge the position names. A cue that gave only a coarse band (teletext)
//  takes that band's resting anchor instead.
//
//  Only the user's Height stepper is placement-exempt.
//
//  This replaced a SwiftUI implementation. Two things it had to fake are real
//  here: the outline is one stroked draw rather than eight offset copies of
//  the string, and the box is MEASURED rather than estimated, so the top-edge
//  anchor and the floor clamp are exact for a multi-line cue instead of
//  approximate.
//

import Combine
import UIKit

// MARK: - CaptionOverlayView

final class CaptionOverlayView: UIView {

    // MARK: Inputs

    /// Current caption appearance. Replaced wholesale on CaptionAppearance changes.
    var style: CaptionStyle {
        didSet {
            guard style != oldValue else { return }
            rebuildCueViews()
        }
    }

    /// True when the player rail is visible; lifts text above it. The host
    /// changes this inside its own chrome animation block, so the lift rides
    /// the same clock as the rail's fade.
    var controlsVisible: Bool {
        didSet {
            guard controlsVisible != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// The video's presentation size (`AetherPlayer.videoSize`). `.zero` means
    /// "unknown" — the overlay then measures against its full bounds, which is
    /// correct for a 16:9 picture filling the screen.
    var videoSize: CGSize {
        didSet {
            guard videoSize != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Height adjustment for THIS media, in stepper units. Sticky per title /
    /// channel like the delay stepper, and applying to the default band only.
    var heightUnits: Int {
        didSet {
            guard heightUnits != oldValue else { return }
            setNeedsLayout()
        }
    }

    // MARK: Metrics
    //
    // Tuned against AVPlayer's own caption rendering (screenshot comparison at
    // the smallest system caption size). Three differences mattered: Apple
    // sizes type from the VIDEO height rather than a fixed point size, boxes
    // the text tightly, and draws one background per cue rather than per line.

    enum Metrics {

        /// Caption size as a fraction of the PRESENTATION height, for each value
        /// the system can report. MEASURED against AVKit, not derived.
        ///
        /// `MACaptionAppearanceGetRelativeCharacterSize` is not a multiplier you
        /// can multiply by. It reports one of five quantised values, and AVKit's
        /// own size does NOT scale linearly with them — a plain multiply is
        /// ~11% short at every setting except the default:
        ///
        ///     reported   AVKit @1080   ratio    a linear multiply would give
        ///       0.35        18.5pt     0.40x                0.35x
        ///       0.6         31.0pt     0.67x                0.6x
        ///       1.0         46.2pt     1.00x                1.0x
        ///       1.5         78.0pt     1.69x                1.5x
        ///       2.0        104.1pt     2.25x                2.0x
        ///
        /// Method (tvOS 26.5 simulator): an AVPlayerViewController playing a
        /// plain black HLS stream with a fixed WebVTT cue, with reference glyphs
        /// of the same vertical extremes drawn at known point sizes through the
        /// same MediaAccessibility font descriptor; ink heights compared in one
        /// screenshot. Sizes off the ladder were reached by writing
        /// `MACaptionCharScale` into injected caption profiles.
        ///
        /// This was a single `0.0529` multiplier from `9f4acd3` (shipped
        /// v1.0.4-74), giving 57.1pt at the default: **24% oversized**, issue
        /// #299. The note behind it claimed a match at "the smallest caption
        /// size", where the API reports 0.35 — but 0.35 is the smallest BUCKET,
        /// and the same commit widened `CaptionAppearance.fontScale`'s clamp
        /// from 0.5 to 0.25, so at that one value the two changes cancelled to
        /// within a point. It was calibrated at the only place in the range that
        /// could not reveal the regression. **Measure both ends.**
        ///
        /// Deliberately NOT the letterboxed picture height: AVKit sizes captions
        /// from the presentation and only *positions* them against the picture,
        /// so a 2.39:1 film gets the same type as a 16:9 one rather than
        /// shrunken type. Verified by shrinking the player view to 960x540, at
        /// which AVKit's captions halve — they follow the VIEW, not the video's
        /// intrinsic size. tvOS always presents 1080 points tall regardless of
        /// whether the display is 1080p or 4K, so this is stable.
        static let sizeLadder: [(reported: CGFloat, fraction: CGFloat)] = [
            (0.35, 0.0172),
            (0.60, 0.0287),
            (1.00, 0.0428),
            (1.50, 0.0722),
            (2.00, 0.0964)
        ]

        /// Caption point size for a presentation height and the system's
        /// reported relative character size.
        ///
        /// Interpolates between the measured rungs rather than matching exactly,
        /// so a value tvOS does not currently report still lands sensibly
        /// instead of falling back to a wrong multiply. Pure and static so the
        /// calibration is testable without building a view.
        static func pointSize(presentationHeight: CGFloat, fontScale: CGFloat) -> CGFloat {
            let height = presentationHeight > 0 ? presentationHeight : assumedVideoHeight
            return height * fraction(forReported: fontScale)
        }

        static func fraction(forReported reported: CGFloat) -> CGFloat {
            guard let first = sizeLadder.first, let last = sizeLadder.last else { return 0 }
            if reported <= first.reported { return first.fraction }
            if reported >= last.reported { return last.fraction }
            for (low, high) in zip(sizeLadder, sizeLadder.dropFirst()) where reported <= high.reported {
                let t = (reported - low.reported) / (high.reported - low.reported)
                return low.fraction + t * (high.fraction - low.fraction)
            }
            return last.fraction
        }

        /// Fallback presentation height, for a degenerate zero-height layout pass.
        static let assumedVideoHeight: CGFloat = 1080

        // Box geometry is expressed as MULTIPLES OF THE POINT SIZE, not fixed
        // points, because Apple's caption box grows with the type — a fixed
        // radius reads as a hard rectangle against much bigger glyphs at a
        // large caption size, and as an over-rounded pill at a small one.
        //
        // Radius is tuned by eye against AVPlayer: 0.25 gives 5pt at the
        // smallest setting (20pt type). The padding ratios are deliberately NOT
        // tied to it — they set how tightly the box hugs the text, which is
        // already matched, so change one without the other.
        static let cornerRadiusRatio: CGFloat = 0.25
        static let paddingHRatio: CGFloat = 0.30
        static let paddingVRatio: CGFloat = 0.075

        /// Uniform-edge outline weight, as a PERCENTAGE of the point size for
        /// `NSAttributedString.Key.strokeWidth` (negative = stroke AND fill).
        ///
        /// Proportional rather than fixed. The SwiftUI implementation faked the
        /// outline with eight copies of the string at a fixed 2pt offset, which
        /// was a tenth of the glyph height at the smallest caption size and a
        /// thin halo at the largest. 4% tracks the type at every size.
        static let outlineStrokePercent: CGFloat = -4

        /// Emboss offset for the raised and depressed edge styles, as a
        /// fraction of the point size. Proportional for the same reason the
        /// outline is: a fixed offset is a slab at 20pt type and invisible at
        /// 57pt.
        static let embossDepthRatio: CGFloat = 0.04

        /// Extra leading between the lines of one cue, on top of the font's own
        /// line height. Zero matches Apple, whose caption lines sit on natural
        /// leading inside a single background.
        static let textLineSpacing: CGFloat = 0

        /// Gap between separate simultaneous cues (two speakers), which SHOULD
        /// read as distinct blocks.
        static let cueSpacing: CGFloat = 4

        /// Horizontal room the default band leaves itself, in points, so a long
        /// caption wraps well inside the picture rather than at its edge.
        static let defaultBandSideInset: CGFloat = 120

        /// Where a TOP-band cue lands when its source gave only a coarse band
        /// and no fine position — teletext through the engine demux, which
        /// quantises the 24-row grid to three bands and supplies no percentage.
        ///
        /// Free to tune, because nothing measurable pins it: the source
        /// genuinely does not say where in the top third the caption belongs.
        /// Set near where the same page's proxied WebVTT resolves (it carries an
        /// exact `line:`, typically around 10%), so the two routes look similar
        /// even though only one of them can be precise.
        static let bandTopFraction: CGFloat = 0.10

        /// Anchor for a LEFT or RIGHT column that came with no fine position.
        /// Deliberately the same 10% / 90% the proxy writes into its WebVTT
        /// (`align:left position:10%`), so the same page lands in the same place
        /// whichever route it arrived by.
        static let bandSideFraction: CGFloat = 0.10

        /// Horizontal no-go zone at each edge of the PICTURE. AVPlayer will not
        /// draw a caption to the very edge — it keeps one inside a safe inset,
        /// the same idea as tvOS's title-safe area. Matches the 90pt the player
        /// chrome insets itself by at 1920 wide.
        static let sideSafeFraction: CGFloat = 0.05

        /// Duration and curve of the rail-driven lift. Matches the chrome's own
        /// fade (`UIView.animate(withDuration: 0.25)` with no options is a 0.25s
        /// ease-in-out), so the caption travels on exactly the curve the rail
        /// arrives on. Keep these in step: PlayerContainerViewController's
        /// `applyChromeVisibility` and the Live TV showRail/hideRail pair are
        /// the other half.
        static let liftDuration: TimeInterval = 0.25
    }

    // MARK: State

    private let model: SubtitleModel
    private var cancellables = Set<AnyCancellable>()

    private var textCues: [(view: CaptionBoxView, placement: AetherSubtitleCue.TextPlacement?)] = []
    private var bitmapCues: [(view: UIImageView, position: CGRect)] = []

    // MARK: Init

    init(model: SubtitleModel,
         style: CaptionStyle = .default,
         controlsVisible: Bool = false,
         videoSize: CGSize = .zero,
         heightUnits: Int = 0) {
        self.model = model
        self.style = style
        self.controlsVisible = controlsVisible
        self.videoSize = videoSize
        self.heightUnits = heightUnits
        super.init(frame: .zero)

        backgroundColor = .clear
        isUserInteractionEnabled = false

        // The model publishes the active SET, and only when it differs, so this
        // rebuilds per visible change rather than per clock tick. The cues come
        // through as the value: `@Published` fires from `willSet`, so reading
        // `model.activeCues` here would see the previous set.
        model.$activeCues
            .sink { [weak self] cues in self?.build(cues) }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Cue set

    /// Re-applies the current cue set, for a style change that alters how the
    /// same text draws.
    private func rebuildCueViews() {
        build(model.activeCues)
    }

    private func build(_ cues: [AetherSubtitleCue]) {
        textCues.forEach { $0.view.removeFromSuperview() }
        bitmapCues.forEach { $0.view.removeFromSuperview() }
        textCues.removeAll()
        bitmapCues.removeAll()

        for cue in cues {
            switch cue.body {
            case .image(let cgImage, let position):
                let iv = UIImageView(image: UIImage(cgImage: cgImage))
                iv.contentMode = .scaleToFill
                iv.layer.magnificationFilter = .trilinear
                addSubview(iv)
                bitmapCues.append((iv, position))
            case .text, .styledText:
                let box = CaptionBoxView(body: cue.body,
                                         style: style,
                                         alignment: Self.lineAlignment(for: cue.placement))
                addSubview(box)
                textCues.append((box, cue.placement))
            }
        }
        setNeedsLayout()
    }

    // MARK: Geometry

    /// The picture's rect inside `bounds`, aspect-fit (how both the engine
    /// surface and AVPlayerLayer place video). Falls back to the full bounds
    /// when the size is unknown.
    private func videoRect(in size: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / videoSize.width, size.height / videoSize.height)
        let w = videoSize.width * scale
        let h = videoSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// The lowest any caption may sit, as a distance from the bottom of the
    /// CONTAINER. EVERY cue obeys this, placed or not.
    ///
    /// Two anchors compete and the larger wins: the caption must sit
    /// `SubtitleAdjustments.bottomMarginFraction` of the PICTURE above its
    /// bottom edge (so letterboxed content is not captioned into its black
    /// bar), and it must clear the rail when the rail is up (which is anchored
    /// to the SCREEN). Taking the max means a 2.39:1 film with the rail hidden
    /// lifts by its letterbox, while the same film with the rail up still
    /// clears the chrome.
    ///
    /// Placed cues obey it too — Live TV is almost entirely placed cues, and
    /// exempting them is what made its captions sit lower than VOD's. It is a
    /// floor only: a cue asking to sit higher keeps its own position.
    private func placementFloor(in size: CGSize) -> CGFloat {
        let rect = videoRect(in: size)
        let letterbox = max(0, size.height - rect.maxY)
        var base = letterbox + rect.height * SubtitleAdjustments.bottomMarginFraction
        if controlsVisible {
            base = max(base, SubtitleAdjustments.controlsFloor(pictureHeight: rect.height))
        }
        return base
    }

    /// Distance from the bottom of the CONTAINER to an UNPLACED cue: the shared
    /// floor plus the user's Height stepper, which applies to the default band
    /// only.
    private func bottomPadding(in size: CGSize) -> CGFloat {
        max(0, placementFloor(in: size) + SubtitleAdjustments.heightOffset(forUnits: heightUnits))
    }

    /// Caption point size for this presentation, before per-cue styling.
    private func baseFontSize(in size: CGSize) -> CGFloat {
        Metrics.pointSize(presentationHeight: size.height, fontScale: style.fontScale)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let rect = videoRect(in: size)
        let pointSize = baseFontSize(in: size)

        // `SubtitleImage.position` is normalized against the SOURCE VIDEO
        // FRAME, not the player's bounds — upstream is explicit that a host
        // maps it onto the on-screen video rect. Multiplying by the full bounds
        // put PGS/DVB cues wrong on anything letterboxed: a 2.39:1 film
        // stretched them vertically and pushed them toward the black bar.
        for entry in bitmapCues {
            entry.view.frame = CGRect(
                x: rect.minX + entry.position.minX * rect.width,
                y: rect.minY + entry.position.minY * rect.height,
                width: entry.position.width * rect.width,
                height: entry.position.height * rect.height
            )
        }

        let unplaced = textCues.filter { $0.placement == nil }
        let placed = textCues.filter { $0.placement != nil }

        layoutDefaultBand(unplaced.map(\.view), in: size, pointSize: pointSize)
        for entry in placed {
            guard let placement = entry.placement else { continue }
            layoutPlaced(entry.view, placement: placement, in: size, rect: rect, pointSize: pointSize)
        }
    }

    /// The default bottom band: cues stacked upward from the floor, centred on
    /// the CONTAINER (not the picture, which is what the SwiftUI original did
    /// and what AVPlayer does for an unplaced cue).
    private func layoutDefaultBand(_ boxes: [CaptionBoxView], in size: CGSize, pointSize: CGFloat) {
        guard !boxes.isEmpty else { return }
        let maxWidth = max(0, size.width - Metrics.defaultBandSideInset * 2)
        var bottom = size.height - bottomPadding(in: size)
        for box in boxes.reversed() {
            box.apply(pointSize: pointSize)
            let fitted = box.fittingSize(maxWidth: maxWidth)
            box.frame = CGRect(x: ((size.width - fitted.width) / 2).rounded(),
                               y: (bottom - fitted.height).rounded(),
                               width: fitted.width,
                               height: fitted.height)
            bottom -= fitted.height + Metrics.cueSpacing
        }
    }

    /// Which edge a cue's lines align to, from the column its own alignment
    /// names. Matches the edge `layoutPlaced` anchors the box on, so the two
    /// cannot disagree.
    ///
    /// An unplaced cue centres, as the default band always has.
    /// Which column a positioned cue anchors to: 0 left, 1 centre, 2 right.
    ///
    /// An explicit numpad `alignment` wins. When the source gives none, a fine
    /// `position.x` STILL names an edge — WebVTT's `position:` is the box's
    /// start edge, not its centre — so a cue placed on the left anchors left.
    /// Centre-anchoring it lets a longer second line widen the box
    /// symmetrically and drag the first line sideways, which is the drift
    /// the line alignment was meant to stop and could not, because the box
    /// itself was on the wrong anchor.
    ///
    /// `layoutPlaced` and `lineAlignment` both read this, so the edge the box
    /// is pinned on and the edge the lines align to cannot disagree.
    static func captionColumn(for placement: AetherSubtitleCue.TextPlacement) -> Int {
        if let alignment = placement.alignment {
            return (min(max(alignment, 1), 9) - 1) % 3
        }
        guard let x = placement.position?.x else { return 1 }
        if x <= 0.4 { return 0 }
        if x >= 0.6 { return 2 }
        return 1
    }

    static func lineAlignment(for placement: AetherSubtitleCue.TextPlacement?) -> NSTextAlignment {
        guard let placement else { return .center }
        switch captionColumn(for: placement) {
        case 0: return .left
        case 2: return .right
        default: return .center
        }
    }

    /// A cue the source positioned itself, placed against the PICTURE (so a
    /// letterboxed film's signs land on the image, not in the black bar).
    ///
    /// Two kinds of placement arrive here and they resolve differently:
    ///
    /// **With a fine position** (proxied WebVTT `line:` / `position:`, ASS
    /// `\pos`) the line position names the box's TOP edge: WebVTT's default
    /// `line-align` is `start`, so the box hangs DOWN from the stated line, and
    /// that is where AVPlayer draws it. Anchoring the centre on it instead sits
    /// half a box high. Horizontally the cue's alignment picks the anchored
    /// edge, and the box wraps into the room between that anchor and the far
    /// side of the picture.
    ///
    /// **Without one** (teletext through the engine demux, which quantises the
    /// grid row to a coarse `\an` and supplies no percentage) the numpad band is
    /// all there is, so the cue takes that band's natural resting place: the
    /// shared floor at the bottom, the matching margin at the top, dead centre
    /// in the middle.
    private func layoutPlaced(_ box: CaptionBoxView,
                              placement: AetherSubtitleCue.TextPlacement,
                              in size: CGSize,
                              rect: CGRect,
                              pointSize: CGFloat) {
        // Numpad: rows 7-9 top, 4-6 middle, 1-3 bottom; columns 1/4/7 left,
        // 2/5/8 centre, 3/6/9 right. 2 (bottom-centre) is the ASS default.
        let an = placement.alignment ?? 2
        let col = Self.captionColumn(for: placement)
        let row = (an - 1) / 3

        // Clamped so a wild coordinate cannot push a caption off screen.
        let ax = placement.position.map { min(max($0.x, 0), 1) }
        let ay = placement.position.map { min(max($0.y, 0), 1) }

        let letterbox = max(0, size.height - rect.maxY)
        let floor = placementFloor(in: size)

        // Horizontal first: the width limit decides how the box wraps, and the
        // wrapped height then decides the vertical anchor.
        //
        // A column with no fine position (teletext) borrows the anchor the
        // proxy writes for that column, so both routes resolve through the
        // identical maths below and land together.
        let anchorX: CGFloat? = ax
            ?? (col == 0 ? Metrics.bandSideFraction
                : col == 2 ? 1 - Metrics.bandSideFraction : nil)

        // The anchor names the edge the cue's OWN alignment names: a left
        // column's left edge, a right column's right edge, a centre column's
        // midpoint. Centring every box on the anchor regardless of alignment
        // is what wrapped `align:left position:10%` into a 27%-wide column
        // four lines tall, pinned at 18.5% instead of starting at 10%.
        let safeMinX = rect.minX + rect.width * Metrics.sideSafeFraction
        let safeMaxX = rect.maxX - rect.width * Metrics.sideSafeFraction
        let requested = anchorX.map { rect.minX + $0 * rect.width } ?? rect.midX
        let anchor = min(max(requested, safeMinX), max(safeMinX, safeMaxX))

        // A side-anchored cue wraps into the room between its anchor and the
        // FAR safe edge, which is what WebVTT gives it. Wrapping into the
        // whole safe width instead would overflow and drag the box off its
        // anchor; wrapping into the near half squeezes it into a column.
        let widthLimit: CGFloat
        switch col {
        case 0: widthLimit = safeMaxX - anchor
        case 2: widthLimit = anchor - safeMinX
        default: widthLimit = max(0, safeMaxX - safeMinX)
        }

        box.apply(pointSize: pointSize)
        let fitted = box.fittingSize(maxWidth: widthLimit)

        // Clamped as well as limited: `fittingSize` can exceed `maxWidth` for
        // a single unbreakable word.
        let requestedX: CGFloat
        switch col {
        case 0: requestedX = anchor
        case 2: requestedX = anchor - fitted.width
        default: requestedX = anchor - fitted.width / 2
        }
        let originX = min(max(requestedX, safeMinX), max(safeMinX, safeMaxX - fitted.width))

        // Vertical. A fine position wins; the band is the fallback.
        //
        // The box is measured, so the half-box below is the real one. That
        // matters twice: the top-edge anchor is exact for a two-line cue rather
        // than a one-line estimate, and the floor clamp protects the TEXT
        // rather than a guess at its midpoint.
        let centreY: CGFloat
        if let ay {
            let halfBox = fitted.height / 2
            let lowestCentre = max(0, floor - letterbox) + halfBox
            let requestedCentre = (1 - ay) * rect.height - halfBox
            centreY = rect.maxY - max(requestedCentre, lowestCentre)
        } else if row == 2 {
            centreY = rect.minY + rect.height * Metrics.bandTopFraction + fitted.height / 2
        } else if row == 1 {
            centreY = rect.midY
        } else {
            centreY = rect.maxY - max(0, floor - letterbox) - fitted.height / 2
        }

        box.frame = CGRect(x: originX.rounded(),
                           y: (centreY - fitted.height / 2).rounded(),
                           width: fitted.width,
                           height: fitted.height)
    }

    // MARK: Host API

    /// Applies a rail-visibility change. Call this INSIDE the host's own chrome
    /// animation block so the lift and the rail's fade share one clock; the
    /// `animated` path is for hosts that have no such block of their own.
    func setControlsVisible(_ visible: Bool, animated: Bool) {
        guard visible != controlsVisible else { return }
        guard animated else {
            controlsVisible = visible
            return
        }
        controlsVisible = visible
        UIView.animate(withDuration: Metrics.liftDuration) { self.layoutIfNeeded() }
    }
}

// MARK: - CaptionBoxView

/// One cue in ONE rounded box, sized to its longest line.
///
/// A multi-line cue keeps its author's line breaks and stays inside a single
/// background — the box hugs the widest line and the shorter lines centre
/// within it. (An earlier attempt boxed each line separately; that reads as
/// detached labels rather than one caption.)
private final class CaptionBoxView: UIView {

    private let label = UILabel()
    private let body: AetherSubtitleCue.Body
    private let style: CaptionStyle

    /// Which edge the lines align to INSIDE the box.
    ///
    /// The box hugs its widest line, so a shorter line has slack. Centring that
    /// slack is right for a centred cue and wrong for a side-anchored one: the
    /// box grows away from its anchor as a later line runs longer, and every
    /// shorter line then re-centres in the wider box — so a left-positioned
    /// cue's first word visibly slides right when the line below it extends.
    /// The anchored edge has to stay put and the growth go to the other side.
    private let alignment: NSTextAlignment

    /// Point size the current attributed string was built at. Everything about
    /// the box scales with it, so a change rebuilds; an unchanged size makes
    /// `apply` free, which matters because layout runs on every rail lift.
    private var appliedPointSize: CGFloat = 0

    /// Nominal ASS font size that a cue's `\fs` is judged against. libavcodec
    /// synthesises its ASS lines at a 384x288 play resolution whose default
    /// style is 16pt, so `\fs32` means "twice normal", not "32 points".
    private static let assNominalFontSize: CGFloat = 16

    init(body: AetherSubtitleCue.Body, style: CaptionStyle, alignment: NSTextAlignment = .center) {
        self.body = body
        self.style = style
        self.alignment = alignment
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        // The rounded background is the view's own, so there is no mask and no
        // offscreen pass. `clipsToBounds` stays false: an outline stroke may sit
        // a fraction outside the text box.
        layer.cornerCurve = .continuous

        label.numberOfLines = 0
        label.textAlignment = alignment
        label.backgroundColor = .clear
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Builds the attributed string and box chrome for a concrete point size.
    func apply(pointSize: CGFloat) {
        guard pointSize != appliedPointSize else { return }
        appliedPointSize = pointSize

        label.attributedText = attributedText(pointSize: pointSize)
        layer.cornerRadius = pointSize * CaptionOverlayView.Metrics.cornerRadiusRatio

        // The uniform edge is an outline INSTEAD of a box; every other edge
        // style draws the system's background behind the glyphs.
        if style.edge == .uniform {
            backgroundColor = .clear
        } else {
            backgroundColor = style.backgroundColor.withAlphaComponent(style.backgroundOpacity)
        }
    }

    /// Inset from the box's edge to the text, zero for the box-less uniform edge.
    private var padding: (h: CGFloat, v: CGFloat) {
        guard style.edge != .uniform else { return (0, 0) }
        return (appliedPointSize * CaptionOverlayView.Metrics.paddingHRatio,
                appliedPointSize * CaptionOverlayView.Metrics.paddingVRatio)
    }

    /// The box's size for a given wrapping width: the text's own size plus
    /// padding, never wider than the limit.
    func fittingSize(maxWidth: CGFloat) -> CGSize {
        guard let text = label.attributedText, text.length > 0 else { return .zero }
        let pad = padding
        let textMax = max(0, maxWidth - pad.h * 2)
        let rect = text.boundingRect(
            with: CGSize(width: textMax, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: min(maxWidth, ceil(rect.width) + pad.h * 2),
                      height: ceil(rect.height) + pad.v * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pad = padding
        label.frame = bounds.insetBy(dx: pad.h, dy: pad.v)
    }

    // MARK: Text

    /// Builds the cue's attributed string, applying each content attribute only
    /// where the matching system Video Override allows it:
    ///  - colour                                          -> `allowsContentColor`
    ///  - bold/italic/underline/strikethrough, font face   -> `allowsContentFont`
    ///  - relative size                                    -> `allowsContentFontSize`
    ///
    /// A gated-off or content-silent attribute renders the system value. The
    /// system foreground opacity applies either way.
    private func attributedText(pointSize: CGFloat) -> NSAttributedString {
        let userColor = style.foreground.withAlphaComponent(style.foregroundOpacity)
        let baseFont = style.font(ofSize: pointSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = CaptionOverlayView.Metrics.textLineSpacing

        let result = NSMutableAttributedString()

        switch body {
        case .text(let string):
            result.append(NSAttributedString(string: string, attributes: [
                .font: baseFont,
                .foregroundColor: userColor,
                .paragraphStyle: paragraph
            ]))

        case .styledText(let runs):
            for run in runs {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font(for: run, baseSize: pointSize) ?? baseFont,
                    .paragraphStyle: paragraph
                ]
                // A run's own colour only wins where the system allows it.
                let contentColor = style.allowsContentColor ? run.color : nil
                attributes[.foregroundColor] =
                    contentColor?.withAlphaComponent(style.foregroundOpacity) ?? userColor
                if style.allowsContentFont {
                    if run.isUnderlined {
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if run.isStruckThrough {
                        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }

        case .image:
            break
        }

        applyEdge(to: result, pointSize: pointSize)
        return result
    }

    /// The system text-edge treatment. Every case is one draw: a negative
    /// `strokeWidth` strokes AND fills, and `NSShadow` is drawn by the text
    /// system rather than by a layer shadow (no offscreen pass, no shadowPath).
    ///
    /// All five `MACaptionAppearanceTextEdgeStyle` values are honoured. Raised
    /// and depressed are the same hard-edged offset in opposite directions:
    /// light from the top-left lifts the glyph off the picture, light from the
    /// bottom-right carves it in. Zero blur is what separates them from
    /// `dropShadow`, which is a soft shadow rather than an emboss.
    private func applyEdge(to text: NSMutableAttributedString, pointSize: CGFloat) {
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }

        /// Emboss depth. Proportional so the effect survives a large caption
        /// size, floored at a point so it does not vanish at the smallest.
        let depth = max(1, pointSize * CaptionOverlayView.Metrics.embossDepthRatio)

        func shadow(offset: CGSize, blur: CGFloat, alpha: CGFloat) -> NSShadow {
            let s = NSShadow()
            s.shadowColor = UIColor.black.withAlphaComponent(alpha)
            s.shadowBlurRadius = blur
            s.shadowOffset = offset
            return s
        }

        switch style.edge {
        case .uniform:
            text.addAttributes([
                .strokeColor: UIColor.black,
                .strokeWidth: CaptionOverlayView.Metrics.outlineStrokePercent
            ], range: full)

        case .dropShadow:
            text.addAttribute(.shadow,
                              value: shadow(offset: CGSize(width: 0, height: 1),
                                            blur: 3,
                                            alpha: 0.85),
                              range: full)

        case .raised:
            text.addAttribute(.shadow,
                              value: shadow(offset: CGSize(width: depth, height: depth),
                                            blur: 0,
                                            alpha: 0.9),
                              range: full)

        case .depressed:
            text.addAttribute(.shadow,
                              value: shadow(offset: CGSize(width: -depth, height: -depth),
                                            blur: 0,
                                            alpha: 0.9),
                              range: full)

        case .none:
            break
        }
    }

    /// The font for one run, or nil when the content asked for nothing and the
    /// system caption font should apply unchanged.
    private func font(for run: AetherSubtitleCue.StyledRun, baseSize: CGFloat) -> UIFont? {
        let wantsFace = style.allowsContentFont && (run.isBold || run.isItalic || run.fontName != nil)
        let scale = contentSizeScale(for: run)
        guard wantsFace || scale != nil else { return nil }

        let size = baseSize * (scale ?? 1)
        // A content font FACE is honoured by name; an unknown name falls back to
        // the system caption font at the same size rather than to a default that
        // would ignore the user's choice entirely.
        var font: UIFont
        if style.allowsContentFont, let name = run.fontName, !name.isEmpty,
           let named = UIFont(name: name, size: size) {
            font = named
        } else {
            font = style.font(ofSize: size)
        }

        if style.allowsContentFont {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.isBold { traits.insert(.traitBold) }
            if run.isItalic { traits.insert(.traitItalic) }
            if !traits.isEmpty,
               let descriptor = font.fontDescriptor.withSymbolicTraits(
                   font.fontDescriptor.symbolicTraits.union(traits)) {
                font = UIFont(descriptor: descriptor, size: size)
            }
        }
        return font
    }

    /// A run's `\fs` as a multiplier, or nil when it asks for nothing.
    ///
    /// `fontSize` is in ASS play-resolution points, so it is meaningful only
    /// RELATIVE to the script's nominal size — libavcodec's synthesised lines
    /// use a 384x288 play resolution whose default style is 16pt. Treating it as
    /// a point size directly would make a `\fs20` line tiny. Clamped so a wild
    /// value cannot fill the screen.
    private func contentSizeScale(for run: AetherSubtitleCue.StyledRun) -> CGFloat? {
        guard style.allowsContentFontSize, let size = run.fontSize, size > 0 else { return nil }
        let ratio = CGFloat(size) / Self.assNominalFontSize
        guard abs(ratio - 1) > 0.01 else { return nil }
        return min(max(ratio, 0.5), 2.0)
    }
}
