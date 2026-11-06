// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

struct IOSAetherSubtitleOverlay: View {
    let cues: [AetherPlayer.SubtitleCue]
    let nativeCues: [AetherPlayer.SubtitleCue]
    let style: CaptionStyle
    /// The chrome's bottom bar top while it shows; captions lift above it
    /// wherever the picture reaches it (landscape, a filled window, a short one).
    let osdTop: CGFloat?
    let videoSize: CGSize
    /// Aspect fill crops the picture to the screen, so captions lay out against the screen.
    var fillsScreen = false

    fileprivate enum Metrics {
        /// AVPlayerViewController's caption line pitch over the video height, per
        /// reported relative size, measured on an iPhone 16 Pro (#307). Not tvOS's
        /// curve and not linear in the reported value: never reduce it to a multiplier.
        static let pitchLadder: [(reported: CGFloat, pitchFraction: CGFloat)] = [
            (0.60, 0.04475),
            (1.00, 0.07215),
            (1.50, 0.11231),
            (2.00, 0.13945)
        ]
        static let minimumPointSize: CGFloat = 8
        static let sideSafeFraction: CGFloat = 0.05
        static let unpositionedBottomFraction: CGFloat = 0.06

        /// Point size whose line pitch matches the ladder, using the caption font's own leading.
        static func pointSize(videoHeight: CGFloat, reported: CGFloat, font: UIFont) -> CGFloat {
            let leading = font.lineHeight / max(font.pointSize, 1)
            return max(minimumPointSize, videoHeight * pitchFraction(forReported: reported) / max(leading, 0.5))
        }

        /// Linear between measured rungs, clamped at the ends.
        static func pitchFraction(forReported reported: CGFloat) -> CGFloat {
            guard let first = pitchLadder.first, let last = pitchLadder.last else { return 0 }
            if reported <= first.reported { return first.pitchFraction }
            for (lo, hi) in zip(pitchLadder, pitchLadder.dropFirst()) where reported <= hi.reported {
                let t = (reported - lo.reported) / (hi.reported - lo.reported)
                return lo.pitchFraction + t * (hi.pitchFraction - lo.pitchFraction)
            }
            return last.pitchFraction
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let allCues = cues + nativeCues
            // `fontScale` is the raw reported size, which is what the ladder is keyed on.
            let pointSize = Metrics.pointSize(
                videoHeight: captionSizingHeight(in: proxy.size),
                reported: style.fontScale,
                font: style.font(ofSize: 100)
            )
            let picture = pictureRect(in: proxy.size)
            let osdBoundary = captionMaxY(in: picture)
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
            // Align lines to the cue's anchored edge: centring a side-anchored cue
            // makes its first line slide as a longer line below it extends the box.
            .multilineTextAlignment(alignment)
            .padding(.horizontal, pointSize * 0.30)
            .padding(.vertical, pointSize * 0.075)
            .background(
                style.edge == .uniform
                    ? Color.clear
                    : Color(uiColor: style.boxColor).opacity(style.boxOpacity),
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
                var base = AttributedString(run.text)
                if style.allowsContentBackground, let background = run.backgroundColor {
                    base.backgroundColor = background
                }
                var text = Text(base)
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

    /// Height captions are sized from: the aspect-fit video height, 16:9 while the
    /// size is unknown (the software decode path never publishes one). Never the
    /// container, which in portrait is about 4x the video band.
    private func captionSizingHeight(in container: CGSize) -> CGFloat {
        let aspect = videoSize.width > 0 && videoSize.height > 0
            ? videoSize.height / videoSize.width
            : 9.0 / 16.0
        return min(container.height, container.width * aspect)
    }

    /// Keeps a bitmap box inside the picture and the side safe inset, then moves
    /// it up only as far as the OSD needs.
    private func adjustedPositionedFrame(
        _ frame: CGRect,
        in picture: CGRect,
        osdBoundary: CGFloat?
    ) -> CGRect {
        let safeMinX = picture.minX + picture.width * Metrics.sideSafeFraction
        let safeMaxX = picture.maxX - picture.width * Metrics.sideSafeFraction
        let maxX = max(safeMinX, safeMaxX - frame.width)
        var originX = min(max(frame.minX, safeMinX), maxX)
        let maxY = max(picture.minY, picture.maxY - frame.height)
        var originY = min(max(frame.minY, picture.minY), maxY)

        if let osdBoundary {
            originY = min(originY, osdBoundary - frame.height)
            originY = max(picture.minY, originY)
        }

        if !originX.isFinite { originX = safeMinX }
        if !originY.isFinite { originY = picture.minY }
        return CGRect(origin: CGPoint(x: originX, y: originY), size: frame.size)
    }

    private func defaultBandRect(
        in picture: CGRect,
        osdBoundary: CGFloat?
    ) -> CGRect {
        let sideInset = picture.width * Metrics.sideSafeFraction
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

    /// Where the bottom bar pushes captions up to. Geometric, not by
    /// orientation: a letterboxed picture that ends above the bar is left alone,
    /// so this is a no-op in portrait on a phone and lifts the band in any
    /// window the picture fills.
    private func captionMaxY(in picture: CGRect) -> CGFloat? {
        guard let osdTop else { return nil }
        return min(picture.maxY, osdTop - picture.height * Metrics.unpositionedBottomFraction)
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
/// An explicit numpad `alignment` wins; otherwise `position.x` names the start
/// edge (WebVTT), so a left cue anchors leading. Layout and line alignment share it.
private func captionColumn(for placement: AetherPlayer.SubtitleCue.TextPlacement) -> Int {
    if let alignment = placement.alignment {
        return (min(max(alignment, 1), 9) - 1) % 3
    }
    guard let x = placement.position?.x else { return 1 }
    if x <= 0.4 { return 0 }
    if x >= 0.6 { return 2 }
    return 1
}

/// Places a content-positioned text cue inside the visible picture. Fine x
/// positions belong to the left/centre/right caption-box edge selected by the
/// cue alignment; fine y positions name the box's top edge. Coarse ASS/teletext
/// positions resolve to the corresponding 10/50/90% band. Same rules as tvOS's
/// `CaptionOverlayView.layoutPlaced`.
private struct IOSPositionedCaptionLayout: Layout {
    let placement: AetherPlayer.SubtitleCue.TextPlacement
    let pictureRect: CGRect
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
        guard let subview = subviews.first, pictureRect.width > 0, pictureRect.height > 0 else { return }

        let alignment = min(max(placement.alignment ?? 2, 1), 9)
        let column = captionColumn(for: placement)
        let row = (alignment - 1) / 3

        let safeMinX = pictureRect.minX + pictureRect.width * IOSAetherSubtitleOverlay.Metrics.sideSafeFraction
        let safeMaxX = pictureRect.maxX - pictureRect.width * IOSAetherSubtitleOverlay.Metrics.sideSafeFraction

        let requestedAnchor: CGFloat
        if let x = placement.position?.x {
            requestedAnchor = pictureRect.minX + min(max(x, 0), 1) * pictureRect.width
        } else if column == 0 {
            requestedAnchor = pictureRect.minX + pictureRect.width * 0.10
        } else if column == 2 {
            requestedAnchor = pictureRect.minX + pictureRect.width * 0.90
        } else {
            requestedAnchor = pictureRect.midX
        }
        let anchor = min(max(requestedAnchor, safeMinX), max(safeMinX, safeMaxX))

        // A side-anchored cue wraps into the room between its anchor and the far
        // safe edge, so a longer line cannot drag the box off its anchor.
        let widthLimit: CGFloat
        switch column {
        case 0: widthLimit = max(0, safeMaxX - anchor)
        case 2: widthLimit = max(0, anchor - safeMinX)
        default: widthLimit = max(0, safeMaxX - safeMinX)
        }

        let fitted = subview.sizeThatFits(
            ProposedViewSize(width: widthLimit, height: pictureRect.height)
        )
        let width = min(fitted.width, widthLimit)
        let height = fitted.height

        let requestedX: CGFloat
        switch column {
        case 0: requestedX = anchor
        case 2: requestedX = anchor - width
        default: requestedX = anchor - width / 2
        }
        let originX = min(max(requestedX, safeMinX), max(safeMinX, safeMaxX - width))

        let requestedY: CGFloat
        if let y = placement.position?.y {
            // Fine positions describe the caption box's top edge.
            requestedY = pictureRect.minY + min(max(y, 0), 1) * pictureRect.height
        } else if row == 2 {
            requestedY = pictureRect.minY + pictureRect.height * 0.10
        } else if row == 1 {
            requestedY = pictureRect.midY - height / 2
        } else {
            requestedY = pictureRect.minY + pictureRect.height * 0.90 - height
        }

        let maximumY = max(pictureRect.minY, pictureRect.maxY - height)
        var originY = min(max(requestedY, pictureRect.minY), maximumY)
        if let osdBoundary {
            originY = min(originY, osdBoundary - height)
            originY = max(pictureRect.minY, originY)
        }
        subview.place(
            at: CGPoint(x: originX.rounded(), y: originY.rounded()),
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
