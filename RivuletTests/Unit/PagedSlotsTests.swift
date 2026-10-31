// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PagedSlotsTests: XCTestCase {
    func test_firstPage_sizesToTotal() {
        var slots = PagedSlots<Int>(pageSize: 3)
        slots.fill([0, 1, 2], at: 0, total: 8)
        XCTAssertEqual(slots.slots, [0, 1, 2, nil, nil, nil, nil, nil])
    }

    func test_pagesFillOutOfOrder() {
        var slots = PagedSlots<Int>(pageSize: 3)
        slots.fill([0, 1, 2], at: 0, total: 8)
        slots.fill([6, 7], at: 6, total: 8)
        XCTAssertEqual(slots.slots, [0, 1, 2, nil, nil, nil, 6, 7])
    }

    func test_claims_coverWholePage() {
        var slots = PagedSlots<Int>(pageSize: 3)
        XCTAssertEqual(slots.unclaimedPage(containing: 4), 3)
        slots.claim(3)
        XCTAssertNil(slots.unclaimedPage(containing: 5))
        slots.release(3)
        XCTAssertEqual(slots.unclaimedPage(containing: 5), 3)
        XCTAssertEqual(slots.claimedPages, [])
    }

    func test_shortPage_endsAnOverstatedList() {
        var slots = PagedSlots<Int>(pageSize: 3)
        slots.fill([0, 1, 2], at: 0, total: 9)
        slots.fill([3], at: 3, total: 9)
        XCTAssertEqual(slots.slots, [0, 1, 2, 3])
    }

    func test_shrinkingTotal_truncates() {
        var slots = PagedSlots<Int>(pageSize: 3)
        slots.fill([0, 1, 2], at: 0, total: 8)
        slots.fill([0, 1, 2], at: 0, total: 5)
        XCTAssertEqual(slots.slots.count, 5)
    }
}
