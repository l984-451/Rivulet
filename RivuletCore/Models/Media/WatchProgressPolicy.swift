// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchProgressPolicy.swift
//  Rivulet
//
//  The one definition of "has a resume point" and "how far in".
//
//  There used to be three, one per DTO, with three different completion
//  thresholds and the same name: `MediaUserState.isInProgress` (offset only),
//  `MediaItem.isInProgress` (< 98%), `PlexMetadata.isInProgress` (2%..90%).
//  Two of them gated the same resume-or-restart prompt on the same item, so
//  which thresholds applied depended on which DTO the play path happened to
//  hold. All three now delegate here.
//
//  This answers the DECISION question ("would pressing Play resume, and is
//  there enough left to bother asking?"). It deliberately does not answer the
//  DISPLAY question: a partial progress bar is drawn whenever the raw fraction
//  is between 0 and 1, which is a different rule and lives at the render sites.
//

import Foundation

enum WatchProgressPolicy {
    /// Below this, a resume point is noise the user does not want to be asked
    /// about (a few seconds of an accidental start).
    static let startedThreshold: Double = 0.02

    /// At or past this, the item counts as finished. Matches what Plex itself
    /// treats as watched, which is why an item this far in drops out of On Deck
    /// and shows the watched glyph rather than a resume offer.
    static let completionThreshold: Double = 0.9

    /// Fraction watched in [0, 1], or nil when there is no position or no
    /// runtime to measure it against. Capped, because Plex sometimes reports an
    /// offset slightly past the duration.
    static func progress(offsetSeconds: TimeInterval, runtimeSeconds: TimeInterval?) -> Double? {
        guard let runtime = runtimeSeconds, runtime > 0, offsetSeconds > 0 else { return nil }
        return min(1.0, offsetSeconds / runtime)
    }

    /// True when the item has a resume point worth offering.
    ///
    /// A runtime the payload should have carried but didn't answers `false`, not
    /// "any offset counts": the fraction is the whole point of the thresholds,
    /// and guessing would turn a finished item back into a resumable one.
    /// Callers with no runtime field at all use the overload below.
    ///
    /// Played-ness is deliberately NOT considered here: a watched item being
    /// rewatched has a real resume point. The one caller that needs "unfinished"
    /// rather than "resumable" adds `&& !isPlayed`.
    static func hasResumePoint(offsetSeconds: TimeInterval, runtimeSeconds: TimeInterval?) -> Bool {
        guard let fraction = progress(offsetSeconds: offsetSeconds, runtimeSeconds: runtimeSeconds) else {
            return false
        }
        return fraction > startedThreshold && fraction < completionThreshold
    }

    /// Position-only judgement, for `MediaUserState` and anything else that has
    /// a resume position but no runtime to measure it against. Any position
    /// counts, so the thresholds do not apply.
    static func hasResumePoint(offsetSeconds: TimeInterval) -> Bool {
        offsetSeconds > 0
    }
}
