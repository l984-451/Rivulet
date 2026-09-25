// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ClickpadDirectionTests.swift
//  RivuletTests
//
//  InputConfig.clickpadHorizontalDirection: where on the Siri Remote clickpad a
//  touch counts as a Left/Right edge. The case that matters is the one an
//  x-only test got wrong: an Up or Down click made a little off the vertical
//  axis must NOT read as a Left/Right click.
//

import XCTest
@testable import Rivulet

@MainActor
final class ClickpadDirectionTests: XCTestCase {

    func testClearHorizontalEdgesReadAsLeftAndRight() {
        XCTAssertEqual(InputConfig.clickpadHorizontalDirection(x: 0.9, y: 0.1), true)
        XCTAssertEqual(InputConfig.clickpadHorizontalDirection(x: -0.9, y: -0.2), false)
    }

    func testCentreReadsAsNoDirection() {
        XCTAssertNil(InputConfig.clickpadHorizontalDirection(x: 0, y: 0))
        XCTAssertNil(InputConfig.clickpadHorizontalDirection(x: 0.2, y: 0.1))
    }

    func testOffAxisVerticalClickIsNotHorizontal() {
        // Past the old x-only threshold, but clearly an Up / Down click.
        XCTAssertNil(InputConfig.clickpadHorizontalDirection(x: 0.35, y: 0.9))
        XCTAssertNil(InputConfig.clickpadHorizontalDirection(x: -0.5, y: -0.8))
    }

    func testEdgeClickThresholdIsStricterThanTracking() {
        // Tracks as a right touch, but too near the centre to turn a .select
        // into an edge click.
        XCTAssertEqual(InputConfig.clickpadHorizontalDirection(x: 0.45, y: 0), true)
        XCTAssertNil(InputConfig.clickpadHorizontalDirection(
            x: 0.45, y: 0, threshold: InputConfig.edgeClickThreshold))
        XCTAssertEqual(InputConfig.clickpadHorizontalDirection(
            x: 0.8, y: 0.1, threshold: InputConfig.edgeClickThreshold), true)
    }
}
