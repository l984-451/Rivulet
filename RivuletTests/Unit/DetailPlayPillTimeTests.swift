// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Issue #279: the detail hero's Play pill read the item's TOTAL runtime
//  whatever its watch state, so a movie 8 minutes in said "1h 38m" while its
//  Continue Watching tile said "1h 30m" on the row it was opened from. The two
//  are the same question about the same item and must answer the same way.
//

import XCTest
@testable import Rivulet

@MainActor
final class DetailPlayPillTimeTests: XCTestCase {
    /// 1h 38m, the runtime from the issue's screenshots.
    private let runtime: TimeInterval = 98 * 60

    func testUnstartedItemShowsTotalRuntime() {
        XCTAssertEqual(
            MediaDetailChromeView.playPillTime(runtime: runtime, viewOffset: 0, partiallyWatched: false),
            "1h 38m")
    }

    func testPartWatchedItemShowsRemainingTime() {
        // 8 minutes in — the exact case reported.
        XCTAssertEqual(
            MediaDetailChromeView.playPillTime(runtime: runtime, viewOffset: 8 * 60, partiallyWatched: true),
            "1h 30m")
    }

    /// A finished item is not "partially watched", so it reads as the full
    /// runtime rather than as "0m" left.
    func testFinishedItemShowsTotalRuntime() {
        XCTAssertEqual(
            MediaDetailChromeView.playPillTime(runtime: runtime, viewOffset: runtime, partiallyWatched: false),
            "1h 38m")
    }

    /// Under a minute left formats as "0m", which reads as broken. Fall back to
    /// the total.
    func testSubMinuteRemainderFallsBackToTotalRuntime() {
        XCTAssertEqual(
            MediaDetailChromeView.playPillTime(runtime: runtime, viewOffset: runtime - 20, partiallyWatched: true),
            "1h 38m")
    }

    /// A show carries no runtime of its own; the pill says "Play" until the
    /// Next Up episode resolves and replaces it.
    func testNoRuntimeShowsPlay() {
        XCTAssertEqual(
            MediaDetailChromeView.playPillTime(runtime: nil, viewOffset: 0, partiallyWatched: false),
            "Play")
        XCTAssertEqual(
            MediaDetailChromeView.playPillTime(runtime: 0, viewOffset: 0, partiallyWatched: false),
            "Play")
    }
}
