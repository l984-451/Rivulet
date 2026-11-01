// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class YearInReviewTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private func at(_ month: Int, _ day: Int, _ hour: Int = 20, minute: Int = 0, second: Int = 0) -> Int {
        let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour,
                                                      minute: minute, second: second))!
        return Int(date.timeIntervalSince1970)
    }

    private func episode(_ show: String, season: Int = 1, _ viewedAt: Int, account: Int = 1) -> PlexHistoryEntry {
        PlexHistoryEntry(ratingKey: "\(show)-\(viewedAt)", title: "Ep", type: "episode", grandparentTitle: show,
                         grandparentKey: "/library/metadata/\(show)", parentIndex: season, viewedAt: viewedAt,
                         accountID: account, thumb: nil, grandparentThumb: "/thumb/\(show)",
                         grandparentArt: "/art/\(show)")
    }

    private func movie(_ title: String, _ viewedAt: Int) -> PlexHistoryEntry {
        PlexHistoryEntry(ratingKey: title, title: title, type: "movie", grandparentTitle: nil, grandparentKey: nil,
                         parentIndex: nil, viewedAt: viewedAt, accountID: 1, thumb: "/poster/\(title)",
                         grandparentThumb: nil, grandparentArt: nil)
    }

    /// 20 hours of TV on one day, enough to pass the threshold.
    private func stats(day: Int = 0, hours: Double = 20) -> [PlexMediaStatistic] {
        [PlexMediaStatistic(accountID: 1, at: at(3, 1, 0) + day * 86400, metadataType: 4,
                            duration: Int(hours * 3600))]
    }

    private func build(_ plays: [PlexHistoryEntry], stats: [PlexMediaStatistic]? = nil,
                       accountID: Int? = 1) -> YearInReview? {
        YearInReview.build(plays: plays, stats: stats ?? self.stats(), year: 2026, accountID: accountID,
                           calendar: calendar)
    }

    func test_bulkLoggedPlays_areDropped() {
        // 290 episodes logged within the same second, as on the measured server.
        let burst = (0..<290).map { _ in episode("Thomas", at(4, 10, 6)) }
        let real = (0..<3).map { episode("Bluey", at(5, 1) + $0 * 600) }
        let review = build(burst + real)
        XCTAssertEqual(review?.topShow?.name, "Bluey")
        XCTAssertEqual(review?.episodeCount, 4)
    }

    func test_bulkGap_doesNotApplyToSongs() {
        let songs = (0..<5).map {
            PlexHistoryEntry(ratingKey: "s\($0)", title: "Song", type: "track", grandparentTitle: "Artist",
                             grandparentKey: "/artist", parentIndex: 1, viewedAt: at(6, 1) + $0 * 30,
                             accountID: 1, thumb: nil, grandparentThumb: nil, grandparentArt: nil)
        }
        XCTAssertEqual(YearInReview.dropBulkPlays(songs).count, 5)
    }

    func test_topShow_countsEpisodesAndSeasons() {
        let plays = [episode("Office", season: 1, at(2, 1)), episode("Office", season: 2, at(2, 2)),
                     episode("Office", season: 2, at(2, 3)), episode("Fallout", at(2, 4))]
        XCTAssertEqual(build(plays)?.topShow?.detail, "3 episodes across 2 seasons")
        XCTAssertEqual(build(plays)?.topShow?.art, "/art/Office")
    }

    func test_topMovies_tiesGoToTheMostRecent() {
        let plays = [movie("Nemo", at(1, 5)), movie("Cars", at(1, 6)), movie("Up", at(1, 7)), movie("Up", at(1, 8))]
        XCTAssertEqual(build(plays)?.topMovies.map(\.name), ["Up", "Cars", "Nemo"])
        XCTAssertEqual(build(plays)?.topMovies.first?.plays, 2)
    }

    func test_otherAccountsAndYears_areIgnored() {
        let plays = [episode("Mine", at(3, 1)), episode("Theirs", at(3, 2), account: 7),
                     episode("Theirs", at(3, 3), account: 7)]
        XCTAssertEqual(build(plays)?.topShow?.name, "Mine")
        let lastYear = PlexHistoryEntry(ratingKey: "x", title: "Old", type: "movie", grandparentTitle: nil,
                                        grandparentKey: nil, parentIndex: nil, viewedAt: at(1, 1, 0) - 3600,
                                        accountID: 1, thumb: nil, grandparentThumb: nil, grandparentArt: nil)
        XCTAssertEqual(build([lastYear, movie("New", at(1, 2))])?.firstPlay?.name, "New")
    }

    func test_tooLittle_showsNothing() {
        XCTAssertNil(build([movie("Up", at(1, 7))], stats: stats(hours: 3)))
        XCTAssertNil(build([], stats: stats(hours: 50)))
    }

    func test_biggestDay_isTheDayWithTheMostHours() {
        let review = build([episode("Bluey", at(3, 2, 9))],
                           stats: stats(day: 0, hours: 6) + stats(day: 1, hours: 12))
        XCTAssertEqual(review?.biggestDay?.hours, 12)
        XCTAssertEqual(review?.biggestDay?.topTitle, "Bluey")
        XCTAssertEqual(review?.biggestDay.map { calendar.component(.day, from: $0.date) }, 2)
    }

    func test_watchTime_namesThePartOfDay() {
        let plays = (0..<4).map { episode("Late", at(2, 1 + $0, 23)) } + [episode("Early", at(3, 1, 7))]
        let time = build(plays)?.watchTime
        XCTAssertEqual(time?.part, .lateNight)
        XCTAssertEqual(time?.peakHour, 23)
    }

    func test_pages_skipWhatIsMissing() {
        let review = build([movie("Up", at(1, 7))])
        // Intro, started, hours, movies, biggest day, when you watch, outro.
        XCTAssertEqual(review?.pages.count, 7)
        XCTAssertFalse(review?.pages.contains { if case .topShow = $0 { true } else { false } } ?? true)
        XCTAssertFalse(review?.pages.contains { if case .topArtist = $0 { true } else { false } } ?? true)
    }

    func test_window_isDecemberAndEarlyJanuary() {
        func year(_ month: Int, _ day: Int) -> Int? {
            YearInReview.year(showingOn: calendar.date(from: DateComponents(year: 2026, month: month, day: day))!,
                              calendar: calendar)
        }
        XCTAssertNil(year(11, 30))
        XCTAssertEqual(year(12, 1), 2026)
        XCTAssertEqual(year(1, 15), 2025)
        XCTAssertNil(year(1, 16))
    }
}
