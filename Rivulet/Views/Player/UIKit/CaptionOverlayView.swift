// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  UIKit caption overlay for VOD and Live TV: text, styled text and PGS/DVB
//  bitmaps from `SubtitleModel`, mounted above the video and below the chrome.
//  Sizing and placement match AVPlayer's caption rendering.

import Combine
import UIKit

// MARK: - CaptionOverlayView

final class CaptionOverlayView: UIView {

    // MARK: Inputs

    /// Current caption appearance. Replaced wholesale on CaptionAppearance changes.
    var style: CaptionStyle {
        didSet {
            guard style != oldValue else { return }
            syncASS()
            rebuildCueViews()
        }
    }

    /// The active track's ASS script when it is ASS/SSA, else nil.
    ///
    /// With every system Video Override allowing content styling (the
    /// default) libass renders the track. With any of them pinned, its lines
    /// draw as plain captions in the system style, keeping `\an` / `\pos`
    /// and dropping vector drawings. libass's own style override cannot stand
    /// in for that: it changes Style definitions only, never inline tags,
    /// and skips positioned events.
    var assTrack: ASSTrackSource? {
        didSet {
            guard assTrack !== oldValue else { return }
            syncASS()
            rebuildCueViews()
        }
    }

    /// Frame-accurate cue-axis clock for libass (see ASSOverlayView).
    var sourceClock: ((CFTimeInterval) -> Double?)? {
        get { assView.sourceClock }
        set { assView.sourceClock = newValue }
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

    /// True while an info pane is open: captions sit above its risen pills.
    var paneOpen = false {
        didSet {
            guard paneOpen != oldValue else { return }
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

        /// Caption size as a fraction of the presentation height per unit of
        /// `MACaptionAppearanceGetRelativeCharacterSize`. AVKit scales linearly
        /// with the reported value for every style but one (measured, tvOS 27.0
        /// sim, within 2% at 0.35, 0.6, 1.0, 1.5 and 2.0).
        ///
        /// Presentation height, not picture height: AVKit sizes captions from the
        /// view and only positions them against the picture (#299).
        static let fractionPerUnit: CGFloat = 0.0481

        /// The exception: Apple's built-in Default style draws about 11% smaller
        /// than its reported 1.0. A copy of it, Classic, or any edited style
        /// does not (#422).
        static let systemDefaultFraction: CGFloat = 0.0428

        /// Caption point size for a presentation height and reported character size.
        static func pointSize(presentationHeight: CGFloat, fontScale: CGFloat,
                              isSystemDefault: Bool = false) -> CGFloat {
            let height = presentationHeight > 0 ? presentationHeight : assumedVideoHeight
            return height * (isSystemDefault ? systemDefaultFraction : fontScale * fractionPerUnit)
        }

        /// Fallback presentation height, for a degenerate zero-height layout pass.
        static let assumedVideoHeight: CGFloat = 1080

        // Box geometry scales with the point size, as Apple's caption box does.
        // Radius tuned by eye against AVPlayer; padding is matched separately.
        static let cornerRadiusRatio: CGFloat = 0.25
        static let paddingHRatio: CGFloat = 0.30
        static let paddingVRatio: CGFloat = 0.075

        /// Uniform-edge outline weight, a percentage of the point size for
        /// `NSAttributedString.Key.strokeWidth` (positive: stroke only). The fill
        /// covers the inner half, so the visible outline is half this.
        static let outlineStrokePercent: CGFloat = 8

        /// Emboss offset for the raised and depressed edge styles, as a
        /// fraction of the point size. Proportional for the same reason the
        /// outline is: a fixed offset is a slab at 20pt type and invisible at
        /// 57pt.
        static let embossDepthRatio: CGFloat = 0.04

        /// Line pitch inside one cue as a multiple of the point size. AVKit spaces
        /// lines wider than the font's own line height (measured, tvOS 27 sim:
        /// 1.43-1.46 at Default, 1.0 and 1.5).
        static let linePitchRatio: CGFloat = 1.444

        /// Leading to add under each line so the pitch is `linePitchRatio`.
        static func lineSpacing(for font: UIFont) -> CGFloat {
            max(0, font.pointSize * linePitchRatio - font.lineHeight)
        }

        /// Gap between separate simultaneous cues (two speakers), which SHOULD
        /// read as distinct blocks.
        static let cueSpacing: CGFloat = 4

        /// Horizontal room the default band leaves itself, in points, so a long
        /// caption wraps well inside the picture rather than at its edge.
        static let defaultBandSideInset: CGFloat = 120

        /// Edge distance for a top or bottom band cue with no fine position
        /// (teletext via engine demux). Near where proxied WebVTT lands (~10%).
        /// Keep it off the 5% default floor, or a placed cue looks unplaced.
        static let bandEdgeFraction: CGFloat = 0.10

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

    /// libass layer for ASS/SSA tracks, below every text and bitmap cue.
    private let assView: ASSOverlayView

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
        self.assView = ASSOverlayView(model: model)
        super.init(frame: .zero)

        backgroundColor = .clear
        isUserInteractionEnabled = false
        addSubview(assView)

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

    // MARK: ASS

    private var libassAllowed: Bool {
        style.allowsContentColor && style.allowsContentFont && style.allowsContentFontSize
    }

    private func syncASS() {
        assView.track = libassAllowed && !isHidden ? assTrack : nil
    }

    /// Hidden, libass stops too (the content filter reading a track unseen).
    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            syncASS()
            rebuildCueViews()
        }
    }

    /// Whether libass is drawing the ASS track right now. Reads the renderer,
    /// not the request, so a libass that failed to start falls back to plain
    /// captions instead of showing nothing.
    private var rendersWithLibass: Bool { assView.isRendering }

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

        for cue in isHidden ? [] : cues {
            switch cue.body {
            case .image(let cgImage, let position):
                let iv = UIImageView(image: UIImage(cgImage: cgImage))
                iv.contentMode = .scaleToFill
                iv.layer.magnificationFilter = .trilinear
                addSubview(iv)
                bitmapCues.append((iv, position))
            case .assEvents(let lines):
                guard !rendersWithLibass else { continue }
                let playRes = ASSEventLine.playRes(fromHeader: assTrack?.header)
                for event in ASSEventLine.lines(in: lines) where !event.isDrawing {
                    let text = event.plainText
                    guard !text.isEmpty else { continue }
                    let placement = event.placement(playRes: playRes).map {
                        AetherSubtitleCue.TextPlacement(alignment: $0.alignment, position: $0.position)
                    }
                    let box = CaptionBoxView(body: .text(text), style: style,
                                             alignment: Self.lineAlignment(for: placement))
                    addSubview(box)
                    textCues.append((box, placement))
                }
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

    /// The lowest any cue may sit, placed or not, as a distance from the container
    /// bottom: the larger of the picture margin (clears a letterbox bar) and the
    /// rail's clearance when the rail is up. A floor only.
    private func placementFloor(in size: CGSize) -> CGFloat {
        let rect = videoRect(in: size)
        let letterbox = max(0, size.height - rect.maxY)
        var base = letterbox + rect.height * restingMarginFraction
        if controlsVisible || paneOpen {
            base = max(base, SubtitleAdjustments.controlsFloor(isSystemDefault: style.isSystemDefault)
                + (paneOpen ? SubtitleAdjustments.paneLift : 0))
        }
        return base
    }

    private var restingMarginFraction: CGFloat {
        style.isSystemDefault ? SubtitleAdjustments.systemDefaultBottomMarginFraction
                              : SubtitleAdjustments.bottomMarginFraction
    }

    /// Distance from the bottom of the CONTAINER to an UNPLACED cue: the shared
    /// floor plus the user's Height stepper, which applies to the default band
    /// only.
    private func bottomPadding(in size: CGSize) -> CGFloat {
        max(0, placementFloor(in: size) + SubtitleAdjustments.heightOffset(forUnits: heightUnits))
    }

    /// Caption point size for this presentation, before per-cue styling.
    private func baseFontSize(in size: CGSize) -> CGFloat {
        Metrics.pointSize(presentationHeight: size.height, fontScale: style.fontScale,
                          isSystemDefault: style.isSystemDefault)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let rect = videoRect(in: size)
        let pointSize = baseFontSize(in: size)

        // libass draws over the picture only, like the bitmap cues below.
        assView.storageSize = videoSize
        assView.linePosition = assLinePosition(in: size, rect: rect)
        assView.frame = rect

        // `SubtitleImage.position` is normalized to the source video frame, so
        // map it onto the on-screen video rect, not the bounds.
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
    /// the container, as AVPlayer does for an unplaced cue.
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

    /// Which column a positioned cue anchors to: 0 left, 1 centre, 2 right.
    ///
    /// An explicit numpad `alignment` wins; otherwise `position.x` names an edge,
    /// because WebVTT's `position:` is the box's start edge, not its centre.
    /// `layoutPlaced` and `lineAlignment` both read this so they cannot disagree.
    static func captionColumn(for placement: AetherSubtitleCue.TextPlacement) -> Int {
        if let alignment = placement.alignment {
            return (min(max(alignment, 1), 9) - 1) % 3
        }
        guard let x = placement.position?.x else { return 1 }
        if x <= 0.4 { return 0 }
        if x >= 0.6 { return 2 }
        return 1
    }

    /// Which edge a cue's lines align to, from its column. An unplaced cue centres.
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
    /// A fine position (WebVTT `line:`, ASS `\pos`) names the box's top edge, since
    /// WebVTT's default `line-align` is `start`. Without one (teletext) the cue
    /// takes its numpad band's resting place.
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

        // Horizontal first: the width limit decides the wrap, which decides the
        // height. A column with no fine position borrows the proxy's anchor.
        let anchorX: CGFloat? = ax
            ?? (col == 0 ? Metrics.bandSideFraction
                : col == 2 ? 1 - Metrics.bandSideFraction : nil)

        // The anchor is the edge the cue's column names: left edge, right edge,
        // or midpoint.
        let safeMinX = rect.minX + rect.width * Metrics.sideSafeFraction
        let safeMaxX = rect.maxX - rect.width * Metrics.sideSafeFraction
        let requested = anchorX.map { rect.minX + $0 * rect.width } ?? rect.midX
        let anchor = min(max(requested, safeMinX), max(safeMinX, safeMaxX))

        // A side-anchored cue wraps into the room between its anchor and the
        // far safe edge, as WebVTT does.
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
        let centreY: CGFloat
        if let ay {
            let halfBox = fitted.height / 2
            let lowestCentre = max(0, floor - letterbox) + halfBox
            let requestedCentre = (1 - ay) * rect.height - halfBox
            centreY = rect.maxY - max(requestedCentre, lowestCentre)
        } else if row == 2 {
            centreY = rect.minY + rect.height * Metrics.bandEdgeFraction + fitted.height / 2
        } else if row == 1 {
            centreY = rect.midY
        } else {
            // The band's resting place; `floor` can still push it higher.
            let band = rect.height * Metrics.bandEdgeFraction
            let lowest = max(0, floor - letterbox)
            centreY = rect.maxY - max(band, lowest) - fitted.height / 2
        }

        box.frame = CGRect(x: originX.rounded(),
                           y: (centreY - fitted.height / 2).rounded(),
                           width: fitted.width,
                           height: fitted.height)
    }

    /// How far libass lifts unpositioned dialogue, as its line position
    /// (percent of the picture height): the rail's clearance while the rail
    /// is up plus the Height stepper, the same lift a plain caption gets over
    /// its resting floor. libass applies it to dialogue only, so positioned
    /// signs stay where the typesetter put them.
    ///
    /// ponytail: the lift jumps on the next rendered frame instead of riding the rail's 0.25 s fade; interpolate linePosition in the display link if it reads as a snap on device.
    private func assLinePosition(in size: CGSize, rect: CGRect) -> Double {
        guard rect.height > 0 else { return 0 }
        let resting = max(0, size.height - rect.maxY) + rect.height * restingMarginFraction
        let lift = bottomPadding(in: size) - resting
        return Double(min(max(lift / rect.height * 100, 0), 100))
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

/// Strokes its text with round joins; the default miter joins spike at sharp
/// corners (the foot of an N) once the stroke is this wide.
private final class OutlineLabel: UILabel {
    override func drawText(in rect: CGRect) {
        UIGraphicsGetCurrentContext()?.setLineJoin(.round)
        super.drawText(in: rect)
    }
}

/// One cue in ONE rounded box, sized to its longest line.
///
/// Keeps the author's line breaks; shorter lines align to `alignment`.
private final class CaptionBoxView: UIView {

    private let label = UILabel()
    /// The uniform edge's stroke-only copy of the text, drawn under `label`.
    /// Stroking the fill itself centres the stroke on the glyph edge, which
    /// thins the letters and draws SF's overlapping contours inside them (#422).
    private var outlineLabel: OutlineLabel?
    private let body: AetherSubtitleCue.Body
    private let style: CaptionStyle

    /// Which edge the lines align to inside the box. A side-anchored cue must not
    /// centre, or its first line slides when a later line runs longer.
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
        if style.edge == .uniform {
            let outline = OutlineLabel()
            outline.numberOfLines = 0
            outline.textAlignment = alignment
            outline.backgroundColor = .clear
            addSubview(outline)
            outlineLabel = outline
        }
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Builds the attributed string and box chrome for a concrete point size.
    func apply(pointSize: CGFloat) {
        guard pointSize != appliedPointSize else { return }
        appliedPointSize = pointSize

        let text = attributedText(pointSize: pointSize)
        label.attributedText = text
        outlineLabel?.attributedText = Self.outlined(text)
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
        outlineLabel?.frame = label.frame
    }

    /// The text as a black stroke with no fill. Stroke attributes leave glyph
    /// metrics alone, so it lays out exactly under the fill.
    private static func outlined(_ text: NSAttributedString) -> NSAttributedString {
        let outline = NSMutableAttributedString(attributedString: text)
        outline.addAttributes([
            .strokeColor: UIColor.black,
            .strokeWidth: CaptionOverlayView.Metrics.outlineStrokePercent
        ], range: NSRange(location: 0, length: outline.length))
        return outline
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
        paragraph.lineSpacing = CaptionOverlayView.Metrics.lineSpacing(for: baseFont)

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

        case .image, .assEvents:
            break
        }

        applyEdge(to: result, pointSize: pointSize)
        return result
    }

    /// The system text-edge treatment, except uniform, which `outlineLabel`
    /// draws. `NSShadow` is drawn by the text system rather than by a layer
    /// shadow (no offscreen pass, no shadowPath).
    ///
    /// Raised and depressed are the same zero-blur offset in opposite directions.
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

        case .uniform, .none:
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
    /// `fontSize` is relative to `assNominalFontSize`, not a point size. Clamped
    /// so a wild value cannot fill the screen.
    private func contentSizeScale(for run: AetherSubtitleCue.StyledRun) -> CGFloat? {
        guard style.allowsContentFontSize, let size = run.fontSize, size > 0 else { return nil }
        let ratio = CGFloat(size) / Self.assNominalFontSize
        guard abs(ratio - 1) > 0.01 else { return nil }
        return min(max(ratio, 0.5), 2.0)
    }
}
