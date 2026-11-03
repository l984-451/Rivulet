// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CardStepperRowTests.swift
//  RivuletTests
//
//  The menu's Delay and Height rows take focus themselves and step on Left
//  and Right; there are no -/+ buttons to reach. VoiceOver steps the same row
//  as an adjustable element.
//

import XCTest
@testable import Rivulet

@MainActor
final class CardStepperRowTests: XCTestCase {

    func test_rowIsTheFocusStopAndStepsAsAnAdjustableElement() {
        var value = 0
        let row = CardStepperRowView(config: CardStepperConfig(
            title: "Delay", value: { String(value) }, onStep: { value += $0 }))

        XCTAssertTrue(row.canBecomeFocused, "the row, not a -/+ button, takes focus")
        XCTAssertTrue(row.accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(row.accessibilityValue, "0")

        row.accessibilityIncrement()
        XCTAssertEqual(value, 1)
        XCTAssertEqual(row.accessibilityValue, "1", "the row re-reads the value after a step")

        row.accessibilityDecrement()
        row.accessibilityDecrement()
        XCTAssertEqual(value, -1)
        XCTAssertEqual(row.accessibilityValue, "-1")
    }

    func test_listHoldsNoStepperButtons() {
        let stepper = CardStepperConfig(title: "Delay", value: { "0.0s" }, onStep: { _ in })
        let list = CardTrackListView(header: "Subtitles", rows: [], steppers: [stepper], onSelect: { _ in })
        list.frame = CGRect(x: 0, y: 0, width: 450, height: 400)
        list.layoutIfNeeded()

        let focusable = focusableDescendants(of: list)
        XCTAssertEqual(focusable.count, 1)
        XCTAssertTrue(focusable.first is CardStepperRowView)
    }

    private func focusableDescendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { sub -> [UIView] in
            (sub.canBecomeFocused ? [sub] : []) + focusableDescendants(of: sub)
        }
    }
}
