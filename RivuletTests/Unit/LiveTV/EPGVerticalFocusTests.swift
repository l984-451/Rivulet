// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EPGVerticalFocusTests.swift
//  RivuletTests
//
//  Up/Down in the guide grid. When every cell the focus engine offers is
//  vetoed in favour of the anchor-time programme, the engine's last offer is
//  to leave the grid (nil index path), which on the Guide is the sidebar.
//

import XCTest
@testable import Rivulet

@MainActor
final class EPGVerticalFocusTests: XCTestCase {
    private typealias C = EPGGuide.Coordinator

    func test_engineCellInAnotherRow_targetsThatRow() {
        XCTAssertEqual(C.verticalTargetSection(from: 13, engineSection: 14, movingDown: true, sectionCount: 20), 14)
    }

    func test_sameRow_isNotAVerticalMove() {
        XCTAssertNil(C.verticalTargetSection(from: 13, engineSection: 13, movingDown: true, sectionCount: 20))
    }

    /// Log 2026-10-01: Down from [13, 0], five offers vetoed, then `next=nil`
    /// was allowed and focus went to the sidebar.
    func test_engineLeavingGrid_withARowBelow_staysInTheGrid() {
        XCTAssertEqual(C.verticalTargetSection(from: 13, engineSection: nil, movingDown: true, sectionCount: 20), 14)
        XCTAssertEqual(C.verticalTargetSection(from: 13, engineSection: nil, movingDown: false, sectionCount: 20), 12)
    }

    /// Up from the first channel must still reach the category pills, and
    /// Down from the last has nowhere in the grid to go.
    func test_engineLeavingGrid_atAnEdge_isAllowed() {
        XCTAssertNil(C.verticalTargetSection(from: 0, engineSection: nil, movingDown: false, sectionCount: 20))
        XCTAssertNil(C.verticalTargetSection(from: 19, engineSection: nil, movingDown: true, sectionCount: 20))
    }

    // MARK: - Horizontal position on Up/Down

    /// Log 2026-10-01: an Up/Down focus scroll arrives through
    /// `scrollViewWillEndDragging` with the engine's own x (321 -> 679,
    /// 768 -> -129), and the scroll then reports decelerating, so the held
    /// position followed it and the guide crept sideways.
    func test_verticalMove_keepsTheHeldX() {
        XCTAssertEqual(C.focusScrollTargetX(proposed: 679, lockedX: 321, isHorizontalMove: false), 321)
        XCTAssertEqual(C.focusScrollTargetX(proposed: -129, lockedX: 768, isHorizontalMove: false), 768)
    }

    func test_horizontalMove_snapsTheProposedXToAHalfHour() {
        XCTAssertEqual(C.focusScrollTargetX(proposed: 229, lockedX: -129, isHorizontalMove: true),
                       C.snappedX(for: 229))
    }
}
