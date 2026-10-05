// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class LiveGenreTests: XCTestCase {

    private func channel(_ name: String) -> UnifiedChannel {
        UnifiedChannel(id: name, sourceType: .plex, sourceId: "s", name: name)
    }

    private func program(_ category: String?) -> UnifiedProgram {
        UnifiedProgram(id: UUID().uuidString, channelId: "c", title: "t",
                       startTime: Date(), endTime: Date().addingTimeInterval(3600), category: category)
    }

    func test_from_readsRealGuideLabels() {
        XCTAssertEqual(LiveGenre.from("178, News"), .news)
        XCTAssertEqual(LiveGenre.from("News & Documentary"), .news)
        XCTAssertEqual(LiveGenre.from("Sports talk"), .sports)
        XCTAssertEqual(LiveGenre.from("Sports event, Football"), .sports)
        XCTAssertEqual(LiveGenre.from("Bus./financial"), .news)
        // A format, not a genre: news channels label bulletins "Series".
        XCTAssertNil(LiveGenre.from("Series"))
        XCTAssertEqual(LiveGenre.from("Series, Comedy"), .entertainment)
        XCTAssertNil(LiveGenre.from("178"))
        XCTAssertNil(LiveGenre.from(nil))
    }

    func test_from_channelNames() {
        XCTAssertEqual(LiveGenre.from("AccuWeather NOW"), .news)
        XCTAssertEqual(LiveGenre.from("News12 Bronx"), .news)
        XCTAssertEqual(LiveGenre.from("Africanews English"), .news)
        XCTAssertEqual(LiveGenre.from("ESPN2"), .sports)
        XCTAssertEqual(LiveGenre.from("Fox Sports 1"), .sports)
        // Keywords match at the start of a word, never inside one.
        XCTAssertNil(LiveGenre.from("Inflation Weekly"))
        XCTAssertNil(LiveGenre.from("Transport Today"))
        XCTAssertNil(LiveGenre.from("Signature Collection"))
        XCTAssertNil(LiveGenre.from("Embracing Change"))
    }

    func test_of_prefersWhatIsOnThenTheUsualThenTheName() {
        let news = channel("CBS News 24/7")
        // A news channel airing a game is in Sports while the game is on.
        XCTAssertEqual(LiveGenre.of(news, airing: program("Football"), guide: []), .sports)
        // Nothing labelled now: what the channel mostly airs.
        let guide = [program("News"), program("News"), program("Sports")]
        XCTAssertEqual(LiveGenre.of(channel("WXYZ"), airing: program(nil), guide: guide), .news)
        // No labels anywhere: the name.
        XCTAssertEqual(LiveGenre.of(news, airing: nil, guide: [program("178")]), .news)
        XCTAssertNil(LiveGenre.of(channel("Payvand TV"), airing: nil, guide: []))
    }

    /// ABC 33/40 airing church on a morning with a WNBA game later: no genre,
    /// never the station's usual sports.
    func test_of_worshipAndInfomercialsAreNoGenre() {
        let guide = [program("Sports, Basketball"), program("Basketball"), program("News")]
        let station = channel("ABC 33/40 WBMA")
        XCTAssertNil(LiveGenre.of(station, airing: program("Religious"), guide: guide))
        XCTAssertNil(LiveGenre.of(station, airing: program("Consumer, Shopping, Variety"), guide: guide))
        // A label that names no genre but is real programming keeps the usual.
        XCTAssertEqual(LiveGenre.of(station, airing: program("Series, Crime"), guide: guide), .sports)
    }

    func test_specificLabels_dropGenreAndFormatWords() {
        XCTAssertEqual(LiveGenre.specificLabels(of: program("Sports event, Football")), ["football"])
        XCTAssertEqual(LiveGenre.specificLabels(of: program("178, News, Politics")), ["politics"])
        XCTAssertEqual(LiveGenre.specificLabels(of: program(nil)), [])
    }
}
