// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  GuideCategoryTabsTests.swift
//  RivuletTests
//
//  The Guide's category tabs: Favorites, sources in order, then groups (#377).
//

import XCTest
@testable import Rivulet

final class GuideCategoryTabsTests: XCTestCase {
    func test_tabTitles() {
        XCTAssertEqual(
            GuideLayoutView.tabTitles(groups: ["HD", "News", "", "HD"], sourceNames: ["Locals", "News", "Locals"],
                                      hasFavorites: true),
            ["Favorites", "Locals", "News", "HD"])
        XCTAssertEqual(GuideLayoutView.tabTitles(groups: ["HD"], sourceNames: [], hasFavorites: false), ["HD"])
        // Groups keep the order given (the source's), not the alphabet (#568).
        XCTAssertEqual(
            GuideLayoutView.tabTitles(groups: ["Sports", "Movies", "Kids", "Sports"], sourceNames: ["Zed"], hasFavorites: true),
            ["Favorites", "Zed", "Sports", "Movies", "Kids"])
        // An M3U group called Favorites keeps its pinned tab.
        XCTAssertEqual(GuideLayoutView.tabTitles(groups: ["Favorites", "A"], sourceNames: [], hasFavorites: false),
                       ["Favorites", "A"])
    }
}
