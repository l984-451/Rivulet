// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherSubtitleCue.swift
//  Rivulet
//
//  Rivulet-side subtitle cue bridged from AetherEngine.SubtitleCue.
//
//  AetherEngine's SubtitleCue cannot be named inside the Rivulet module:
//  AetherEngine is both the module and a class, so `AetherEngine.SubtitleCue`
//  parses as a nested-type lookup on the class and fails, while the
//  unqualified `SubtitleCue` resolves to Rivulet's own text-only cue
//  type. So AetherPlayer converts Aether's cues into this type at the engine
//  boundary (inside a closure where the element type is inferred). Unlike
//  Rivulet's `SubtitleCue`, this carries BOTH text and bitmap (PGS/DVB)
//  bodies, matching AetherEngine and preserving bitmap subtitle support.
//

import CoreGraphics
import SwiftUI

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
        /// Text carrying the CONTENT's own per-run colour (WebVTT `<c>`
        /// classes, teletext colour codes). Whether a run's colour is painted
        /// or replaced by the user's caption colour is the RENDERER's call —
        /// see `CaptionStyle.allowsContentColor`, which mirrors the system's
        /// "Video Override" setting. The cue always carries what the content
        /// said; the renderer decides whether the user overrode it.
        case styledText([StyledRun])
        /// `position` is the bitmap's origin+size in [0, 1] of the source
        /// video frame; the overlay multiplies by the on-screen video rect.
        case image(cgImage: CGImage, position: CGRect)
    }

    /// One run of a styled text cue, mirroring AetherEngine's
    /// `SubtitleTextRun`. Every field is CONTENT-specified styling; nil /
    /// false means the content was silent and the renderer uses the system
    /// caption value. Whether a content value is painted at all is the
    /// renderer's call, per attribute, against the matching
    /// `CaptionStyle.allowsContent*` (the system "Video Override" states).
    ///
    /// The engine parses these out of the ASS event line libavcodec produces
    /// for every text format, so SRT, WebVTT, teletext and ASS all arrive
    /// here through one path (AE 5.26.0).
    struct StyledRun: Hashable {
        var text: String
        var color: Color?
        var isBold: Bool = false
        var isItalic: Bool = false
        var isUnderlined: Bool = false
        var isStruckThrough: Bool = false
        /// Face the content asked for (ASS `\fn`, SRT `<font face=>`).
        var fontName: String?
        /// Size the content asked for (ASS `\fs`), in ASS play-resolution
        /// points — a RELATIVE hint, not a pixel size, so the renderer scales
        /// it against the script's nominal size rather than using it directly.
        var fontSize: Int?
    }

    /// Placement the content asked for (ASS `\an` / `\pos`), mirroring
    /// AetherEngine's `SubtitleTextPlacement`. nil for nearly every cue,
    /// meaning the host places it in its usual band.
    ///
    /// There is NO system caption setting for position, so no Video Override
    /// gate applies — a content position is always honoured, and the user's
    /// Height stepper deliberately does not move it (a sign pinned to the top
    /// of frame must not drift with an app-level offset).
    struct TextPlacement: Hashable {
        /// ASS numpad alignment: 1 bottom-left through 9 top-right, 5 centred.
        var alignment: Int?
        /// `\pos` anchor normalized to [0, 1] against the video frame, y from
        /// the top — the same convention `SubtitleImage.position` uses.
        var position: CGPoint?
    }

    /// Stable content identity: `(startTime, endTime, body)`.
    ///
    /// `id` is NOT usable as an identity. It originates from AetherEngine's
    /// `EmbeddedSubtitleDecoder.nextCueID`, a per-decoder-instance monotonic
    /// counter starting at 0. Every seek makes the drainer reset the decoder
    /// (`.resetAndDecode`), so ids restart at 0 and collide with unrelated
    /// older cues still sitting in the engine's `subtitleCues` array — which
    /// hands SwiftUI duplicate `ForEach` identities.
    ///
    /// Content identity also collapses the engine's re-decode duplicates
    /// (identical start + end + body) while keeping genuine simultaneous
    /// speakers (identical start, DIFFERENT text) distinct.
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
            }
        }
    }
}
