// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The show page's Watched button asks before changing every episode, and
/// offers only the directions that would change something.
@MainActor
final class ShowWatchPromptTests: XCTestCase {
    private typealias Choice = ShowWatchPrompt.Choice

    func test_partlyWatched_offersBothDirections_withCounts() {
        let prompt = ShowWatchPrompt(progress: ChildProgress(played: 10, total: 24))
        XCTAssertEqual(prompt.message, "10 of 24 episodes watched.")
        XCTAssertEqual(prompt.choices, [
            Choice(title: "Mark 14 Episodes as Watched", markWatched: true),
            Choice(title: "Mark 10 Episodes as Unwatched", markWatched: false),
        ])
    }

    func test_fullyWatched_offersOnlyUnwatched() {
        let prompt = ShowWatchPrompt(progress: ChildProgress(played: 24, total: 24))
        XCTAssertEqual(prompt.choices, [Choice(title: "Mark 24 Episodes as Unwatched", markWatched: false)])
    }

    func test_unwatched_offersOnlyWatched() {
        let prompt = ShowWatchPrompt(progress: ChildProgress(played: 0, total: 24))
        XCTAssertEqual(prompt.choices, [Choice(title: "Mark 24 Episodes as Watched", markWatched: true)])
    }

    func test_singleEpisode_isSingular() {
        let prompt = ShowWatchPrompt(progress: ChildProgress(played: 1, total: 2))
        XCTAssertEqual(prompt.message, "1 of 2 episodes watched.")
        XCTAssertEqual(prompt.choices.map(\.title), ["Mark 1 Episode as Watched", "Mark 1 Episode as Unwatched"])
    }

    func test_noCounts_offersBothWithoutNumbers() {
        let prompt = ShowWatchPrompt(progress: nil)
        XCTAssertNil(prompt.message)
        XCTAssertEqual(prompt.choices, [
            Choice(title: "Mark All Episodes as Watched", markWatched: true),
            Choice(title: "Mark All Episodes as Unwatched", markWatched: false),
        ])
    }

    func test_playedAboveTotal_isClamped() {
        let prompt = ShowWatchPrompt(progress: ChildProgress(played: 30, total: 24))
        XCTAssertEqual(prompt.message, "24 of 24 episodes watched.")
        XCTAssertEqual(prompt.choices.map(\.markWatched), [false])
    }
}
