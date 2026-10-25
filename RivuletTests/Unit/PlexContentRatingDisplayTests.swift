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
}
