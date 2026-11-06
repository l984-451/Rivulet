// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SeasonOrderTests.swift
//  RivuletTests
//
//  Issue #534: Specials list after the last season, as Plex and Infuse show them.
//

import XCTest
@testable import Rivulet

final class SeasonOrderTests: XCTestCase {

    private struct Season: Equatable {
        let id: String
        let number: Int?
    }

    private func order(_ seasons: [Season]) -> [String] {
        SeasonOrder.specialsLast(seasons, seasonNumber: \.number).map(\.id)
    }

    func testSpecialsMoveAfterTheLastSeason() {
        let seasons = [Season(id: "sp", number: 0), Season(id: "s1", number: 1), Season(id: "s2", number: 2)]
        XCTAssertEqual(order(seasons), ["s1", "s2", "sp"])
    }

    func testSeasonsKeepTheServerOrder() {
        // The rule never sorts: a server's own order (here a descending one) is kept.
        let seasons = [Season(id: "s3", number: 3), Season(id: "s1", number: 1), Season(id: "s2", number: 2)]
        XCTAssertEqual(order(seasons), ["s3", "s1", "s2"])
    }

    func testEveryEpisodeOfSpecialsMovesInItsOwnOrder() {
        // A show's flat episode list: the specials stay in order among themselves.
        let episodes = [
            Season(id: "sp1", number: 0), Season(id: "sp2", number: 0),
            Season(id: "e1", number: 1), Season(id: "e2", number: 1), Season(id: "e3", number: 2),
        ]
        XCTAssertEqual(order(episodes), ["e1", "e2", "e3", "sp1", "sp2"])
    }

    func testUnnumberedItemsStayWhereTheyAre() {
        let seasons = [Season(id: "sp", number: 0), Season(id: "untitled", number: nil), Season(id: "s1", number: 1)]
        XCTAssertEqual(order(seasons), ["untitled", "s1", "sp"])
    }

    func testNoSpecialsReturnsTheListUntouched() {
        let seasons = [Season(id: "s1", number: 1), Season(id: "s2", number: 2)]
        XCTAssertEqual(order(seasons), ["s1", "s2"])
        XCTAssertEqual(order([]), [])
    }
}
