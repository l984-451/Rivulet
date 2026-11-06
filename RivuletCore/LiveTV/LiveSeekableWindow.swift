// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveSeekableWindow.swift
//  Rivulet
//
//  The rewind window a live stream actually advertises, on the same axis as
//  the player's `currentTime` and `seek(to:)`. Kept free of AVFoundation so
//  the range normalisation and live-edge rules are testable without an item.
//

import Foundation

struct LiveSeekableWindow: Equatable {
    let lowerBound: TimeInterval
    let upperBound: TimeInterval

    init(lowerBound: TimeInterval, upperBound: TimeInterval) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    init?(ranges: [(start: TimeInterval, duration: TimeInterval)]) {
        let valid = ranges.compactMap { range -> (TimeInterval, TimeInterval)? in
            guard range.start.isFinite, range.duration.isFinite, range.duration > 0 else { return nil }
            let end = range.start + range.duration
            guard end.isFinite, end > range.start else { return nil }
            return (range.start, end)
        }
        // A live playlist can briefly expose disjoint ranges while it refreshes.
        // The range with the newest end is the only one that owns "live".
        guard let live = valid.max(by: { $0.1 < $1.1 }) else { return nil }
        lowerBound = live.0
        upperBound = live.1
    }

    var duration: TimeInterval { upperBound - lowerBound }

    /// Shorter than this is the playlist's live holdback, not a window worth
    /// a scrubber.
    static let minimumSeekableDuration: TimeInterval = 60

    var isSeekable: Bool { duration >= Self.minimumSeekableDuration }

    /// Within this of the newest segment is the live edge itself.
    static let liveEdgeTolerance: TimeInterval = 3

    /// Where a seek into the window lands: inside it, and clear of its oldest
    /// segment, which the next playlist refresh may evict before the seek lands.
    func seekTarget(_ requested: TimeInterval) -> TimeInterval {
        let floor = lowerBound + min(6, duration / 10)
        return min(max(requested, floor), upperBound)
    }

    func isAtLiveEdge(_ position: TimeInterval) -> Bool {
        upperBound - position <= Self.liveEdgeTolerance
    }

    /// Whether the viewer counts as behind live, for the LIVE badge.
    ///
    /// An HLS stream plays a few segments behind the newest, and that gap grows
    /// by a segment and snaps back each time the playlist updates. Judged
    /// against the 3s edge alone, a channel nobody touched would flip between
    /// live and behind every few seconds. So being behind counts once the
    /// viewer paused or rewound (their own time shift), or when the stream has
    /// fallen well past any normal live delay on its own.
    static func isBehindLive(_ behind: TimeInterval, timeShifted: Bool) -> Bool {
        timeShifted ? behind > liveEdgeTolerance : behind >= 30
    }
}
