//
//  AetherSubtitleOverlayView.swift
//  Rivulet
//
//  SwiftUI overlay that renders subtitle cues from a SubtitleModel.
//  Mounted in UniversalPlayerView above the video surface, below the
//  UIKit transport bar hosted by PlayerContainerViewController.
//
//  controlsVisible insets (matched to SubtitleOverlayView on the AVPlayer
//  routes, so subtitles sit at the same height on every route):
//    true  -> 368 pt bottom padding (rail bottom inset 84 + railHeight 260
//             + 24 gap; clears the 3a glass rail)
//    false -> 100 pt bottom padding (same resting height as the AVPlayer
//             route's SubtitleOverlayView, mirroring native caption placement)
//

import SwiftUI

// MARK: - AetherSubtitleOverlayView

struct AetherSubtitleOverlayView: View {

    @ObservedObject var model: SubtitleModel

    /// Current caption appearance. Replaced wholesale on CaptionAppearance changes.
    var style: CaptionStyle

    /// True when the player rail is visible; lifts text above it.
    var controlsVisible: Bool

    // Bottom padding constants (pts). controlsVisiblePadding =
    // PlayerRailView.railHeight (260) + rail bottom inset (84) + 24 gap.
    // defaultPadding matches SubtitleOverlayView's resting bottomOffset (100)
    // on the AVPlayer route, which mirrors native AVPlayer caption placement —
    // 60 sat visibly too close to the screen edge.
    private static let controlsVisiblePadding: CGFloat = 368
    private static let defaultPadding: CGFloat = 100

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Bitmap cues: render all simultaneously (PGS can emit multiples).
                //
                // Keyed by contentKey, NOT by cue.id: the engine's cue id is a
                // per-decoder monotonic counter that restarts at 0 whenever a
                // seek resets the decoder, so it collides with older cues still
                // in the array and hands SwiftUI duplicate ForEach identities.
                ForEach(model.activeCues.filter(\.isBitmap), id: \.contentKey) { cue in
                    if case .image(let cgImage, let pos) = cue.body {
                        bitmapCue(cgImage: cgImage, position: pos, size: geo.size)
                    }
                }

                // Text cues: stack vertically at bottom-centre. Also keyed by
                // contentKey; see the note above.
                //
                // ORDER MATTERS: the bottom padding must be applied INSIDE the
                // full-screen frame (padding first, then frame). Padding after
                // the frame grows the composite beyond the screen — the frame
                // stays screen-height, the ZStack top-anchors it, and the
                // padding hangs invisibly off the bottom edge, so the inset
                // never lifted the text at all (subs sat glued to the edge and
                // the rail lift was a no-op).
                VStack(spacing: 4) {
                    ForEach(model.activeCues.filter(\.isText), id: \.contentKey) { cue in
                        styledText(cue.body, size: geo.size)
                    }
                }
                .padding(.bottom, controlsVisible
                    ? Self.controlsVisiblePadding
                    : Self.defaultPadding)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Bitmap cue

    @ViewBuilder
    private func bitmapCue(cgImage: CGImage, position: CGRect, size: CGSize) -> some View {
        let frameW = position.width  * size.width
        let frameH = position.height * size.height
        let originX = position.minX  * size.width
        let originY = position.minY  * size.height

        Image(decorative: cgImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: frameW, height: frameH)
            .offset(x: originX, y: originY)
    }

    // MARK: - Text cue

    @ViewBuilder
    private func styledText(_ body: AetherSubtitleCue.Body, size: CGSize) -> some View {
        let maxWidth = max(0, size.width - 240)
        // System conformance: the user's chosen caption font (via the
        // MediaAccessibility font descriptor) and text opacity apply, not
        // just color/size/edge. Base size 42 matches SubtitleOverlayView on
        // the HLS route so captions render identically across routes.
        let baseFont = style.font(ofSize: 42 * style.fontScale)

        switch style.edge {
        case .dropShadow:
            cueText(body)
                .font(baseFont)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(style.backgroundColor.opacity(style.backgroundOpacity))
                )
                .frame(maxWidth: maxWidth)

        case .uniform:
            // 8-direction black outline (no per-character stroke on tvOS).
            let offsets: [(CGFloat, CGFloat)] = [
                (-2, -2), ( 0, -2), ( 2, -2),
                (-2,  0),           ( 2,  0),
                (-2,  2), ( 0,  2), ( 2,  2)
            ]
            ZStack {
                ForEach(Array(offsets.enumerated()), id: \.offset) { _, delta in
                    Text(body.plainText)
                        .font(baseFont)
                        .foregroundStyle(Color.black)
                        .multilineTextAlignment(.center)
                        .offset(x: delta.0, y: delta.1)
                }
                cueText(body)
                    .font(baseFont)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: maxWidth)

        default:
            // .none / .raised / .depressed: solid background box.
            cueText(body)
                .font(baseFont)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(style.backgroundColor.opacity(style.backgroundOpacity))
                )
                .frame(maxWidth: maxWidth)
        }
    }

    /// Builds the cue's `Text` with the colour policy applied per run:
    ///  - Video Override ON (`style.allowsContentColor`): a run's
    ///    content-specified colour wins; unstyled runs get the user colour.
    ///  - Video Override OFF: everything renders in the user's colour.
    /// The system foreground opacity applies to both.
    private func cueText(_ body: AetherSubtitleCue.Body) -> Text {
        let userColor = style.foreground.opacity(style.foregroundOpacity)
        switch body {
        case .text(let string):
            return Text(string).foregroundStyle(userColor)
        case .styledText(let runs):
            return runs.reduce(Text(verbatim: "")) { acc, run in
                let color: Color
                if style.allowsContentColor, let contentColor = run.color {
                    color = contentColor.opacity(style.foregroundOpacity)
                } else {
                    color = userColor
                }
                return acc + Text(run.text).foregroundStyle(color)
            }
        case .image:
            return Text(verbatim: "")
        }
    }
}

// MARK: - AetherSubtitleCue helpers

private extension AetherSubtitleCue {
    var isText: Bool {
        switch body {
        case .text, .styledText: return true
        case .image: return false
        }
    }
    var isBitmap: Bool {
        if case .image = body { return true }
        return false
    }
}

private extension AetherSubtitleCue.Body {
    /// Flattened text — used for the uniform-edge outline layers, which are
    /// always solid black regardless of run colours.
    var plainText: String {
        switch self {
        case .text(let string): return string
        case .styledText(let runs): return runs.map(\.text).joined()
        case .image: return ""
        }
    }
}
