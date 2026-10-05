// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveSuggestionsTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class LiveSuggestionsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func candidate(_ id: String, title: String, category: String?, genre: LiveGenre?,
                           placeholder: Bool = false)
        -> (channel: UnifiedChannel, program: UnifiedProgram?, genre: LiveGenre?) {
        let channel = UnifiedChannel(id: id, sourceType: .dispatcharr, sourceId: "s", name: id)
        let program = UnifiedProgram(id: placeholder ? "\(id):placeholder:1" : UUID().uuidString,
                                     channelId: id, title: title,
                                     startTime: now.addingTimeInterval(-600),
                                     endTime: now.addingTimeInterval(600), category: category)
        return (channel, program, genre)
    }

    private func viewing(_ channelId: String, title: String?, labels: [String], genre: LiveGenre?,
                         daysAgo: Double = 0) -> LiveViewing {
        LiveViewing(channelId: channelId, at: now.addingTimeInterval(-daysAgo * 86_400),
                    title: title, labels: labels, genre: genre?.rawValue)
    }

    func test_sameShowOutranksSameKindOutranksSameGenre() {
        let history = [viewing("old", title: "Monday Night Football", labels: ["football"], genre: .sports)]
        let ranked = LiveSuggestions.rank([
            candidate("genre", title: "Golf Live", category: "Sports", genre: .sports),
            candidate("show", title: "Monday Night Football", category: "Sports", genre: .sports),
            candidate("kind", title: "College Gameday", category: "Football", genre: .sports),
            candidate("none", title: "Evening News", category: "News", genre: .news),
        ], history: history, now: now)

        XCTAssertEqual(ranked.map(\.id), ["show", "kind", "genre"])
    }

    /// Most guide entries have no category. The sport in the title still
    /// makes NFL and college games the same kind, above other sports.
    func test_sportInTheTitleLinksGamesWithoutCategories() {
        let watched = candidate("espnu", title: "College Football", category: nil, genre: .sports).program
        let history = [viewing("espnu", title: "College Football",
                               labels: LiveGenre.specificLabels(of: watched).sorted(), genre: .sports)]
        let ranked = LiveSuggestions.rank([
            candidate("golf", title: "Golf Live", category: nil, genre: .sports),
            candidate("nfl", title: "NFL Football", category: nil, genre: .sports),
            candidate("sec", title: "Live: College Football", category: nil, genre: .sports),
        ], history: history, now: now)

        XCTAssertEqual(ranked.map(\.id), ["sec", "nfl", "golf"])
    }

    func test_oldViewingsFadeOut() {
        let history = [viewing("old", title: nil, labels: [], genre: .news, daysAgo: 60)]
        let ranked = LiveSuggestions.rank([candidate("news", title: "Headlines", category: "News", genre: .news)],
                                          history: history, now: now)
        XCTAssertTrue(ranked.isEmpty)
    }

    /// Saturday noon learns from Saturday noons: last Saturday's football
    /// outranks golf watched at noon on a (fresher) Wednesday, and Saturday
    /// morning cartoons have faded by noon.
    func test_sameWeekdayAndHourCountMost() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let saturdayNoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
        func at(daysAgo: Double, hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0,
                          of: saturdayNoon.addingTimeInterval(-daysAgo * 86_400))!
        }
        let history = [
            LiveViewing(channelId: "x", at: at(daysAgo: 7, hour: 12), title: nil, labels: ["football"], genre: "Sports"),
            LiveViewing(channelId: "y", at: at(daysAgo: 7, hour: 9), title: nil, labels: [], genre: "Kids"),
            LiveViewing(channelId: "z", at: at(daysAgo: 3, hour: 12), title: nil, labels: ["golf"], genre: "Sports"),
        ]
        func score(_ id: String, _ title: String, _ category: String, _ genre: LiveGenre) -> Double {
            LiveSuggestions.scores([(candidate(id, title: title, category: category, genre: genre), saturdayNoon)],
                                   history: history, now: saturdayNoon, calendar: calendar)[0]
        }
        let football = score("cfb", "College Football", "Football", .sports)
        let golf = score("golf", "PGA Tour Golf", "Golf", .sports)
        let cartoons = score("kids", "SpongeBob", "Children", .kids)

        XCTAssertGreaterThan(football, golf)
        XCTAssertGreaterThanOrEqual(football, LiveSuggestions.threshold)
        XCTAssertLessThan(cartoons, LiveSuggestions.threshold)
    }

    /// Starting Soon judges each programme at its own start, not at now.
    func test_scoresAreJudgedAtEachCandidatesOwnTime() {
        let history = [viewing("old", title: nil, labels: [], genre: .sports)]
        let game = candidate("cfb", title: "College Football", category: "Football", genre: .sports)
        let scores = LiveSuggestions.scores([(game, now), (game, now.addingTimeInterval(8 * 3600))],
                                            history: history, now: now)
        XCTAssertGreaterThanOrEqual(scores[0], LiveSuggestions.threshold)
        XCTAssertLessThan(scores[1], scores[0])
    }

    /// A guide gap's stand-in is named after the channel, so its title must
    /// not count as the same show.
    func test_placeholderTitleIsNotAShowMatch() {
        let history = [viewing("elsewhere", title: "ESPN", labels: [], genre: nil)]
        let ranked = LiveSuggestions.rank([candidate("espn", title: "ESPN", category: nil, genre: nil, placeholder: true)],
                                          history: history, now: now)
        XCTAssertTrue(ranked.isEmpty)
    }
}
