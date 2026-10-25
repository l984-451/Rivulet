// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherSubtitleCue.swift
//  Rivulet
//
//  Rivulet-side subtitle cue (text and bitmap bodies), converted from the engine's
//  cue in AetherPlayer. `AetherEngine.SubtitleCue` cannot be named here: the module
//  and a class share the name, and bare `SubtitleCue` is Rivulet's text-only type.
//

import CoreGraphics
import UIKit

/// A subtitle cue ready for the Aether host overlay to paint.
struct AetherSubtitleCue: Identifiable {
    let id: Int
    let startTime: Double
    let endTime: Double
    let body: Body
    /// Content-specified placement, or nil to use the overlay's default band.
    /// Defaulted so the Live TV legible bridge, which builds cues by hand
    /// from AVPlayer's attributed strings, does not have to pass it.
    var placement: TextPlacement? = nil

    /// Text dialogue, or a positioned bitmap (PGS / DVB / DVD).
    enum Body {
        case text(String)
        /// Text with the content's own per-run styling. The renderer decides,
        /// per `CaptionStyle.allowsContent*`, whether to paint it.
        case styledText([StyledRun])
        /// `position` is the bitmap's origin+size in [0, 1] of the source
        /// video frame; the overlay multiplies by the on-screen video rect.
        case image(cgImage: CGImage, position: CGRect)
        /// Raw ASS event lines (`ReadOrder,Layer,Style,...,Text`), one per
        /// line, from an ASS/SSA track under the engine's
        /// `preserveASSMarkup`. libass draws them (`ASSOverlayView`); with
        /// Video Override pinned the overlay draws their plain text instead.
        case assEvents(String)
    }

    /// One run of a styled text cue, mirroring AetherEngine's `SubtitleTextRun`.
    /// nil or false means the content was silent and the system value applies.
    struct StyledRun: Hashable {
        var text: String
        var color: UIColor?
        /// Background behind this run's glyphs (WebVTT `bg_*` classes), drawn
        /// over the system caption box where `allowsContentBackground` allows.
        var backgroundColor: UIColor?
        var isBold: Bool = false
        var isItalic: Bool = false
        var isUnderlined: Bool = false
        var isStruckThrough: Bool = false
        /// Face the content asked for (ASS `\fn`, SRT `<font face=>`).
        var fontName: String?
        /// Size the content asked for (ASS `\fs`), relative to the script's nominal size.
        var fontSize: Int?
    }

    /// Placement the content asked for (ASS `\an` / `\pos`); nil means the usual
    /// band. Always honoured, and the Height stepper does not move it.
    struct TextPlacement: Hashable {
        /// ASS numpad alignment: 1 bottom-left through 9 top-right, 5 centred.
        var alignment: Int?
        /// `\pos` anchor normalized to [0, 1] against the video frame, y from
        /// the top — the same convention `SubtitleImage.position` uses.
        var position: CGPoint?
        /// WebVTT snap-to-lines `line:` as written: 0 is the first line from
        /// the top, -1 the last line at the bottom. Needs the rendered line
        /// height, so only the overlay can resolve it. `position.y` wins.
        var lineNumber: Int? = nil
    }

    /// Content identity: collapses the engine's re-decode duplicates while
    /// simultaneous speakers (same start, different text) stay distinct.
    var contentKey: ContentKey {
        ContentKey(startTime: startTime, endTime: endTime, body: body, placement: placement)
    }

    /// Hashable projection of a cue's content.
    ///
    /// Image bodies key off the CGImage's *reference identity* plus the
    /// position rect — never pixel contents. Comparing pixels would be
    /// expensive, and a decoder reset that re-emits the same packet yields
    /// the same (or an equivalent) decoded image object. If two image cues
    /// share start/end/position but carry different CGImage refs we keep both:
    /// conservative, never drop a cue we cannot prove is a duplicate.
    struct ContentKey: Hashable {
        enum BodyKey: Hashable {
            case text(String)
            case styledText([StyledRun])
            case image(image: ObjectIdentifier, position: CGRect)
            case assEvents(String)
        }

        let startTime: Double
        let endTime: Double
        let body: BodyKey
        let placement: TextPlacement?

        init(startTime: Double, endTime: Double, body: Body, placement: TextPlacement?) {
            self.startTime = startTime
            self.endTime = endTime
            self.placement = placement
            switch body {
            case .text(let string):
                self.body = .text(string)
            case .styledText(let runs):
                self.body = .styledText(runs)
            case .image(let cgImage, let position):
                self.body = .image(image: ObjectIdentifier(cgImage), position: position)
            case .assEvents(let lines):
                self.body = .assEvents(lines)
            }
        }
    }
}

/// The active ASS/SSA track's script header plus the loaded file's embedded
/// fonts, mapped from the engine at the AetherPlayer boundary. A class so the
/// overlay can tell tracks apart by identity without comparing font payloads
/// (10 to 30 MB): AetherPlayer publishes a new instance per track and per load.
final class ASSTrackSource {
    let trackId: Int
    let header: String
    let fonts: [LibassRenderer.Font]

    init(trackId: Int, header: String, fonts: [LibassRenderer.Font]) {
        self.trackId = trackId
        self.header = header
        self.fonts = fonts
    }
}
