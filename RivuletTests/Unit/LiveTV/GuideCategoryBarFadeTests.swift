// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  GuideCategoryBarFadeTests.swift
//  RivuletTests
//
//  When the Guide's category pills fade at each end of the row.
//

import XCTest
@testable import Rivulet

final class GuideCategoryBarFadeTests: XCTestCase {
    private func fades(offset: CGFloat, content: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        GuideCategoryBarView.edgeFades(offsetX: offset, contentWidth: content, width: 1000, fadeWidth: 80)
    }

    func test_pillsThatFit_doNotFade() {
        let result = fades(offset: 0, content: 600)
        XCTAssertEqual(result.leading, 0)
        XCTAssertEqual(result.trailing, 0)
    }

    func test_morePillsToTheRight_fadeTheRightEndOnly() {
        let result = fades(offset: 0, content: 3000)
        XCTAssertEqual(result.leading, 0)
        XCTAssertEqual(result.trailing, 1)
    }

    func test_midList_fadesBothEnds() {
        let result = fades(offset: 500, content: 3000)
        XCTAssertEqual(result.leading, 1)
        XCTAssertEqual(result.trailing, 1)
    }

    func test_scrolledToTheEnd_fadesTheLeftEndOnly() {
        let result = fades(offset: 2000, content: 3000)
        XCTAssertEqual(result.leading, 1)
        XCTAssertEqual(result.trailing, 0)
    }

    func test_fadeBuildsOverItsWidth() {
        XCTAssertEqual(fades(offset: 40, content: 3000).leading, 0.5)
        XCTAssertEqual(fades(offset: 1960, content: 3000).trailing, 0.5)
    }

    func test_bouncePastTheEnds_staysInRange() {
        XCTAssertEqual(fades(offset: -20, content: 3000).leading, 0)
        XCTAssertEqual(fades(offset: 2020, content: 3000).trailing, 0)
    }
}
