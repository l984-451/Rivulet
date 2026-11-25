// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The About age card never makes up "NR": a missing rating reads "Unknown".
final class AboutAgeTextTests: XCTestCase {
    func test_missingRating_readsUnknown() {
        for missing in [nil, "", " ", "N/A", "n/a"] {
            XCTAssertEqual(AboutCollectionCell.ageText(missing), String(localized: "Unknown"), "\(String(describing: missing))")
        }
    }

    func test_serversRating_showsAsSent() {
        for rating in ["PG-13", "FSK 16", "NR", "Not Rated"] {
            XCTAssertEqual(AboutCollectionCell.ageText(rating), rating)
        }
    }
}
