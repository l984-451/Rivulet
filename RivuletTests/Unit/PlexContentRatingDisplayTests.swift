// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PlexContentRatingDisplayTests: XCTestCase {
    func test_countryPrefixIsStripped() {
        XCTAssertEqual(PlexMetadata.displayContentRating("uk/12A"), "12A")
        XCTAssertEqual(PlexMetadata.displayContentRating("au/M"), "M")
    }

    func test_unprefixedRatingIsUnchanged() {
        XCTAssertEqual(PlexMetadata.displayContentRating("PG-13"), "PG-13")
        XCTAssertNil(PlexMetadata.displayContentRating(nil))
    }

    func test_emptyRemainderKeepsRaw() {
        XCTAssertEqual(PlexMetadata.displayContentRating("uk/"), "uk/")
    }

    /// The Plex hero shows the display form too, not Plex's raw "de/12" (#467).
    @MainActor
    func test_plexHero_showsTheDisplayRating() {
        var meta = PlexMetadata()
        meta.ratingKey = "1"
        meta.type = "movie"
        meta.title = "Charge"
        meta.contentRating = "de/12"
        let hero = HeroSlideView()
        hero.configure(item: meta, serverURL: "http://s", authToken: "t", animated: false)
        XCTAssertEqual(hero.ratingBadgeText, "ab 12 Jahren")
    }

    func testGermanAgesReadAsTheTVAppShowsThem() {
        XCTAssertEqual(PlexMetadata.displayContentRating("de/16"), "ab 16 Jahren")
        XCTAssertEqual(PlexMetadata.displayContentRating("de/FSK"), "FSK")
    }
}
