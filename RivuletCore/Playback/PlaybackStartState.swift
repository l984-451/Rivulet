// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

struct PlaybackStartState {
    private(set) var itemHasPlayed = false
    private(set) var streamHasPlayed = false
    private var wasSeeking = false
    private var reportSeekCompletion = false

    mutating func beginLoad(startsItem: Bool) {
        streamHasPlayed = false
        wasSeeking = false
        reportSeekCompletion = false
        if startsItem { itemHasPlayed = false }
    }

    mutating func seekCompleted(isSeeking: Bool, isStarting: Bool) -> Bool {
        let completed = reportSeekCompletion && !isSeeking && !isStarting
        if !isSeeking { reportSeekCompletion = false }
        else if !wasSeeking { reportSeekCompletion = streamHasPlayed && !isStarting }
        wasSeeking = isSeeking
        return completed
    }

    func heartbeatState(isPaused: Bool, isLoading: Bool, isStarting: Bool, isSeeking: Bool, isStalled: Bool) -> String? {
        guard itemHasPlayed else { return nil }
        if isLoading || isStarting || isSeeking || isStalled { return "buffering" }
        return isPaused ? "paused" : nil
    }

    mutating func didPlay() {
        itemHasPlayed = true
        streamHasPlayed = true
    }
}
