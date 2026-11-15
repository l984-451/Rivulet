// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeRowOrderTests.swift
//  RivuletTests
//
//  The order Home draws its rows in, set in Settings > Home > Rows. Rows are
//  plain strings here: each one is its own key.
//

import XCTest
@testable import Rivulet

final class HomeRowOrderTests: XCTestCase {

    private func arrange(_ rows: [String], _ saved: [String]) -> [String] {
        HomeRowOrder.arrange(rows, key: { $0 }, savedOrder: saved)
    }

    func test_noSavedOrder_keepsHomesOrder() {
        XCTAssertEqual(arrange(["cw", "movies", "tv"], []), ["cw", "movies", "tv"])
    }

    func test_savedOrder_wins() {
        XCTAssertEqual(arrange(["cw", "movies", "tv"], ["tv", "cw", "movies"]), ["tv", "cw", "movies"])
    }

    /// A new row (a playlist just switched on) goes last, in Home's own order
    /// when there are several.
    func test_unsavedRows_goLast() {
        XCTAssertEqual(arrange(["cw", "movies", "fav", "tv", "playlist"], ["tv", "movies", "cw"]),
                       ["tv", "movies", "cw", "fav", "playlist"])
        XCTAssertEqual(arrange(["new", "cw", "movies"], ["movies", "cw"]), ["movies", "cw", "new"])
    }

    /// Every server's Continue Watching, or a kind's favorites rows, share a key
    /// and stay together in their own order.
    func test_rowsSharingAKey_moveTogether() {
        let rows = ["plex-cw", "jf-cw", "movies", "fav-a", "fav-b"]
        let key = { (row: String) in row.hasSuffix("cw") ? "cw" : row.hasPrefix("fav") ? "fav" : row }
        XCTAssertEqual(HomeRowOrder.arrange(rows, key: key, savedOrder: ["fav", "movies", "cw"]),
                       ["fav-a", "fav-b", "movies", "plex-cw", "jf-cw"])
    }

    func test_savedKeysOfGoneRows_areIgnored() {
        XCTAssertEqual(arrange(["cw", "tv"], ["gone", "tv", "cw"]), ["tv", "cw"])
    }

    func test_moved_swapsWithItsNeighbour_andStopsAtTheEnds() {
        XCTAssertEqual(HomeRowOrder.moved("tv", up: true, among: ["cw", "movies", "tv"], saved: []),
                       ["cw", "tv", "movies"])
        XCTAssertEqual(HomeRowOrder.moved("cw", up: true, among: ["cw", "tv"], saved: ["x"]), ["x"],
                       "no-op at the top")
        XCTAssertEqual(HomeRowOrder.moved("tv", up: false, among: ["cw", "tv"], saved: ["x"]), ["x"],
                       "no-op at the bottom")
    }

    /// A row not on the page now (its server offline) keeps its saved key.
    func test_moved_keepsSavedKeysNotShown() {
        XCTAssertEqual(HomeRowOrder.moved("tv", up: true, among: ["cw", "tv"], saved: ["cw", "offline", "tv"]),
                       ["tv", "cw", "offline"])
    }

    /// A row switched on drops its old saved place, so it lands last.
    func test_placedLast_dropsTheRowsSavedPlace() {
        let keys = HomeRowOrder.placedLast("fav", among: ["cw", "movies", "fav", "tv"], saved: ["fav", "cw", "offline"])
        XCTAssertEqual(keys, ["cw", "movies", "tv", "offline"])
        XCTAssertEqual(arrange(["cw", "fav", "movies", "tv"], keys), ["cw", "movies", "tv", "fav"])
    }

    func test_key_continueWatchingIsOneRow() {
        let cw = CachedHomeHub(id: "a", title: "", isContinueWatching: true, hubKey: nil,
                               hubIdentifier: "home.continue", totalSize: nil, items: [])
        let movies = CachedHomeHub(id: "b", title: "", isContinueWatching: false, hubKey: nil,
                                   hubIdentifier: "movie.recentlyadded.1", totalSize: nil, items: [])
        XCTAssertEqual(HomeRowOrder.key(for: cw), HomeRowOrder.continueWatchingKey)
        XCTAssertEqual(HomeRowOrder.key(for: movies), "movie.recentlyadded.1")
    }
}
