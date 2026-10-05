// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

struct IOSAetherSubtitleOverlay: View {
    let cues: [AetherPlayer.SubtitleCue]
    let nativeCues: [AetherPlayer.SubtitleCue]
    let style: CaptionStyle
    let landscapeOSDTop: CGFloat?
    let videoSize: CGSize
    /// Aspect fill crops the picture to the screen, so captions lay out against the screen.
    var fillsScreen = false

    private enum Metrics {
        // iPhone captions need a smaller curve than the 10-foot tvOS UI.
        // 0.039675 is a 25% reduction from tvOS's 0.0529, equivalent to
        // reducing a 0.20 scale factor to 0.15.
        static let fontHeightFraction: CGFloat = 0.039675
        static let minimumPointSize: CGFloat = 10
        static let positionedSafeFraction: CGFloat = 0.10
        static let unpositionedBottomFraction: CGFloat = 0.05
    }

    var body: some View {
        GeometryReader { proxy in
            let allCues = cues + nativeCues
            let pointSize = max(
                Metrics.minimumPointSize,
                min(proxy.size.width, proxy.size.height)
                    * Metrics.fontHeightFraction
                    * style.fontScale
            )
            let picture = pictureRect(in: proxy.size)
            let osdBoundary = landscapeCaptionMaxY(
                in: picture,
                container: proxy.size
            )
            let positionedSafe = positionedSafeRect(in: picture)
            let defaultBand = defaultBandRect(
                in: picture,
                osdBoundary: osdBoundary
            )
            ZStack {
                ForEach(allCues) { cue in
                    if case .image(let image, let position) = cue.body {
                        let frame = adjustedPositionedFrame(
                            CGRect(
                                x: picture.minX + picture.width * position.minX,
                                y: picture.minY + picture.height * position.minY,
                                width: picture.width * position.width,
                                height: picture.height * position.height
                            ),
                            in: picture,
                            osdBoundary: osdBoundary
                        )
                        Image(uiImage: image)
                            .resizable()
                            .frame(
                                width: frame.width,
                                height: frame.height
                            )
                            .position(
                                x: frame.midX,
                                y: frame.midY
                            )
                            .animation(.easeInOut(duration: 0.25), value: osdBoundary)
                    }
                }

                ForEach(allCues) { cue in
                    if cue.hasText, let placement = cue.placement {
                        IOSPositionedCaptionLayout(
                            placement: placement,
                            pictureRect: picture,
                            safeRect: positionedSafe,
                            osdBoundary: osdBoundary
                        ) {
                            subtitleText(cue.body,
                                         pointSize: pointSize,
                                         alignment: Self.lineAlignment(for: placement))
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .animation(.easeInOut(duration: 0.25), value: osdBoundary)
                    }
                }

                VStack(spacing: 6) {
                    ForEach(allCues) { cue in
                        if cue.hasText, cue.placement == nil {
                            subtitleText(cue.body, pointSize: pointSize)
                        }
                    }
                }
                .frame(width: defaultBand.width, height: defaultBand.height, alignment: .bottom)
                .position(x: defaultBand.midX, y: defaultBand.midY)
                .animation(.easeInOut(duration: 0.25), value: osdBoundary)
            }
        }
        .allowsHitTesting(false)
    }

    /// Which edge a positioned cue's lines align to, from the column its own
    /// alignment names. Matches the edge IOSPositionedCaptionLayout anchors the
    /// box on, so the two cannot disagree. Unplaced cues centre, as the default
    /// band always has.
    private static func lineAlignment(
        for placement: AetherPlayer.SubtitleCue.TextPlacement?
    ) -> TextAlignment {
        guard let placement else { return .center }
        switch captionColumn(for: placement) {
        case 0: return .leading
        case 2: return .trailing
        default: return .center
        }
    }

    private func subtitleText(
        _ body: AetherPlayer.SubtitleCue.Body,
        pointSize: CGFloat,
        alignment: TextAlignment = .center
    ) -> some View {
        renderedText(body, pointSize: pointSize)
            // A cue's box hugs its widest line, so a shorter line has slack.
            // Centring that slack is right for a centred cue and wrong for a
            // side-anchored one: the box grows away from its anchor when a later
            // line runs longer, and every shorter line then re-centres in the
            // wider box, so a left-positioned cue's first word visibly slides
            // right as the line beneath it extends. Rolling captions show it as
            // the top line drifting. The anchored edge has to stay put.
            .multilineTextAlignment(alignment)
            .padding(.horizontal, pointSize * 0.30)
            .padding(.vertical, pointSize * 0.075)
            .background(
                style.edge == .uniform
                    ? Color.clear
                    : Color(uiColor: style.backgroundColor).opacity(style.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: pointSize * 0.25)
            )
            .modifier(IOSCaptionEdgeModifier(style: style.edge, pointSize: pointSize))
    }

    private func renderedText(
        _ body: AetherPlayer.SubtitleCue.Body,
        pointSize: CGFloat
    ) -> Text {
        let userColor = Color(uiColor: style.foreground).opacity(style.foregroundOpacity)
        switch body {
        case .text(let string):
            return Text(string)
                .font(Font(style.font(ofSize: pointSize)))
                .foregroundColor(userColor)
        case .styledText(let runs):
            return runs.reduce(Text("")) { result, run in
                let runColor = style.allowsContentColor ? run.color : nil
                var text = Text(run.text)
                    .font(Font(font(for: run, baseSize: pointSize)))
                    .foregroundColor(
                        runColor.map {
                            Color(uiColor: $0).opacity(style.foregroundOpacity)
                        } ?? userColor
                    )
                if style.allowsContentFont {
                    if run.isUnderlined { text = text.underline() }
                    if run.isStruckThrough { text = text.strikethrough() }
                }
                return Text("\(result)\(text)")
            }
        case .image:
            return Text("")
        }
    }

    private func font(
        for run: AetherPlayer.SubtitleCue.StyledRun,
        baseSize: CGFloat
    ) -> UIFont {
        var size = baseSize
        if style.allowsContentFontSize, let contentSize = run.fontSize, contentSize > 0 {
            size *= min(max(CGFloat(contentSize) / 16, 0.5), 2)
        }

        var font: UIFont
        if style.allowsContentFont,
           let name = run.fontName,
           !name.isEmpty,
           let named = UIFont(name: name, size: size) {
            font = named
        } else {
            font = style.font(ofSize: size)
        }

        guard style.allowsContentFont else { return font }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if run.isBold { traits.insert(.traitBold) }
        if run.isItalic { traits.insert(.traitItalic) }
        if !traits.isEmpty,
           let descriptor = font.fontDescriptor.withSymbolicTraits(
               font.fontDescriptor.symbolicTraits.union(traits)
           ) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
    }

    private func pictureRect(in container: CGSize) -> CGRect {
        guard !fillsScreen, videoSize.width > 0, videoSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func positionedSafeRect(in picture: CGRect) -> CGRect {
        picture.insetBy(
            dx: picture.width * Metrics.positionedSafeFraction,
            dy: picture.height * Metrics.positionedSafeFraction
        )
    }

    /// Matches the subtitle-refinement renderer: clamp authored text and DVB/
    /// PGS bitmap boxes into the picture's central 80%, then move an overlapping
    /// cue only far enough upward to keep the 5%-of-picture OSD clearance.
    private func adjustedPositionedFrame(
        _ frame: CGRect,
        in picture: CGRect,
        osdBoundary: CGFloat?
    ) -> CGRect {
        let safe = positionedSafeRect(in: picture)
        let maxX = max(safe.minX, safe.maxX - frame.width)
        var originX = min(max(frame.minX, safe.minX), maxX)
        let maxY = max(safe.minY, safe.maxY - frame.height)
        var originY = min(max(frame.minY, safe.minY), maxY)

        if let osdBoundary {
            originY = min(originY, osdBoundary - frame.height)
            originY = max(picture.minY, originY)
        }

        if !originX.isFinite { originX = safe.minX }
        if !originY.isFinite { originY = safe.minY }
        return CGRect(origin: CGPoint(x: originX, y: originY), size: frame.size)
    }

    private func defaultBandRect(
        in picture: CGRect,
        osdBoundary: CGFloat?
    ) -> CGRect {
        let sideInset = picture.width * Metrics.positionedSafeFraction
        let restingMaxY = picture.maxY
            - picture.height * Metrics.unpositionedBottomFraction
        let maxY = min(restingMaxY, osdBoundary ?? restingMaxY)
        return CGRect(
            x: picture.minX + sideInset,
            y: picture.minY,
            width: max(0, picture.width - sideInset * 2),
            height: max(0, maxY - picture.minY)
        )
    }

    private func landscapeCaptionMaxY(
        in picture: CGRect,
        container: CGSize
    ) -> CGFloat? {
        guard container.width > container.height, let landscapeOSDTop else { return nil }
        return min(
            picture.maxY,
            landscapeOSDTop - picture.height * Metrics.unpositionedBottomFraction
        )
    }
}

private extension AetherPlayer.SubtitleCue {
    var hasText: Bool {
        switch body {
        case .text(let text): return !text.isEmpty
        case .styledText(let runs): return runs.contains { !$0.text.isEmpty }
        case .image: return false
        }
    }
}

/// Which column a positioned cue anchors to: 0 leading, 1 centre, 2 trailing.
///
/// An explicit numpad `alignment` wins. When the source gives none, a fine
/// `position.x` STILL names an edge: WebVTT's `position:` is the box's start
/// edge, not its centre, so a cue placed on the left must anchor leading.
/// Centre-anchoring it is what let a longer second line widen the box
/// symmetrically and drag the first line sideways.
///
/// The layout and the line alignment both read this, so the edge the box is
/// pinned on and the edge the lines align to cannot disagree.
private func captionColumn(for placement: AetherPlayer.SubtitleCue.TextPlacement) -> Int {
    if let alignment = placement.alignment {
        return (min(max(alignment, 1), 9) - 1) % 3
    }
    guard let x = placement.position?.x else { return 1 }
    if x <= 0.4 { return 0 }
    if x >= 0.6 { return 2 }
    return 1
}

/// Places a content-positioned text cue inside the visible picture's title-safe
/// region. Fine x positions belong to the left/centre/right caption-box edge
/// selected by the cue alignment; fine y positions name the box's top edge.
/// Coarse ASS/teletext positions resolve to the corresponding 10/50/90% band.
/// The measured box is clamped after wrapping, matching subtitle-refinement.
private struct IOSPositionedCaptionLayout: Layout {
    let placement: AetherPlayer.SubtitleCue.TextPlacement
    let pictureRect: CGRect
    let safeRect: CGRect
    let osdBoundary: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first, safeRect.width > 0, safeRect.height > 0 else { return }

        let fitted = subview.sizeThatFits(
            ProposedViewSize(width: safeRect.width, height: safeRect.height)
        )
        let width = min(fitted.width, safeRect.width)
        let height = min(fitted.height, safeRect.height)
        let alignment = min(max(placement.alignment ?? 2, 1), 9)
        let column = captionColumn(for: placement)
        let row = (alignment - 1) / 3

        let anchorX: CGFloat
        if let x = placement.position?.x {
            anchorX = pictureRect.minX
                + min(max(x, 0.10), 0.90) * pictureRect.width
        } else if column == 0 {
            anchorX = pictureRect.minX + pictureRect.width * 0.10
        } else if column == 2 {
            anchorX = pictureRect.minX + pictureRect.width * 0.90
        } else {
            anchorX = pictureRect.midX
        }

        let requestedX: CGFloat
        switch column {
        case 0: requestedX = anchorX
        case 2: requestedX = anchorX - width
        default: requestedX = anchorX - width / 2
        }

        let requestedY: CGFloat
        if let y = placement.position?.y {
            // Fine positions describe the caption box's top edge.
            requestedY = pictureRect.minY
                + min(max(y, 0.10), 0.90) * pictureRect.height
        } else if row == 2 {
            requestedY = pictureRect.minY + pictureRect.height * 0.10
        } else if row == 1 {
            requestedY = pictureRect.midY - height / 2
        } else {
            requestedY = pictureRect.minY + pictureRect.height * 0.90 - height
        }

        let maximumX = max(safeRect.minX, safeRect.maxX - width)
        let originX = min(max(requestedX, safeRect.minX), maximumX)
        let maximumY = max(safeRect.minY, safeRect.maxY - height)
        var originY = min(max(requestedY, safeRect.minY), maximumY)
        if let osdBoundary {
            originY = min(originY, osdBoundary - height)
            originY = max(pictureRect.minY, originY)
        }
        subview.place(
            at: CGPoint(x: originX, y: originY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: height)
        )
    }
}

private struct IOSCaptionEdgeModifier: ViewModifier {
    let style: CaptionStyle.Edge
    let pointSize: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let depth = max(1, pointSize * 0.04)
        switch style {
        case .none:
            content
        case .dropShadow:
            content.shadow(color: .black.opacity(0.85), radius: 3, y: 1)
        case .raised:
            content.shadow(color: .black.opacity(0.9), radius: 0, x: depth, y: depth)
        case .depressed:
            content.shadow(color: .black.opacity(0.9), radius: 0, x: -depth, y: -depth)
        case .uniform:
            content
                .shadow(color: .black, radius: 0, x: depth, y: 0)
                .shadow(color: .black, radius: 0, x: -depth, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: depth)
                .shadow(color: .black, radius: 0, x: 0, y: -depth)
        }
    }
}
