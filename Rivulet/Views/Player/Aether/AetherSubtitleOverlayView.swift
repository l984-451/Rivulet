// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherSubtitleOverlayView.swift
//  Rivulet
//
//  SwiftUI overlay that renders subtitle cues from a SubtitleModel.
//  Mounted in UniversalPlayerView above the video surface, below the
//  UIKit transport bar hosted by PlayerContainerViewController.
//
//  Sizing and placement mirror AVPlayer's own caption rendering:
//    - point size = a fraction of the PRESENTATION height x the system's
//      relative-character-size multiplier
//    - the resting bottom margin is a fraction of the PICTURE height, so a
//      letterboxed film is captioned on the image, not in its black bar
//    - with the rail up, the screen-anchored rail clearance (368 pt = rail
//      bottom inset 84 + railHeight 260 + 24 gap) wins instead
//  See the Metrics block below for the derivations.
//

import SwiftUI

// MARK: - AetherSubtitleOverlayView

struct AetherSubtitleOverlayView: View {

    @ObservedObject var model: SubtitleModel

    /// Current caption appearance. Replaced wholesale on CaptionAppearance changes.
    var style: CaptionStyle

    /// True when the player rail is visible; lifts text above it.
    var controlsVisible: Bool

    /// The video's presentation size (`AetherPlayer.videoSize`). `.zero` means
    /// "unknown" — the overlay then measures against its full bounds, which is
    /// the pre-existing behaviour and correct for a 16:9 picture filling the
    /// screen.
    var videoSize: CGSize = .zero

    // controlsVisiblePadding = PlayerRailView.railHeight (260) + rail bottom
    // inset (84) + 24 gap; measured from the SCREEN because the rail is
    // screen-anchored.
    private static let controlsVisiblePadding: CGFloat = 368

    /// Distance from the bottom of the PICTURE to the bottom of the caption
    /// box, as a fraction of picture height — so letterboxed content keeps
    /// captions on the image rather than dropping them into the black bar,
    /// and the placement holds at any presentation size.
    ///
    /// Tuned against AVPlayer's own placement (a two-line caption centres at
    /// roughly 8% of picture height). Bottom-anchored rather than
    /// centre-anchored, so a third line grows upward instead of shifting the
    /// whole caption down.
    private static let videoBottomMarginFraction: CGFloat = 0.06

    // MARK: Apple-matching caption metrics
    //
    // Tuned against AVPlayer's own caption rendering (screenshot comparison at
    // the smallest system caption size). Three differences mattered: Apple
    // sizes type from the VIDEO height rather than a fixed point size, boxes
    // the text tightly, and draws one background per LINE rather than one
    // around the whole cue.

    /// Caption point size as a fraction of the PRESENTATION height (the
    /// player's own bounds), before the user's relative-size multiplier.
    ///
    /// The model is: base fraction × the system's own multiplier. The WebVTT
    /// caption spec default is 5% (`5vh`); this sits near it, tuned on device
    /// against AVPlayer's own rendering — at the smallest system caption size
    /// `MACaptionAppearanceGetRelativeCharacterSize` reports 0.35, and
    /// 1080 × 0.0529 × 0.35 = 20pt is the match. Every other size follows
    /// from the multiplier.
    ///
    /// Do NOT re-tune this to compensate for a size problem: if captions are
    /// the wrong size, suspect the multiplier reaching us instead (see
    /// `CaptionAppearance.fontScale`, whose clamp used to swallow 0.35 and
    /// silently flatten the bottom of the range).
    ///
    /// Deliberately NOT the letterboxed picture height: Apple sizes captions
    /// from the presentation and only *positions* them against the picture,
    /// so a 2.39:1 film gets the same type as a 16:9 one rather than shrunken
    /// type. tvOS always presents 1080 points tall regardless of whether the
    /// display is 1080p or 4K, so this is stable across outputs.
    private static let fontHeightFraction: CGFloat = 0.0529

    /// Fallback presentation height, for the degenerate case of a zero-height
    /// layout pass.
    private static let assumedVideoHeight: CGFloat = 1080

    // Box geometry is expressed as MULTIPLES OF THE POINT SIZE, not fixed
    // points, because Apple's caption box grows with the type — at a large
    // caption size a fixed 4pt radius reads as a hard rectangle against much
    // bigger glyphs. The ratios below reproduce the previously tuned 4 / 8 / 2
    // at the smallest setting and scale from there.
    private static let cornerRadiusRatio: CGFloat = 0.15
    private static let paddingHRatio: CGFloat = 0.30
    private static let paddingVRatio: CGFloat = 0.075

    /// Extra leading between the lines of one cue, on top of the font's own
    /// line height. Zero matches Apple, whose caption lines sit on natural
    /// leading inside a single background.
    private static let textLineSpacing: CGFloat = 0

    /// Gap between separate simultaneous cues (two speakers), which SHOULD
    /// read as distinct blocks.
    private static let cueSpacing: CGFloat = 4

