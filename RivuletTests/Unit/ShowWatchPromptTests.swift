// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The show page's Watched button asks before changing every episode, and
/// offers only the directions that would change something.
@MainActor
final class ShowWatchPromptTests: XCTestCase {
    private let watched = ShowWatchPrompt.markWatched
    private let unwatched = ShowWatchPrompt.markUnwatched

    func test_labels() {
        XCTAssertEqual(watched.title, "Mark All Watched")
        XCTAssertEqual(unwatched.title, "Mark All Unwatched")
        XCTAssertTrue(watched.markWatched)
        XCTAssertFalse(unwatched.markWatched)
    }

    func test_partlyWatched_offersBoth_withCount() {
        let prompt = ShowWatchPrompt(progress: ChildProgress(played: 10, total: 24))
        XCTAssertEqual(prompt.message, "10 of 24 episodes watched.")
        XCTAssertEqual(prompt.choices, [watched, unwatched])
    }

    func test_fullyWatched_offersOnlyUnwatched() {
        XCTAssertEqual(ShowWatchPrompt(progress: ChildProgress(played: 24, total: 24)).choices, [unwatched])
    }

    func test_unwatched_offersOnlyWatched() {
        XCTAssertEqual(ShowWatchPrompt(progress: ChildProgress(played: 0, total: 24)).choices, [watched])
    }

    func test_noCounts_offersBoth_withoutMessage() {
        let prompt = ShowWatchPrompt(progress: nil)
        XCTAssertNil(prompt.message)
        XCTAssertEqual(prompt.choices, [watched, unwatched])
    }

    func test_playedAboveTotal_isClamped() {
        let prompt = ShowWatchPrompt(progress: ChildProgress(played: 30, total: 24))
        XCTAssertEqual(prompt.message, "24 of 24 episodes watched.")
        XCTAssertEqual(prompt.choices, [unwatched])
    }
}
