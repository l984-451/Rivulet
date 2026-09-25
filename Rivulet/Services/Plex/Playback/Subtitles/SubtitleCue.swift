// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleCue.swift
//  Rivulet
//
//  Model for a single subtitle entry with timing and text.
//

import Foundation

/// A single subtitle cue with start time, end time, and text content
nonisolated struct SubtitleCue: Identifiable, Equatable, Sendable {
    let id: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    /// Check if this cue should be displayed at the given time
    func isActive(at time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }
}

/// Collection of parsed subtitle cues (from SRT/ASS/VTT) — distinct from the
/// agnostic-layer `SubtitleTrack` in `Models/Media/`.
nonisolated struct ParsedSubtitleTrack: Sendable {
    let cues: [SubtitleCue]

    /// Find all cues that should be displayed at the given time
    /// (multiple cues can overlap)
    func activeCues(at time: TimeInterval) -> [SubtitleCue] {
        // Binary search for efficiency with large subtitle files
        // Find first cue that might be active, then collect all active ones
        guard !cues.isEmpty else { return [] }

        var result: [SubtitleCue] = []

        // Binary search to find starting point
        var low = 0
        var high = cues.count - 1

        while low < high {
            let mid = (low + high) / 2
            if cues[mid].endTime <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // Collect all active cues from this point
        for i in low..<cues.count {
            let cue = cues[i]
            if cue.startTime > time {
                break  // Past our time window
            }
            if cue.isActive(at: time) {
                result.append(cue)
            }
        }

        return result
    }

    /// Empty track
    static let empty = ParsedSubtitleTrack(cues: [])
}
