// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import XCTest
@testable import Rivulet

@MainActor
final class CinematicBrowseTests: XCTestCase {
    func test_navigationRequestsSparsePagesAndStopsAtLibraryBounds() {
        let browser = CinematicBrowseViewController(items: Array(repeating: .gridPlaceholder, count: 40))
        var requested: [Int] = []
        browser.onRequestItem = { requested.append($0) }
        browser.loadViewIfNeeded()
        browser.move(by: -1)
        XCTAssertEqual(browser.selectedIndex, 0)
        browser.move(by: 25)
        XCTAssertEqual(browser.selectedIndex, 25)
        XCTAssertTrue(requested.contains(25))
        XCTAssertTrue(requested.contains(37), "Prefetch the following page before it is reached")
        XCTAssertTrue(requested.contains(13), "Keep reverse browsing ready too")
        browser.move(by: 100)
        XCTAssertEqual(browser.selectedIndex, 39)
        browser.view.accessibilityDecrement()
        XCTAssertEqual(browser.selectedIndex, 38)
    }

    func test_pageUpdatesPreservePositionAndLibraryShrinkClampsIt() {
        let browser = CinematicBrowseViewController(items: Array(repeating: .gridPlaceholder, count: 40), selectedIndex: 25)
        browser.loadViewIfNeeded()
        browser.update(items: Array(repeating: .gridPlaceholder, count: 60))
        XCTAssertEqual(browser.selectedIndex, 25)
        browser.update(items: Array(repeating: .gridPlaceholder, count: 10))
        XCTAssertEqual(browser.selectedIndex, 9)
        browser.update(items: [])
        browser.move(by: 1)
        XCTAssertEqual(browser.selectedIndex, 0)
        XCTAssertEqual(browser.view.accessibilityLabel, "No Titles")
    }
}
