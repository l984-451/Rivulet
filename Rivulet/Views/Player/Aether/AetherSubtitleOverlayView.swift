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
//    - with the rail up, the same margin is measured off the rail's top edge
//      (344 pt) instead, so the caption keeps its distance either way; shared
//      with the HLS-route overlay via SubtitleAdjustments so the routes agree
//
//  That margin is a FLOOR every cue obeys (`placementFloor`). A cue carrying
//  its own placement keeps it while it sits at or above the floor and is
//  raised to it otherwise, so a WebVTT `line:100%` or a bottom teletext row
//  lands where captions belong rather than against the edge of the picture.
//  Only the user's Height stepper is placement-exempt.
//
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

    /// Height adjustment for THIS media, in stepper units. Sticky per title /
    /// channel like the delay stepper and defaulting to 0.
    ///
    /// Pushed in by the host rather than read from defaults here: the key
    /// changes under a channel switch or a next-episode swap while the view
    /// keeps its identity, and re-binding a dynamic-key `@AppStorage` across
    /// that is not something to rely on.
    var heightUnits: Int = 0

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

    /// Inset for an edge-aligned positioned cue, so `\an7` does not sit hard
    /// against the corner of the picture.
    private static let placedInset: CGFloat = 40

    /// Nominal ASS font size that a cue's `\fs` is judged against. libavcodec
    /// synthesises its ASS lines at a 384x288 play resolution whose default
    /// style is 16pt, so `\fs32` means "twice normal", not "32 points".
    private static let assNominalFontSize: CGFloat = 16

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

    /// The lowest any caption may sit, as a distance from the bottom of the
    /// CONTAINER. EVERY cue obeys this, placed or not.
    ///
    /// Two anchors compete and the larger wins: the caption must sit
    /// `SubtitleAdjustments.bottomMarginFraction` of the PICTURE above its
    /// bottom edge (so letterboxed
    /// content is not captioned into its black bar), and it must clear the
    /// rail when the rail is up (which is anchored to the SCREEN). Taking the
    /// max means a 2.39:1 film with the rail hidden lifts by its letterbox,
    /// while the same film with the rail up still clears the chrome.
    ///
    /// A cue that asked to sit LOWER than this — a WebVTT `line:100%`, a
    /// teletext bottom row — is raised to it rather than being drawn against
    /// the edge of the picture. Only a cue asking to sit HIGHER keeps its own
    /// position. Live TV is almost entirely placed cues, so exempting them
    /// here is what made its captions sit lower than VOD's.
    private func placementFloor(in bounds: CGSize) -> CGFloat {
        let rect = videoRect(in: bounds)
        let letterbox = max(0, bounds.height - rect.maxY)
        var base = letterbox + rect.height * SubtitleAdjustments.bottomMarginFraction
        if controlsVisible {
            // Same margin, measured off the rail's top edge instead of the
            // picture's bottom, so the caption keeps its distance either way.
            base = max(base, SubtitleAdjustments.controlsFloor(pictureHeight: rect.height))
        }
        return base
    }

    /// Distance from the bottom of the CONTAINER to an UNPLACED cue: the
    /// shared floor plus the user's Height stepper, which applies to the
    /// default band only.
    private func bottomPadding(in bounds: CGSize) -> CGFloat {
        max(0, placementFloor(in: bounds) + SubtitleAdjustments.heightOffset(forUnits: heightUnits))
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
                // Unpositioned text cues: the default bottom band, and the
                // ONLY place the user's Height adjustment applies.
                VStack(spacing: Self.cueSpacing) {
                    ForEach(model.activeCues.filter { $0.isText && $0.placement == nil },
                            id: \.contentKey) { cue in
                        styledText(cue.body, size: geo.size)
                    }
                }
                .padding(.bottom, bottomPadding(in: geo.size))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)

                // Cues the SOURCE placed (ASS \an / \pos — signs, top-of-frame
                // captions the broadcaster moved off on-screen graphics).
                // Positioned against the picture, and deliberately exempt from
                // the Height stepper: an authored position must not drift with
                // an app-level offset.
                ForEach(model.activeCues.filter { $0.isText && $0.placement != nil },
                        id: \.contentKey) { cue in
                    if let placement = cue.placement {
                        placedCue(cue.body, placement: placement, size: geo.size)
                    }
                }
            }
            // Both bands move only when the rail appears or dismisses, so the
            // lift reads as the captions sliding out of the chrome's way
            // rather than snapping. Cues the rail never covered are unaffected
            // by definition — their geometry doesn't change.
            //
            // Matches the chrome's own fade: `UIView.animate(withDuration:)`
            // with no options is a 0.25s ease-in-out, so the caption travels
            // on exactly the curve the rail arrives on. Keep these in step —
            // PlayerContainerViewController.applyChromeVisibility and the Live
            // TV showRail/hideRail pair are the other half.
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Bitmap cue

    @ViewBuilder
    private func bitmapCue(cgImage: CGImage, position: CGRect, size: CGSize) -> some View {
        // `SubtitleImage.position` is normalized against the SOURCE VIDEO
        // FRAME, not the player's bounds — upstream is explicit that a host
        // maps it onto the on-screen video rect, and `SubtitleTextPlacement`
        // shares the convention (AE #233). Multiplying by the full bounds
        // put PGS/DVB cues wrong on anything letterboxed: a 2.39:1 film
        // stretched them vertically and pushed them toward the black bar.
        // Falls back to the full bounds when the video size is unknown,
        // which is what the old behaviour assumed anyway.
        let rect = videoRect(in: size)
        let frameW = position.width  * rect.width
        let frameH = position.height * rect.height
        let originX = rect.minX + position.minX * rect.width
        let originY = rect.minY + position.minY * rect.height

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
                    // Outline layers are always solid black, but keep the
                    // per-run fonts so the outline tracks styled glyphs.
                    cueText(body, baseSize: pointSize, forcedColor: .black)
                        .font(baseFont)
                        .multilineTextAlignment(.center)
                        .lineSpacing(Self.textLineSpacing)
                        .offset(x: delta.0, y: delta.1)
                }
                cueText(body, baseSize: pointSize)
                    .font(baseFont)
                    .multilineTextAlignment(.center)
                    .lineSpacing(Self.textLineSpacing)
            }
            .frame(maxWidth: maxWidth)

        case .dropShadow:
            boxed(cueText(body, baseSize: pointSize).font(baseFont),
                  maxWidth: maxWidth, fontSize: pointSize)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)

        default:
            // .none / .raised / .depressed: solid background box.
            boxed(cueText(body, baseSize: pointSize).font(baseFont),
                  maxWidth: maxWidth, fontSize: pointSize)
        }
    }

    /// A cue the source positioned itself, placed against the PICTURE (so a
    /// letterboxed film's signs land on the image, not in the black bar).
    ///
    /// Alignment and anchor are used TOGETHER, not either/or: in ASS the
    /// numpad alignment names WHICH POINT OF THE TEXT BOX sits at the `\pos`
    /// anchor, so `\an1` puts the box's bottom-left there and `\an8` its
    /// top-centre. Centring on the anchor regardless (what a bare
    /// `.position()` does) is only right for `\an5`. The engine relies on
    /// this: for a WebVTT percentage `line` it picks the anchoring edge so a
    /// two-line cue cannot hang off frame, and expresses that choice through
    /// the alignment (AE 5.27.0).
    ///
    /// Anchoring is done with edge insets rather than by measuring the
    /// rendered text, so it needs no size pass: pinning an edge of a
    /// full-picture frame at a fraction of the picture puts that edge exactly
    /// on the anchor. The two centred axes fall back to an offset from
    /// centre, which is the same thing expressed the only way SwiftUI allows.
    @ViewBuilder
    private func placedCue(_ body: AetherSubtitleCue.Body,
                           placement: AetherSubtitleCue.TextPlacement,
                           size: CGSize) -> some View {
        let rect = videoRect(in: size)
        // Numpad: rows 7-9 top, 4-6 middle, 1-3 bottom; columns 1/4/7 left,
        // 2/5/8 centre, 3/6/9 right. 2 (bottom-centre) is the ASS default.
        let an = placement.alignment ?? 2
        let col = (an - 1) % 3
        let row = (an - 1) / 3

        let horizontal: HorizontalAlignment = col == 0 ? .leading : col == 2 ? .trailing : .center
        let vertical: VerticalAlignment = row == 2 ? .top : row == 1 ? .center : .bottom

        // Clamped so a wild coordinate cannot push a caption off screen.
        let ax = placement.position.map { min(max($0.x, 0), 1) }
        let ay = placement.position.map { min(max($0.y, 0), 1) }

        // Inset from the pinned edge = the anchor's distance from that edge.
        // With no anchor this is the plain edge inset, which is the teletext
        // and bare-\an case.
        let leading   = (col == 0 ? ax.map { $0 * rect.width } : nil) ?? (col == 0 ? Self.placedInset : 0)
        let trailing  = (col == 2 ? ax.map { (1 - $0) * rect.width } : nil) ?? (col == 2 ? Self.placedInset : 0)
        let top       = (row == 2 ? ay.map { $0 * rect.height } : nil) ?? (row == 2 ? Self.placedInset : 0)

        // A placed cue keeps the position it asked for only while that position
        // is at or above the shared floor — the same 6%-of-picture baseline
        // every other cue rests on, raised to clear the rail when the rail is
        // up. Anything lower is lifted to it.
        //
        // This is `bottomPadding` minus the Height stepper, which stays
        // exempt: an authored position must not drift with an app-level
        // offset, but it should still land where captions belong.
        let letterbox = max(0, size.height - rect.maxY)
        let floor = placementFloor(in: size)

        let requestedBottom = (ay.map { (1 - $0) * rect.height }) ?? Self.placedInset
        let bottom = row == 0 ? max(requestedBottom, max(0, floor - letterbox)) : 0

        // A centred axis cannot be expressed as an inset, so shift it off centre.
        let dx = (col == 1 ? ax.map { ($0 - 0.5) * rect.width } : nil) ?? 0
        // A centred cue pushed far enough down lands behind the rail too, so
        // the same floor caps the shift. Approximate — this pins the cue's
        // CENTRE rather than its bottom edge, which the inset paths do exactly
        // — but a mid-anchored cue is rare and slightly high beats covered.
        let centreDY = (row == 1 ? ay.map { ($0 - 0.5) * rect.height } : nil) ?? 0
        let maxCentreDY = size.height - floor - rect.minY - rect.height / 2
        let dy = row == 1 ? min(centreDY, maxCentreDY) : centreDY

        styledText(body, size: size)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .frame(width: rect.width, height: rect.height,
                   alignment: Alignment(horizontal: horizontal, vertical: vertical))
            .offset(x: rect.minX + dx, y: rect.minY + dy)
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
    /// Builds the cue's `Text`, applying each content attribute only where
    /// the matching system Video Override allows it:
    ///  - colour                → `allowsContentColor`
    ///  - bold/italic/underline/strikethrough, font face → `allowsContentFont`
    ///  - relative size         → `allowsContentFontSize`
    /// A gated-off or content-silent attribute renders the system value. The
    /// system foreground opacity applies either way.
    ///
    /// `forcedColor` repaints every run in one colour while KEEPING per-run
    /// fonts, so the uniform-edge outline layers track styled glyph metrics
    /// instead of misaligning under a bold or resized run.
    private func cueText(_ body: AetherSubtitleCue.Body,
                         baseSize: CGFloat,
                         forcedColor: Color? = nil) -> Text {
        let userColor = style.foreground.opacity(style.foregroundOpacity)
        switch body {
        case .text(let string):
            return Text(string).foregroundStyle(forcedColor ?? userColor)
        case .styledText(let runs):
            return runs.reduce(Text(verbatim: "")) { acc, run in
                var piece = Text(run.text)

                let contentColor = style.allowsContentColor ? run.color : nil
                piece = piece.foregroundStyle(
                    forcedColor ?? contentColor?.opacity(style.foregroundOpacity) ?? userColor)

                // A run's own font only replaces the system caption font when
                // it actually asks for something; otherwise the outer .font()
                // modifier applies and the user's face is preserved.
                if let font = runFont(for: run, baseSize: baseSize) {
                    piece = piece.font(font)
                }
                if style.allowsContentFont {
                    if run.isUnderlined { piece = piece.underline() }
                    if run.isStruckThrough { piece = piece.strikethrough() }
                }
                return acc + piece
            }
        case .image:
            return Text(verbatim: "")
        }
    }

    /// The font for one run, or nil when the content asked for nothing and
    /// the view-level caption font should apply unchanged.
    private func runFont(for run: AetherSubtitleCue.StyledRun, baseSize: CGFloat) -> Font? {
        let wantsFace = style.allowsContentFont && (run.isBold || run.isItalic || run.fontName != nil)
        let scale = contentSizeScale(for: run)
        guard wantsFace || scale != nil else { return nil }

        let size = baseSize * (scale ?? 1)
        // A content font FACE is honoured by name; an unknown name falls back
        // to the system caption font at the same size rather than to a
        // default that would ignore the user's choice entirely.
        var font: Font
        if style.allowsContentFont, let name = run.fontName, !name.isEmpty {
            font = .custom(name, fixedSize: size)
        } else {
            font = style.font(ofSize: size)
        }
        if style.allowsContentFont {
            if run.isBold { font = font.bold() }
            if run.isItalic { font = font.italic() }
        }
        return font
    }

    /// A run's `\fs` as a multiplier, or nil when it asks for nothing.
    ///
    /// `fontSize` is in ASS play-resolution points, so it is meaningful only
    /// RELATIVE to the script's nominal size — libavcodec's synthesised lines
    /// use a 384x288 play resolution whose default style is 16pt. Treating it
    /// as a point size directly would make a `\fs20` line tiny. Clamped so a
    /// wild value cannot fill the screen.
    private func contentSizeScale(for run: AetherSubtitleCue.StyledRun) -> CGFloat? {
        guard style.allowsContentFontSize, let size = run.fontSize, size > 0 else { return nil }
        let ratio = CGFloat(size) / Self.assNominalFontSize
        guard abs(ratio - 1) > 0.01 else { return nil }
        return min(max(ratio, 0.5), 2.0)
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

