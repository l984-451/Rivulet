// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ReplayWindowLogic.swift
//  Rivulet
//
//  Pure logic for the skip-back subtitle window: after a skip back,
//  subtitles are temporarily on, then auto-revert once playback passes
//  the point where it was invoked (or last extended to, if the user
//  invoked it again while still inside the window).
//

import Foundation

struct ReplayWindowLogic {
    /// Playback time the window reverts at (the point replay was invoked,
    /// or extended to on a repeat invocation).
    let invokedAt: TimeInterval

    /// Subtitle track id active before replay temporarily changed it, or
    /// nil if subtitles were already off. Restored (or, if nil, subtitles
    /// are turned back off) when the window reverts.
    let priorSubtitleTrackId: Int?

    /// True once a time-observer tick has been observed *before*
    /// `invokedAt` — i.e. the backward seek that opens the window has
    /// actually landed. `openCaptionWindow(until:)` sets the window
    /// synchronously but performs its seek asynchronously in a Task; a
    /// stale time-observer tick can fire in that gap at/after `invokedAt`
    /// (playback hasn't moved yet). Without arming, that stale tick would
    /// satisfy `shouldRevert` immediately and revert subtitles before the
    /// seek ever lands. Only a tick that actually observes playback below
    /// `invokedAt` proves the seek landed, and only then should a
    /// subsequent pass back over `invokedAt` count as "passed the point."
    let armed: Bool

    init(invokedAt: TimeInterval, priorSubtitleTrackId: Int?, armed: Bool = false) {
        self.invokedAt = invokedAt
        self.priorSubtitleTrackId = priorSubtitleTrackId
        self.armed = armed
    }

    /// True once playback has been armed (observed before `invokedAt`) and
    /// has now passed `invokedAt`.
    func shouldRevert(currentTime: TimeInterval) -> Bool {
        armed && currentTime > invokedAt
    }

    /// Feed a time-observer tick through the window. Arms the window once
    /// a tick lands before `invokedAt` (proof the backward seek landed);
    /// a no-op once already armed.
    func observing(currentTime: TimeInterval) -> ReplayWindowLogic {
        guard !armed, currentTime < invokedAt else { return self }
        return ReplayWindowLogic(invokedAt: invokedAt, priorSubtitleTrackId: priorSubtitleTrackId, armed: true)
    }

    /// A repeat invocation while still inside the window extends the
    /// revert point without disturbing `priorSubtitleTrackId`. Already
    /// armed from the earlier pass below `invokedAt` (that's how the user
    /// got back here to re-invoke replay), so the extended window stays
    /// armed rather than re-requiring a fresh sub-invokedAt tick.
    func extended(to newInvokedAt: TimeInterval) -> ReplayWindowLogic {
        ReplayWindowLogic(invokedAt: max(invokedAt, newInvokedAt), priorSubtitleTrackId: priorSubtitleTrackId, armed: armed)
    }
}
