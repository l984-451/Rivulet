// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PauseScreenContentTests.swift
//  RivuletTests
//
//  The pause screen's text: pure functions, no view.
//

import XCTest
@testable import Rivulet

@MainActor
final class PauseScreenContentTests: XCTestCase {

    // MARK: - Episode line

    func test_episodeLine_full() {
        XCTAssertEqual(PauseScreenText.episodeLine(season: 2, episode: 5, name: "The Long Tide"),
                       "Season 2, Episode 5 · The Long Tide")
    }

    func test_episodeLine_dropsMissingParts() {
        XCTAssertEqual(PauseScreenText.episodeLine(season: 2, episode: 5, name: nil), "Season 2, Episode 5")
        XCTAssertEqual(PauseScreenText.episodeLine(season: nil, episode: 5, name: "Pilot"), "Episode 5 · Pilot")
        XCTAssertEqual(PauseScreenText.episodeLine(season: nil, episode: 5, name: nil), "Episode 5")
        XCTAssertEqual(PauseScreenText.episodeLine(season: 2, episode: nil, name: "Pilot"), "Season 2 · Pilot")
        XCTAssertEqual(PauseScreenText.episodeLine(season: 2, episode: nil, name: nil), "Season 2")
        XCTAssertEqual(PauseScreenText.episodeLine(season: nil, episode: nil, name: "Pilot"), "Pilot")
        XCTAssertNil(PauseScreenText.episodeLine(season: nil, episode: nil, name: nil))
    }

    func test_episodeLine_blankNameIsNoName() {
        XCTAssertEqual(PauseScreenText.episodeLine(season: 1, episode: 3, name: "  "), "Season 1, Episode 3")
    }

    func test_episodeLine_specialsNameNoSeason() {
        XCTAssertEqual(PauseScreenText.episodeLine(season: 0, episode: 3, name: "Behind the Scenes"),
                       "Episode 3 · Behind the Scenes")
    }

    func test_episodeLine_nameThatRepeatsTheNumberIsDropped() {
        XCTAssertEqual(PauseScreenText.episodeLine(season: 1, episode: 4, name: "Episode 4"), "Season 1, Episode 4")
        // A different number is a real title.
        XCTAssertEqual(PauseScreenText.episodeLine(season: 1, episode: 4, name: "Episode 9"),
                       "Season 1, Episode 4 · Episode 9")
    }

    // MARK: - Movie line

    func test_movieLine() {
        XCTAssertEqual(PauseScreenText.movieLine(year: 2019, rating: "R"), "2019 · R")
        XCTAssertEqual(PauseScreenText.movieLine(year: 2019, rating: nil), "2019")
        XCTAssertEqual(PauseScreenText.movieLine(year: nil, rating: "PG-13"), "PG-13")
        XCTAssertEqual(PauseScreenText.movieLine(year: 2019, rating: ""), "2019")
        XCTAssertNil(PauseScreenText.movieLine(year: nil, rating: nil))
    }

    // MARK: - From metadata (every server fills the same fields)

    func test_detailLine_episodeMetadata() {
        let meta = PlexMetadata(type: "episode", title: "The Long Tide", contentRating: "TV-MA",
                                summary: "Storm.", year: 2024, parentIndex: 2,
                                grandparentTitle: "Saltglass", index: 5)
        XCTAssertEqual(PauseScreenText.title(for: meta), "Saltglass")
        XCTAssertEqual(PauseScreenText.detailLine(for: meta), "Season 2, Episode 5 · The Long Tide")
        XCTAssertEqual(PauseScreenText.synopsis(for: meta), "Storm.")
    }

    func test_detailLine_movieMetadata_stripsCountryPrefix() {
        let meta = PlexMetadata(type: "movie", title: "Heat", contentRating: "gb/15", year: 1995)
        XCTAssertEqual(PauseScreenText.title(for: meta), "Heat")
        XCTAssertEqual(PauseScreenText.detailLine(for: meta), "1995 · 15")
    }

    func test_title_episodeWithoutShowFallsBackToItsOwnTitle() {
        let meta = PlexMetadata(type: "episode", title: "Pilot", parentIndex: 1, index: 1)
        XCTAssertEqual(PauseScreenText.title(for: meta), "Pilot")
    }

    func test_synopsis_emptyIsNone() {
        XCTAssertNil(PauseScreenText.synopsis(for: PlexMetadata(type: "movie", summary: " \n")))
        XCTAssertNil(PauseScreenText.synopsis(for: PlexMetadata(type: "movie")))
    }

    // MARK: - Time line

    func test_timeLine_minutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ended: Date?
        let line = PauseScreenText.timeLine(position: 31 * 60 + 42, duration: 70 * 60, now: now) {
            ended = $0
            return "10:41 PM"
        }
        XCTAssertEqual(line, "38 min left · Ends at 10:41 PM")
        XCTAssertEqual(ended, now.addingTimeInterval(38 * 60 + 18))
    }

    func test_timeLine_hoursAndMinutes() {
        let line = PauseScreenText.timeLine(position: 0, duration: 92 * 60, now: Date()) { _ in "9:00 PM" }
        XCTAssertEqual(line, "1 hr 32 min left · Ends at 9:00 PM")
    }

    func test_timeLine_wholeHour() {
        let line = PauseScreenText.timeLine(position: 30 * 60, duration: 150 * 60, now: Date()) { _ in "9:00 PM" }
        XCTAssertEqual(line, "2 hr left · Ends at 9:00 PM")
    }

    func test_timeLine_neverUnderOneMinute() {
        let line = PauseScreenText.timeLine(position: 599, duration: 600, now: Date()) { _ in "9:00 PM" }
        XCTAssertEqual(line, "1 min left · Ends at 9:00 PM")
    }

    func test_timeLine_noDurationIsNoLine() {
        XCTAssertNil(PauseScreenText.timeLine(position: 10, duration: 0, now: Date()))
    }

    func test_timeLine_positionPastTheEndEndsNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ended: Date?
        _ = PauseScreenText.timeLine(position: 700, duration: 600, now: now) { ended = $0; return "" }
        XCTAssertEqual(ended, now)
    }

    func test_progress_isClamped() {
        XCTAssertEqual(PauseScreenText.progress(position: 30, duration: 120), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PauseScreenText.progress(position: 200, duration: 120), 1)
        XCTAssertEqual(PauseScreenText.progress(position: -5, duration: 120), 0)
        XCTAssertEqual(PauseScreenText.progress(position: 30, duration: 0), 0)
    }

    // MARK: - Style

    func test_fittedSynopsis_keepsWholeSentences() {
        let text = "One two. Three four five. Six seven eight nine."
        let fits = { (s: String) in s.count <= 26 }
        XCTAssertEqual(PauseScreenText.fittedSynopsis(text, fits: fits), "One two. Three four five.")
    }

    func test_fittedSynopsis_allOfItWhenItFits() {
        let text = "One two. Three four."
        XCTAssertEqual(PauseScreenText.fittedSynopsis(text, fits: { _ in true }), text)
    }

    func test_fittedSynopsis_firstSentenceTooLongKeepsItAll() {
        let text = "A very long first sentence. Short."
        XCTAssertEqual(PauseScreenText.fittedSynopsis(text, fits: { $0.count <= 5 }), text)
    }
}
