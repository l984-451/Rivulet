// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItem+ViewHelpers.swift
//  Rivulet
//
//  Convenience computed properties used by views that display episode/season
//  cards. These are pure derivations from the fields already on MediaItem;
//  no network calls, no backend knowledge.
//

import Foundation

extension MediaItem {
    // MARK: - Watch State Helpers

    /// True when the item has been started but not finished.
    var isInProgress: Bool {
        WatchProgressPolicy.hasResumePoint(offsetSeconds: userState.viewOffset,
                                          runtimeSeconds: runtime)
    }

    /// True when the item has been fully watched (isPlayed flag from provider).
    var isWatched: Bool { userState.isPlayed }

    /// Fractional watch progress [0, 1], or nil if not started.
    var watchProgress: Double? {
        WatchProgressPolicy.progress(offsetSeconds: userState.viewOffset,
                                     runtimeSeconds: runtime)
    }

    // MARK: - Formatting

    /// Human-readable duration derived from `runtime` (seconds).
    var durationFormatted: String? {
        guard let runtime else { return nil }
        let totalMinutes = Int(runtime / 60)
        guard totalMinutes > 0 else { return nil }
        if totalMinutes >= 60 {
            let h = totalMinutes / 60
            let m = totalMinutes % 60
            return m > 0 ? String(localized: "\(h)h \(m)m") : String(localized: "\(h)h")
        }
        return String(localized: "\(totalMinutes)m")
    }

    /// "S01E03"-style label for episodes; nil for non-episodes.
    var episodeString: String? {
        guard kind == .episode,
              let s = seasonNumber,
              let e = episodeNumber else { return nil }
        return String(localized: "S\(String(format: "%02d", s))E\(String(format: "%02d", e))")
    }
}
