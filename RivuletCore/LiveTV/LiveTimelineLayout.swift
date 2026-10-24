// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTimelineLayout.swift
//  Rivulet
//
//  Where the live timeline's pieces sit, as fractions of the bar.
//
//  Without a rewind window the bar measures the programme on air. With one,
//  the bar reaches back to cover it: when the window starts before the
//  current programme, the earlier programmes it reaches into join the bar as
//  their own sections, and the part the viewer can actually seek through is
//  filled.
//

import Foundation

struct LiveTimelineLayout: Equatable {
    /// The wall-clock span the bar measures.
    let start: Date
    let end: Date
    /// Programme boundaries inside the bar, as fractions in (0, 1), ascending.
    let boundaries: [Double]
    /// Where the seekable window begins; nil without a rewind window.
    let seekableStart: Double?
    /// What has aired so far: the live edge.
    let aired: Double
    /// What is on screen.
    let playing: Double
    /// The wall-clock time of the picture on screen.
    let onScreen: Date

    /// The furthest back the bar reaches, however deep the window: past this
    /// the current programme would shrink to a sliver.
    static let maximumLookback: TimeInterval = 4 * 3_600

    /// Nil when there is nothing to measure: no guide data and no window.
    init?(
        now: Date,
        program: UnifiedProgram?,
        earlierPrograms: [UnifiedProgram] = [],
        seekWindowSeconds: TimeInterval?,
        behindLiveSeconds: TimeInterval
    ) {
        let program = program.flatMap { $0.endTime > $0.startTime ? $0 : nil }
        let behind = behindLiveSeconds.isFinite ? max(0, behindLiveSeconds) : 0
        let window = seekWindowSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard program != nil || window != nil else { return nil }

        let onScreen = now.addingTimeInterval(-behind)
        let windowStart = window.map { now.addingTimeInterval(-min($0, Self.maximumLookback)) }

        var start = program?.startTime ?? windowStart ?? now
        let end = program.map { max($0.endTime, now) } ?? now
        var boundaries: [Date] = []
        if let windowStart, windowStart < start {
            if program != nil {
                // Earlier programmes, newest first, until one covers the window's start.
                let earlier = earlierPrograms
                    .filter { $0.endTime <= start && $0.endTime > windowStart && $0.endTime > $0.startTime }
                    .sorted { $0.startTime > $1.startTime }
                var cursor = start
                // Contiguous only: a gap in the guide ends the walk.
                for previous in earlier where previous.endTime >= cursor.addingTimeInterval(-1) {
                    boundaries.append(cursor)
                    cursor = previous.startTime
                    if cursor <= windowStart { break }
                }
                // Past the guide's reach the bar simply runs on to the window's start.
                if cursor > windowStart {
                    boundaries.append(cursor)
                    cursor = windowStart
                }
                start = max(cursor, now.addingTimeInterval(-Self.maximumLookback))
            } else {
                start = windowStart
            }
        }

        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }
        func fraction(_ date: Date) -> Double {
            min(max(date.timeIntervalSince(start) / span, 0), 1)
        }
        self.start = start
        self.end = end
        self.boundaries = boundaries.map(fraction).filter { $0 > 0 && $0 < 1 }.sorted()
        self.seekableStart = windowStart.map(fraction)
        self.aired = fraction(now)
        self.playing = fraction(onScreen)
        self.onScreen = onScreen
    }
}
