// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import OpenWatchParty
import XCTest
@testable import Rivulet

final class WatchTogetherTests: XCTestCase {

    // MARK: - Drift trim

    func testTrimStartsPastDeadbandAndStopsInsideIt() {
        XCTAssertEqual(WatchTogetherPlayerAdapter.trimRate(drift: -80, current: 1), 1)
        XCTAssertEqual(WatchTogetherPlayerAdapter.trimRate(drift: -120, current: 1), 1.02)
        XCTAssertEqual(WatchTogetherPlayerAdapter.trimRate(drift: 120, current: 1), 0.98)
        XCTAssertEqual(WatchTogetherPlayerAdapter.trimRate(drift: -80, current: 1.02), 1.02)
        XCTAssertEqual(WatchTogetherPlayerAdapter.trimRate(drift: -30, current: 1.02), 1)
    }

    func testTrimLeavesWhatTheSDKCorrectsToTheSDK() {
        XCTAssertEqual(WatchTogetherPlayerAdapter.trimRate(drift: -400, current: 1.02), 1)
        XCTAssertEqual(WatchTogetherPlayerAdapter.trimRate(drift: nil, current: 1.02), 1)
    }

    func testSeekAccuracyIsTheWorstRecentLandingCapped() {
        XCTAssertEqual(WatchTogetherPlayerAdapter.accuracy(from: []), 0)
        XCTAssertEqual(WatchTogetherPlayerAdapter.accuracy(from: [120, 2300, 40]), 2300)
        XCTAssertEqual(WatchTogetherPlayerAdapter.accuracy(from: [60_000]), 8000)
    }

    // MARK: - Seek landings

    @MainActor
    func testALandingIsSeenEvenWhenItArrivesDuringTheSeekCall() async {
        let outcomes = PassthroughSubject<WatchTogetherSeekOutcome, Never>()
        let landed = await watchTogetherLanding(of: outcomes.eraseToAnyPublisher()) {
            outcomes.send(.began)
            outcomes.send(.landed(42))
        }
        XCTAssertEqual(landed, 42)
    }

    @MainActor
    func testAGivenUpSeekReportsNoLanding() async {
        let outcomes = PassthroughSubject<WatchTogetherSeekOutcome, Never>()
        let landed = await watchTogetherLanding(of: outcomes.eraseToAnyPublisher()) {
            outcomes.send(.began)
            outcomes.send(.gaveUp)
        }
        XCTAssertNil(landed)
    }

    @MainActor
    func testASeekThatNeverBeganDoesNotHoldTheRoom() async {
        let outcomes = PassthroughSubject<WatchTogetherSeekOutcome, Never>()
        let start = Date()
        let landed = await watchTogetherLanding(of: outcomes.eraseToAnyPublisher()) {}
        XCTAssertNil(landed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    // MARK: - Describing an item

    func testPlexGuidsBecomeCatalogueIDs() {
        let ids = WatchTogetherSession.ids(
            fromPlexGuid: "plex://movie/abc",
            guids: ["imdb://tt0322259", "tmdb://584", "tvdb://20800", "junk", "other://1"])
        XCTAssertEqual(ids, ["plex": "plex://movie/abc", "imdb": "tt0322259", "tmdb": "584", "tvdb": "20800"])
        // An unmatched item's agent guid names nothing another server knows.
        XCTAssertEqual(WatchTogetherSession.ids(fromPlexGuid: "tv.plex.agents.none://242639", guids: []), [:])
    }

    func testEpisodeDescriptorPassesTheRelaysRules() throws {
        var meta = try XCTUnwrap(try JSONDecoder().decode(PlexMetadata.self, from: Data("""
        {"ratingKey":"214321","type":"episode","title":"Pilot","guid":"plex://episode/1","index":1,"parentIndex":2,
         "grandparentTitle":"9-1-1: Nashville","grandparentGuid":"plex://show/2","Guid":[{"id":"imdb://tt34368743"}]}
        """.utf8)))
        meta.year = 2025
        let media = WatchTogetherSession.media(plex: meta, show: nil, durationMs: 2_529_150, server: "plex:abc")
        XCTAssertNil(checkMedia(media))
        XCTAssertEqual(media.kind, .episode)
        XCTAssertEqual(media.series?.title, "9-1-1: Nashville")
        XCTAssertEqual(media.series?.ids, ["plex": "plex://show/2"])
        XCTAssertEqual(media.season, 2)
        XCTAssertEqual(media.episode, 1)
        let shortcut = try XCTUnwrap(WatchTogetherSession.shortcut(in: media))
        XCTAssertEqual(shortcut.server, "plex:abc")
        XCTAssertEqual(shortcut.item, "214321")
    }

    func testUntitledEpisodeGetsAStandInTitle() throws {
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data("""
        {"ratingKey":"1","type":"episode","title":"  ","index":5,"parentIndex":1,"grandparentTitle":"Show"}
        """.utf8))
        XCTAssertNil(checkMedia(WatchTogetherSession.media(plex: meta, show: nil, durationMs: 1000, server: nil)))
    }

    // MARK: - Title matching

    func testTitlesMatchOnWordsAndCloseYears() {
        XCTAssertTrue(TitleCopies.sameTitle("Spider-Man: Homecoming", year: 2017, ids: [:],
                                            as: "Spider Man Homecoming", year: 2018, ids: [:]))
        XCTAssertFalse(TitleCopies.sameTitle("Dune", year: 1984, ids: [:], as: "Dune", year: 2021, ids: [:]))
        XCTAssertTrue(TitleCopies.sameTitle("Dune", year: nil, ids: [:], as: "Dune", year: 2021, ids: [:]))
    }

    func testAnIDConflictOverridesAMatchingTitle() {
        XCTAssertFalse(TitleCopies.sameTitle("Dune", year: 2021, ids: ["tmdb": "438631"],
                                             as: "Dune", year: 2021, ids: ["tmdb": "841"]))
        XCTAssertTrue(TitleCopies.sameTitle("Dune", year: 2021, ids: ["tmdb": "438631"],
                                            as: "Dune", year: 2021, ids: ["imdb": "tt1160419"]))
    }

    // MARK: - The relay's rules on names

    func testNamesAreTrimmedToWhatTheRelayTakes() {
        XCTAssertEqual(WatchTogetherSession.cleanName("  Kevin \n"), "Kevin")
        XCTAssertEqual(WatchTogetherSession.cleanName("   "), "Rivulet")
        XCTAssertEqual(WatchTogetherSession.cleanName(String(repeating: "a", count: 40)).count, 32)
    }

    func testFailuresMapToWhatTheUserIsTold() {
        XCTAssertEqual(WatchTogetherSession.failure(for: PartyError(.roomNotFound)), .roomNotFound)
        XCTAssertEqual(WatchTogetherSession.failure(for: PartyError(.roomLocked)), .roomFull)
        XCTAssertEqual(WatchTogetherSession.failure(for: PartyError(.clientBlocked)), .unreachable)
        XCTAssertEqual(WatchTogetherSession.failure(for: URLError(.badURL)), .other)
    }
}
