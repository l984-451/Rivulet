// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class CaptionWritingDirectionTests: XCTestCase {
    func testHebrewIsRightToLeft() {
        XCTAssertEqual(CaptionOverlayView.baseWritingDirection(for: "שלום, מה שלומך?"), .rightToLeft)
    }

    func testHebrewOpeningWithLatinNameStaysRightToLeft() {
        XCTAssertEqual(CaptionOverlayView.baseWritingDirection(for: "John אמר שהוא יגיע מחר."), .rightToLeft)
    }

    func testArabicIsRightToLeft() {
        XCTAssertEqual(CaptionOverlayView.baseWritingDirection(for: "مرحبا بالعالم."), .rightToLeft)
    }

    func testEnglishIsLeftToRight() {
        XCTAssertEqual(CaptionOverlayView.baseWritingDirection(for: "Hello there."), .leftToRight)
    }

    func testNoLettersIsNatural() {
        XCTAssertEqual(CaptionOverlayView.baseWritingDirection(for: "♪ 123 ♪"), .natural)
    }
}
