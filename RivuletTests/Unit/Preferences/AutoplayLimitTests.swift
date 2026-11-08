// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class AutoplayLimitTests: XCTestCase {
    func test_off_neverStopsAutoplay() {
        XCTAssertTrue(AutoplayLimit.off.allowsAutoplay(afterEpisodesInARow: 1))
        XCTAssertTrue(AutoplayLimit.off.allowsAutoplay(afterEpisodesInARow: 50))
    }

    /// One more: the episode you picked, one by autoplay, then Up Next waits.
    func test_one_playsOneMoreEpisode() {
        XCTAssertTrue(AutoplayLimit.one.allowsAutoplay(afterEpisodesInARow: 1))
        XCTAssertFalse(AutoplayLimit.one.allowsAutoplay(afterEpisodesInARow: 2))
    }

    func test_three_playsThreeMoreEpisodes() {
        XCTAssertTrue(AutoplayLimit.three.allowsAutoplay(afterEpisodesInARow: 3))
        XCTAssertFalse(AutoplayLimit.three.allowsAutoplay(afterEpisodesInARow: 4))
    }
}
