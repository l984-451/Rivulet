// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsTriviaRowLayoutTests.swift
//  RivuletTests
//
//  Trivia cards in the Insights box widen to show their fact whole: a short
//  fact takes the narrowest card, a long one a wider card, never a clipped one.
//

import XCTest
@testable import Rivulet

@MainActor
final class InsightsTriviaRowLayoutTests: XCTestCase {

    private let sentence = "A reasonably long trivia sentence that must wrap across several lines. "

    func test_shortFact_takesTheNarrowestCard() {
        XCTAssertEqual(InsightsTriviaCardView.width(for: "Short fact.", showsCategory: false), 460)
    }

    func test_longerFact_widensUntilItFits() {
        let short = InsightsTriviaCardView.width(for: sentence, showsCategory: false)
        let long = InsightsTriviaCardView.width(for: String(repeating: sentence, count: 4), showsCategory: false)
        XCTAssertGreaterThan(long, short)
    }

    func test_categoryLine_needsAtLeastAsMuchWidth() {
        let text = String(repeating: sentence, count: 3)
        XCTAssertGreaterThanOrEqual(InsightsTriviaCardView.width(for: text, showsCategory: true),
                                    InsightsTriviaCardView.width(for: text, showsCategory: false))
    }
}
