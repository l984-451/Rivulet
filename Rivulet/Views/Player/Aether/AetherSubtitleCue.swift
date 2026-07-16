//
//  AetherSubtitleCue.swift
//  Rivulet
//
//  Rivulet-side subtitle cue bridged from AetherEngine.SubtitleCue.
//
//  AetherEngine's SubtitleCue cannot be named inside the Rivulet module:
//  AetherEngine is both the module and a class, so `AetherEngine.SubtitleCue`
//  parses as a nested-type lookup on the class and fails, while the
//  unqualified `SubtitleCue` resolves to Rivulet's own text-only RPlayer cue
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

    /// Text dialogue, or a positioned bitmap (PGS / DVB / DVD).
    enum Body {
        case text(String)
        /// Text with per-run CONTENT-specified colour (WebVTT `<c>` classes
        /// via the native legible output). Whether a run's colour is honoured
        /// or replaced by the user's caption colour is the RENDERER's call
        /// (`CaptionStyle.allowsContentColor` — the system "Video Override"
        /// setting); the cue always carries what the content said.
        case styledText([StyledRun])
        /// `position` is the bitmap's origin+size in [0, 1] of the source
        /// video frame; the overlay multiplies by the on-screen video rect.
        case image(cgImage: CGImage, position: CGRect)
    }

    /// One run of a styled text cue. `color` is nil when the content did not
    /// specify one (renderer falls back to the system caption colour).
    struct StyledRun: Hashable {
        var text: String
        var color: Color?
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
        ContentKey(startTime: startTime, endTime: endTime, body: body)
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

        init(startTime: Double, endTime: Double, body: Body) {
            self.startTime = startTime
            self.endTime = endTime
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
