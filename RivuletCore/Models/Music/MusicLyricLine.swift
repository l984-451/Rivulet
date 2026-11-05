// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// One time-synced lyric line. `start` is seconds from the top of the track.
struct MusicLyricLine: Hashable, Sendable {
    /// Apple Music brings a line in this long before it is sung.
    static let lead: TimeInterval = 0.75

    let start: TimeInterval
    let text: String
}

extension Array where Element == MusicLyricLine {
    /// The line to show as sung at `time`: the last one due within `lead`. Nil before the first.
    func activeIndex(at time: TimeInterval, lead: TimeInterval = 0) -> Int? {
        lastIndex { $0.start <= time + lead }
    }
}
