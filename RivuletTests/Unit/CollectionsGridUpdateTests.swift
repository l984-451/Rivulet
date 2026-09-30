// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CollectionsGridUpdateTests.swift
//  RivuletTests
//
//  What a refreshed collection list does to a library grid that is showing
//  collections (the Titles / Collections switch). Grid slot ids are
//  positional, so the order of these checks decides whether the focused tile
//  can change collection under the user.
//

import XCTest
@testable import Rivulet

final class CollectionsGridUpdateTests: XCTestCase {

    private func update(grid: [String?], list: [String?], busy: Bool) -> PlexHomeViewController.CollectionsGridUpdate {
        PlexHomeViewController.collectionsGridUpdate(gridKeys: grid, listKeys: list, isGridBusy: busy)
    }

    func test_sameList_changesNothing() {
        XCTAssertEqual(update(grid: ["9144", "118562"], list: ["9144", "118562"], busy: false), .unchanged)
    }

    func test_sameList_whileBusy_changesNothing() {
        XCTAssertEqual(update(grid: ["9144"], list: ["9144"], busy: true), .unchanged)
    }

    /// The empty check beats the hold: the header hides the switch once the
    /// list is empty, so a held collections grid would have no way out.
    func test_emptiedList_returnsToTitles_evenWhileBusy() {
        XCTAssertEqual(update(grid: ["9144"], list: [], busy: true), .titles)
    }

    /// Both empty is not "unchanged": an empty collections grid with the
    /// switch hidden would be stuck until relaunch.
    func test_emptyList_withEmptyGrid_returnsToTitles() {
        XCTAssertEqual(update(grid: [], list: [], busy: false), .titles)
    }

    func test_changedList_whileBusy_holds() {
        XCTAssertEqual(update(grid: ["9144"], list: ["9144", "118562"], busy: true), .hold)
    }

    func test_changedList_whenIdle_applies() {
        XCTAssertEqual(update(grid: ["9144"], list: ["9144", "118562"], busy: false), .apply)
    }

    /// Same members in a new order: every moved slot shows a different
    /// collection, so it counts as a change.
    func test_reorderedList_applies() {
        XCTAssertEqual(update(grid: ["9144", "118562"], list: ["118562", "9144"], busy: false), .apply)
    }
}
