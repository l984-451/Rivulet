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

    /// The global Height setting, in stepper units. Applies to the default band only.
    var heightUnits: Int {
        didSet {
            guard heightUnits != oldValue else { return }
            setNeedsLayout()
        }
    }

    // MARK: Metrics
    //
    // Apple's caption renderer (MediaToolbox `FigCaptionRendererCaption`), read
    // and checked by screenshot against AVPlayerViewController on grey.

    enum Metrics {

        /// Caption size as a fraction of the presentation height, in whole points,
        /// then scaled by `MACaptionAppearanceGetRelativeCharacterSize`. AVKit is
        /// linear for every style but one (52pt at 1.0 and 1080; measured, tvOS 27.0
        /// sim at 0.35, 0.6, 1.0, 1.5 and 2.0).
        ///
        /// Presentation height, not picture height: AVKit sizes captions from the
        /// view and only positions them against the picture (#299).
        static let fractionPerUnit: CGFloat = 0.0482

        /// The exception: Apple's built-in Default style draws about 11% smaller
        /// than its reported 1.0, keyed on the style's name. A copy of it, Classic,
        /// or any edited style does not (#422).
        static let systemDefaultFraction: CGFloat = 0.0428

        /// Caption point size for a presentation height and reported character size.
        static func pointSize(presentationHeight: CGFloat, fontScale: CGFloat,
                              isSystemDefault: Bool = false) -> CGFloat {
            let height = presentationHeight > 0 ? presentationHeight : assumedVideoHeight
            return isSystemDefault ? (height * systemDefaultFraction).rounded(.down)
                                   : (height * fractionPerUnit).rounded(.down) * fontScale
        }

        /// The highest the Height setting may rest the default band's bottom edge.
        static let highestBandFraction: CGFloat = 0.8

        /// Fallback presentation height, for a degenerate zero-height layout pass.
        static let assumedVideoHeight: CGFloat = 1080

        /// Blur of every edge style's shadow, in points.
        static let edgeShadowBlur: CGFloat = 4

        /// Shadow offset of the raised, depressed and drop shadow edges. Above 60pt
        /// Apple takes two thirds of it.
        static func edgeOffset(pointSize: CGFloat) -> CGFloat {
            let offset = pointSize * 3 / 34
            return pointSize > 60 ? offset / 1.5 : offset
        }

        /// `strokeWidth` percentage for the uniform and drop shadow edges. Half the
        /// stroke shows outside the glyph, and above 60pt it grows at an eighth the rate.
        static func strokeWidthPercent(pointSize: CGFloat, edge: CaptionStyle.Edge) -> CGFloat {
            let factor: CGFloat = edge == .uniform ? 7 / 72 : 2 / 72
            let outside = pointSize <= 60 ? pointSize * factor : (60 + (pointSize - 60) / 8) * factor
            return outside * 2 * 100 / pointSize
        }

        /// How far a raised, depressed or uniform edge insets the text inside its box.
        static func edgeInset(for font: UIFont, edge: CaptionStyle.Edge) -> CGFloat {
            switch edge {
            case .raised, .depressed: return edgeOffset(pointSize: font.pointSize)
            case .uniform: return (font.ascender - font.descender) * 0.1
            case .dropShadow, .none: return 0
            }
        }

        /// Leading to add under each line. Apple spaces lines by the font's leading
        /// or a fifth of its ascent and descent, whichever is larger, in whole points.
        static func lineSpacing(for font: UIFont) -> CGFloat {
            let height = font.ascender - font.descender
            return max(0, ceil(height + max(font.leading, height * 0.2) - 0.1) - font.lineHeight)
        }

        /// Apple multiplies every caption colour by this while the display is in HDR.
        static let hdrColorScale: CGFloat = 0.9

        /// Gap between separate simultaneous cues (two speakers), which SHOULD
        /// read as distinct blocks.
        static let cueSpacing: CGFloat = 4

        /// Horizontal room the default band's text leaves itself, in points, so a
        /// long caption wraps inside the picture rather than at its edge.
        static let defaultBandSideInset: CGFloat = 90

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

    private var displayIsHDR: Bool {
        (window?.windowScene?.screen.currentEDRHeadroom ?? 1) > 1.001
    }
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
                                             alignment: Self.lineAlignment(for: placement), isHDR: displayIsHDR)
                    addSubview(box)
                    textCues.append((box, placement))
                }
            case .text, .styledText:
                let box = CaptionBoxView(body: cue.body,
                                         style: style,
                                         alignment: Self.lineAlignment(for: cue.placement),
                                         isHDR: displayIsHDR)
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
        var base = letterbox + rect.height * SubtitleAdjustments.bottomMarginFraction
        if controlsVisible || paneOpen {
            base = max(base, SubtitleAdjustments.controlsFloor
                + (paneOpen ? SubtitleAdjustments.paneLift : 0))
        }
        return base
    }

    /// Distance from the bottom of the CONTAINER to an UNPLACED cue: AVPlayer's
    /// position plus the Height setting, on screen and clear of the rail.
    private func bottomPadding(in size: CGSize) -> CGFloat {
        let rect = videoRect(in: size)
        let resting = max(0, size.height - rect.maxY) + rect.height * SubtitleAdjustments.bottomMarginFraction
        let offset = SubtitleAdjustments.heightOffset(forUnits: heightUnits)
        // The cap leaves room for a few lines above the box's bottom edge.
        let highest = size.height * Metrics.highestBandFraction
        // The Height stepper lives in the open pane, so every step has to show there.
        if paneOpen { return min(max(0, placementFloor(in: size) + offset), highest) }
        let onScreen = min(max(0, resting + offset), highest)
        return controlsVisible ? max(onScreen, placementFloor(in: size)) : onScreen
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
            let fitted = box.fittingSize(maxTextWidth: maxWidth)
            box.frame = CGRect(x: ((size.width - fitted.width) / 2).rounded(.down),
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

    /// Paragraph direction from the cue's dominant script, so a right-to-left cue that
    /// opens with a Latin name or a digit still ends its sentence on the left (#468).
    static func baseWritingDirection(for text: String) -> NSWritingDirection {
        var rtl = 0, ltr = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: rtl += 1
            default: ltr += 1
            }
        }
        if rtl == 0 && ltr == 0 { return .natural }
        return rtl > ltr ? .rightToLeft : .leftToRight
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
        let resting = max(0, size.height - rect.maxY) + rect.height * SubtitleAdjustments.bottomMarginFraction
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

/// Draws past its text so a stroke or shadow is not cut off at the bounds: `bleed`
/// is how far its frame reaches beyond the text. Text sits on the top of its rect, whole
/// points when the frame is, and strokes join round as Apple's do.
private final class CaptionTextLabel: UILabel {
    var bleed: CGFloat = 0

    override func drawText(in rect: CGRect) {
        UIGraphicsGetCurrentContext()?.setLineJoin(.round)
        var text = rect.insetBy(dx: bleed, dy: bleed)
        text.size.height = textRect(forBounds: text, limitedToNumberOfLines: 0).height
        super.drawText(in: text)
    }
}

/// One cue: the window behind it all, a background behind each line, then the text.
///
/// Keeps the author's line breaks; shorter lines align to `alignment`.
private final class CaptionBoxView: UIView {

    private let label = CaptionTextLabel()
    /// The uniform and drop shadow edges' stroke-only copy of the text, under `label`.
    /// Stroking the fill itself centres the stroke on the glyph edge, which
    /// thins the letters and draws SF's overlapping contours inside them (#422).
    private var strokeLabel: CaptionTextLabel?
    private var lineBackgrounds: [UIView] = []
    private let body: AetherSubtitleCue.Body
    private let style: CaptionStyle
    private let colorScale: CGFloat

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

    init(body: AetherSubtitleCue.Body, style: CaptionStyle, alignment: NSTextAlignment = .center, isHDR: Bool = false) {
        self.body = body
        self.style = style
        self.alignment = alignment
        self.colorScale = isHDR ? CaptionOverlayView.Metrics.hdrColorScale : 1
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        layer.cornerCurve = .circular

        label.numberOfLines = 0
        label.textAlignment = alignment
        label.backgroundColor = .clear
        if style.edge == .uniform || style.edge == .dropShadow {
            let stroke = CaptionTextLabel()
            stroke.numberOfLines = 0
            stroke.textAlignment = alignment
            stroke.backgroundColor = .clear
            addSubview(stroke)
            strokeLabel = stroke
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
        strokeLabel?.attributedText = stroked(text, pointSize: pointSize)
        layer.cornerRadius = (pointSize * style.box.cornerRadius).rounded(.down)
        backgroundColor = scaled(style.windowColor).withAlphaComponent(style.windowOpacity)
        lineBackgrounds.forEach { $0.removeFromSuperview() }
        lineBackgrounds = []
    }

    /// Inset from the box's edge to the text, whole points as Apple's are.
    private var padding: (h: CGFloat, v: CGFloat) {
        let edge = CaptionOverlayView.Metrics.edgeInset(for: style.font(ofSize: appliedPointSize), edge: style.edge)
        let vertical = appliedPointSize * style.box.vertical / 2 + edge
        return ((appliedPointSize * style.box.horizontal / 2 + edge).rounded(),
                edge > 0 ? ceil(vertical) : vertical.rounded())
    }

    /// The box's size for a given wrapping width, inside the box.
    func fittingSize(maxWidth: CGFloat) -> CGSize {
        fittingSize(maxTextWidth: maxWidth - padding.h * 2)
    }

    /// The box's size around text wrapped at a width: its size plus padding.
    func fittingSize(maxTextWidth: CGFloat) -> CGSize {
        guard let text = label.attributedText, text.length > 0 else { return .zero }
        let pad = padding
        let rect = text.boundingRect(
            with: CGSize(width: max(0, maxTextWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        // CoreText's line box takes whole points of ascent and descent; the slack sits under the text.
        let font = style.font(ofSize: appliedPointSize)
        let lineBox = ceil(font.ascender) + ceil(-font.descender) - (font.ascender - font.descender)
        return CGSize(width: ceil(rect.width) + pad.h * 2,
                      height: (rect.height + lineBox).rounded() + pad.v * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pad = padding
        let text = bounds.insetBy(dx: pad.h, dy: pad.v)
        let bleed = (appliedPointSize / 2).rounded(.up)
        for view in [label, strokeLabel].compactMap({ $0 }) {
            view.bleed = bleed
            view.frame = text.insetBy(dx: -bleed, dy: -bleed)
        }
        layoutLineBackgrounds(in: text)
    }

    /// A background behind each line, ascent to descent and as wide as its text. A
    /// label does not report its lines, so TextKit lays the same string out again.
    private func layoutLineBackgrounds(in textFrame: CGRect) {
        lineBackgrounds.forEach { $0.removeFromSuperview() }
        lineBackgrounds = []
        guard style.backgroundOpacity > 0.01, let text = label.attributedText, text.length > 0 else { return }

        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: textFrame.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let storage = NSTextStorage(attributedString: text)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)

        let font = style.font(ofSize: appliedPointSize)
        let color = scaled(style.backgroundColor).withAlphaComponent(style.backgroundOpacity)
        let string = text.string as NSString
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, range, _ in
            var characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            while characters.length > 1,
                  CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: NSMaxRange(characters) - 1)) ?? "x") {
                characters.length -= 1
            }
            let ink = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil), in: container)
            let baseline = rect.minY + manager.location(forGlyphAt: range.location).y
            let background = UIView(frame: CGRect(x: textFrame.minX + ink.minX,
                                                  y: textFrame.minY + baseline - font.ascender,
                                                  width: ink.width,
                                                  height: font.ascender - font.descender))
            background.backgroundColor = color
            background.isUserInteractionEnabled = false
            self.insertSubview(background, at: 0)
            self.lineBackgrounds.append(background)
        }
    }

    /// The text as a black stroke with no fill. Stroke attributes leave glyph
    /// metrics alone, so it lays out exactly under the fill.
    private func stroked(_ text: NSAttributedString, pointSize: CGFloat) -> NSAttributedString {
        let stroke = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: stroke.length)
        stroke.addAttributes([
            .strokeColor: UIColor.black,
            .strokeWidth: CaptionOverlayView.Metrics.strokeWidthPercent(pointSize: pointSize, edge: style.edge)
        ], range: full)
        if style.edge == .dropShadow {
            stroke.addAttribute(.shadow, value: edgeShadow(CGSize.zero), range: full)
        }
        return stroke
    }

    private func edgeShadow(_ offset: CGSize) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black
        shadow.shadowBlurRadius = CaptionOverlayView.Metrics.edgeShadowBlur
        shadow.shadowOffset = offset
        return shadow
    }

    private func scaled(_ color: UIColor) -> UIColor {
        guard colorScale != 1 else { return color }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * colorScale, green: g * colorScale, blue: b * colorScale, alpha: a)
    }

    // MARK: Text

    private var plainText: String {
        switch body {
        case .text(let string): return string
        case .styledText(let runs): return runs.map(\.text).joined()
        case .image, .assEvents: return ""
        }
    }

    /// Builds the cue's attributed string, applying each content attribute only
    /// where the matching system Video Override allows it:
    ///  - colour                                          -> `allowsContentColor`
    ///  - bold/italic/underline/strikethrough, font face   -> `allowsContentFont`
    ///  - relative size                                    -> `allowsContentFontSize`
    ///
    /// A gated-off or content-silent attribute renders the system value. The
    /// system foreground opacity applies either way.
    private func attributedText(pointSize: CGFloat) -> NSAttributedString {
        let userColor = scaled(style.foreground).withAlphaComponent(style.foregroundOpacity)
        let baseFont = style.font(ofSize: pointSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.baseWritingDirection = CaptionOverlayView.baseWritingDirection(for: plainText)
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
                    contentColor.map { scaled($0).withAlphaComponent(style.foregroundOpacity) } ?? userColor
                if style.allowsContentBackground, let background = run.backgroundColor {
                    attributes[.backgroundColor] = background
                }
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

    /// The fill's shadow for the raised, depressed and drop shadow edges.
    private func applyEdge(to text: NSMutableAttributedString, pointSize: CGFloat) {
        let offset = CaptionOverlayView.Metrics.edgeOffset(pointSize: pointSize)
        let direction: CGSize
        switch style.edge {
        case .raised: direction = CGSize(width: -offset, height: -offset)
        case .depressed: direction = CGSize(width: offset, height: offset)
        case .dropShadow: direction = CGSize(width: 0, height: -offset)
        case .uniform, .none: return
        }
        text.addAttribute(.shadow, value: edgeShadow(direction), range: NSRange(location: 0, length: text.length))
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
