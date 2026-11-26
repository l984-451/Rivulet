// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveScoresPaneTests.swift
//  RivuletTests
//
//  The Live TV Scores pane's card order, league tabs and status note, and
//  which pane Down reopens with the chrome hidden.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveScoresPaneTests: XCTestCase {
    private typealias Pane = LiveScoresPaneView
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func game(_ id: String, _ state: ScoreGame.State, at offset: TimeInterval = 0) -> ScoreGame {
        let team = ScoreTeam(abbr: id, name: id, short: id, nickname: id, location: id, score: 0, logo: nil)
        return ScoreGame(id: id, state: state, start: start.addingTimeInterval(offset), detail: "",
                         network: nil, away: team, home: team)
    }

    private func board(_ league: League, games: [ScoreGame], stale: Bool = false) -> Scoreboard {
        Scoreboard(league: league, fetchedAt: start, stale: stale, poll: 30, games: games)
    }

    func test_order_currentFirst_thenLiveUpcomingFinal() {
        let games = [game("final", .post), game("soon", .pre, at: 3600), game("early", .pre),
                     game("live", .in), game("mine", .post)]
        XCTAssertEqual(Pane.ordered(games, currentID: "mine").map(\.id), ["mine", "live", "early", "soon", "final"])
    }

    func test_order_withoutCurrent_isByStateThenStart() {
        let games = [game("b", .in, at: 60), game("a", .in), game("f", .post)]
        XCTAssertEqual(Pane.ordered(games, currentID: nil).map(\.id), ["a", "b", "f"])
    }

    func test_order_watchedGamesFollowCurrent_latestFirst() {
        let games = [game("live", .in), game("older", .post), game("prev", .in, at: 60), game("mine", .in)]
        XCTAssertEqual(Pane.ordered(games, currentID: "mine", watchedIDs: ["mine", "prev", "older"]).map(\.id),
                       ["mine", "prev", "older", "live"])
    }

    func test_noteWatched_movesToFront_capsAtSix() {
        (1...7).forEach { Pane.noteWatched("g\($0)") }
        Pane.noteWatched("g3")
        XCTAssertEqual(Pane.watchedGameIDs, ["g3", "g7", "g6", "g5", "g4", "g2"])
    }

    func test_leagues_onlyThoseWithGames_inLeagueOrder() {
        let boards: [League: Scoreboard] = [.nhl: board(.nhl, games: [game("x", .pre)]),
                                            .nba: board(.nba, games: []),
                                            .nfl: board(.nfl, games: [game("y", .in)])]
        XCTAssertEqual(Pane.leagues(in: boards), [.nfl, .nhl])
    }

    func test_status_pausedWins_staleShowsAge_freshShowsNothing() {
        let stale = board(.nfl, games: [], stale: true)
        XCTAssertEqual(Pane.statusText(board: stale, isPaused: true, now: start), "Scores paused")
        XCTAssertEqual(Pane.statusText(board: stale, isPaused: false, now: start.addingTimeInterval(7 * 60)),
                       "Updated 7 min ago")
        XCTAssertEqual(Pane.statusText(board: stale, isPaused: false, now: start), "Updated 1 min ago")
        XCTAssertNil(Pane.statusText(board: board(.nfl, games: []), isPaused: false, now: start))
    }
}