    /// User height adjustment from the OSD stepper (global; positive = higher).
    /// Read as @AppStorage so stepping it re-renders the overlay live.
    @AppStorage(SubtitleAdjustments.heightKey) private var heightUnits: Int = 0

    /// The picture's rect inside `bounds`, aspect-fit (how both the engine
    /// surface and AVPlayerLayer place video). Falls back to the full bounds
    /// when the size is unknown.
    private func videoRect(in bounds: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = videoSize.width * scale
        let h = videoSize.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Distance from the bottom of the CONTAINER to the text.
    ///
    /// Two anchors compete and the larger wins: the caption must sit
    /// `videoBottomMargin` above the bottom of the PICTURE (so letterboxed
    /// content is not captioned into its black bar), and it must clear the
    /// rail when the rail is up (which is anchored to the SCREEN). Taking the
    /// max means a 2.39:1 film with the rail hidden lifts by its letterbox,
    /// while the same film with the rail up still clears the chrome.
    private func bottomPadding(in bounds: CGSize) -> CGFloat {
        let rect = videoRect(in: bounds)
        let letterbox = max(0, bounds.height - rect.maxY)
        var base = letterbox + rect.height * Self.videoBottomMarginFraction
        if controlsVisible {
            base = max(base, Self.controlsVisiblePadding)
        }
        return max(0, base + SubtitleAdjustments.heightOffset(forUnits: heightUnits))
    }

    /// Caption point size for this presentation, before per-cue styling.
    private func baseFontSize(in bounds: CGSize) -> CGFloat {
        let height = bounds.height > 0 ? bounds.height : Self.assumedVideoHeight
        return height * Self.fontHeightFraction * style.fontScale
    }

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
                VStack(spacing: Self.cueSpacing) {
                    ForEach(model.activeCues.filter(\.isText), id: \.contentKey) { cue in
                        styledText(cue.body, size: geo.size)
                    }
                }
                .padding(.bottom, bottomPadding(in: geo.size))
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

    /// One cue in ONE rounded box, sized to its longest line.
    ///
    /// A multi-line cue keeps its author's line breaks and stays inside a
    /// single background — the box hugs the widest line and the shorter lines
    /// centre within it. (An earlier attempt boxed each line separately; that
    /// reads as detached labels rather than one caption.)
    @ViewBuilder
    private func styledText(_ body: AetherSubtitleCue.Body, size: CGSize) -> some View {
        let maxWidth = max(0, size.width - 240)
        let pointSize = baseFontSize(in: size)
        let baseFont = style.font(ofSize: pointSize)

        switch style.edge {
        case .uniform:
            // 8-direction black outline (no per-character stroke on tvOS).
            let offsets: [(CGFloat, CGFloat)] = [
                (-2, -2), ( 0, -2), ( 2, -2),
                (-2,  0),           ( 2,  0),
                (-2,  2), ( 0,  2), ( 2,  2)
            ]
            ZStack {
                ForEach(Array(offsets.enumerated()), id: \.offset) { _, delta in
                    // Outline layers are always solid black, so they use the
                    // flattened text rather than the per-run colours.
                    Text(body.plainText)
                        .font(baseFont)
                        .foregroundStyle(Color.black)
                        .multilineTextAlignment(.center)
                        .lineSpacing(Self.textLineSpacing)
                        .offset(x: delta.0, y: delta.1)
                }
                cueText(body)
                    .font(baseFont)
                    .multilineTextAlignment(.center)
                    .lineSpacing(Self.textLineSpacing)
            }
            .frame(maxWidth: maxWidth)

        case .dropShadow:
            boxed(cueText(body).font(baseFont), maxWidth: maxWidth, fontSize: pointSize)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)

        default:
            // .none / .raised / .depressed: solid background box.
            boxed(cueText(body).font(baseFont), maxWidth: maxWidth, fontSize: pointSize)
        }
    }

    /// The tight background box Apple draws behind a caption, with padding and
    /// radius proportional to `fontSize`.
    private func boxed(_ text: some View, maxWidth: CGFloat, fontSize: CGFloat) -> some View {
        text
            .multilineTextAlignment(.center)
            .lineSpacing(Self.textLineSpacing)
            .padding(.horizontal, fontSize * Self.paddingHRatio)
            .padding(.vertical, fontSize * Self.paddingVRatio)
            .background(
                RoundedRectangle(cornerRadius: fontSize * Self.cornerRadiusRatio, style: .continuous)
                    .fill(style.backgroundColor.opacity(style.backgroundOpacity))
            )
            .frame(maxWidth: maxWidth)
    }

    /// Builds the cue's `Text`, applying the colour policy per run:
    ///  - Video Override ON (`style.allowsContentColor`): a run's
    ///    content-specified colour wins; runs without one get the user colour.
    ///  - Video Override OFF: every run renders in the user's colour.
    /// The system foreground opacity applies either way.
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
    /// Flattened text, for the uniform-edge outline layers (always solid
    /// black, so per-run colours are irrelevant there).
    var plainText: String {
        switch self {
        case .text(let string): return string
        case .styledText(let runs): return runs.map(\.text).joined()
        case .image: return ""
        }
    }
}
