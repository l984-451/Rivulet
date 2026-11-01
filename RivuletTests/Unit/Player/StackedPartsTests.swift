// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class StackedPartsTests: XCTestCase {

    // Part lengths of the stacked Sintel test title on the home PMS.
    private let parts = StackedParts([(file: "pt1", duration: 472.166), (file: "pt2", duration: 421.407)])!

    func test_singleFileOrMissingLength_isNotStacked() {
        XCTAssertNil(StackedParts([(file: "a", duration: 100)]))
        XCTAssertNil(StackedParts([(file: "a", duration: 100), (file: "b", duration: nil)]))
        XCTAssertNil(StackedParts([(file: "a", duration: 100), (file: "b", duration: 0)]))
    }

    func test_durationIsTheSum() {
        XCTAssertEqual(parts.duration, 893.573, accuracy: 0.0001)
        XCTAssertEqual(parts.starts, [0, 472.166])
    }

    func test_locate() {
        XCTAssertEqual(parts.locate(0).index, 0)
        XCTAssertEqual(parts.locate(-5).offset, 0)
        XCTAssertEqual(parts.locate(472.0).index, 0)
        XCTAssertEqual(parts.locate(472.166).index, 1)
        XCTAssertEqual(parts.locate(600).offset, 600 - 472.166, accuracy: 0.0001)
        XCTAssertEqual(parts.locate(10_000).index, 1)
    }
}
