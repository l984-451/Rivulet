// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeCollectionPageTests.swift
//  RivuletTests
//
//  The collection page is PlexHomeViewController in `.collection` mode: one
//  `.grid` section under the collection's title. The supplementary header
//  takes its style from the section's `headerStyle`, so a titled grid must
//  carry the Watchlist page's title style. The untitled library grid keeps
//  the row style it has always had.
//
//  `gridSlotRange` is the write range for a loaded page. A reload can land
//  after the collection shrank below the page's start, and an unclamped
//  `start..<end` then traps with "Range requires lowerBound <= upperBound".
//

import XCTest
@testable import Rivulet

@MainActor
final class HomeCollectionPageTests: XCTestCase {

    func test_titledGrid_usesWatchlistHeaderStyle() {
        let section = HomeSectionData.grid(items: [], title: "James Bond Collection")
        XCTAssertEqual(section.id, .grid)
        XCTAssertEqual(section.kind, .grid)
        XCTAssertEqual(section.title, "James Bond Collection")
        XCTAssertTrue(section.headerStyle == .swiftUIWatchlist)
        XCTAssertNil(section.totalSize, "a title-only header carries no count")
    }

    func test_untitledGrid_keepsRowHeaderStyle() {
        let section = HomeSectionData.grid(items: [])
        XCTAssertNil(section.title)
        XCTAssertTrue(section.headerStyle == .swiftUIInfiniteRow)
    }

    // MARK: - gridSlotRange

    func test_gridSlotRange_pageStartBeyondShrunkGrid_isEmpty() {
        // Page 1 re-requested after the collection dropped below its start.
        let range = PlexHomeViewController.gridSlotRange(start: 60, returned: 0, slotCount: 55)
        XCTAssertEqual(range, 60..<60)
        XCTAssertTrue(range.isEmpty)
    }

    func test_gridSlotRange_partialLastPage() {
        XCTAssertEqual(PlexHomeViewController.gridSlotRange(start: 60, returned: 10, slotCount: 70), 60..<70)
    }

    func test_gridSlotRange_pageClampedByShrink() {
        XCTAssertEqual(PlexHomeViewController.gridSlotRange(start: 0, returned: 60, slotCount: 55), 0..<55)
    }

    func test_gridSlotRange_fullPage() {
        XCTAssertEqual(PlexHomeViewController.gridSlotRange(start: 0, returned: 60, slotCount: 130), 0..<60)
    }
}
