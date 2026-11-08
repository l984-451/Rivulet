// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import CoreGraphics
@testable import Rivulet

final class CaptionHeightTests: XCTestCase {

    func testOffsetIsClampedUnitsTimesStep() {
        XCTAssertEqual(CaptionHeight.offset(forUnits: 3), 60)
        XCTAssertEqual(CaptionHeight.offset(forUnits: 999), 800)
        XCTAssertEqual(CaptionHeight.offset(forUnits: -999), -300)
    }

    func testLabel() {
        XCTAssertEqual(CaptionHeight.formatted(0), "0")
        XCTAssertEqual(CaptionHeight.formatted(3), "+3")
        XCTAssertEqual(CaptionHeight.formatted(-2), "-2")
    }

    /// Resting 940 on a 1000 screen: units move it both ways, and the screen bounds it.
    func testBandBottomMovesAndStaysOnScreen() {
        XCTAssertEqual(CaptionHeight.bandBottom(resting: 940, units: 0, containerHeight: 1_000), 940)
        XCTAssertEqual(CaptionHeight.bandBottom(resting: 940, units: 5, containerHeight: 1_000), 840)
        XCTAssertEqual(CaptionHeight.bandBottom(resting: 940, units: -15, containerHeight: 1_000), 1_000)
        XCTAssertEqual(CaptionHeight.bandBottom(resting: 940, units: 40, containerHeight: 1_000), 200, accuracy: 0.001)
    }

    func testBandBottomStaysAboveTheChrome() {
        XCTAssertEqual(CaptionHeight.bandBottom(resting: 940, units: -5, containerHeight: 1_000, cap: 700), 700)
        XCTAssertEqual(CaptionHeight.bandBottom(resting: 940, units: 25, containerHeight: 1_000, cap: 700), 440)
    }

    func testStoredValueIsClamped() {
        let saved = CaptionHeight.units
        defer { CaptionHeight.units = saved }
        CaptionHeight.units = 999
        XCTAssertEqual(CaptionHeight.units, 40)
        CaptionHeight.step(by: -200)
        XCTAssertEqual(CaptionHeight.units, -15)
    }
}
