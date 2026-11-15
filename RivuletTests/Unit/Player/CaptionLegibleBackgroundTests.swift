// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreMedia
import XCTest
@testable import Rivulet

@MainActor
final class CaptionLegibleBackgroundTests: XCTestCase {

    private func argb(_ a: Double, _ r: Double, _ g: Double, _ b: Double) -> [NSNumber] {
        [a, r, g, b].map { NSNumber(value: $0) }
    }

    func test_characterBackground_becomesRunBackground() throws {
        let key = NSAttributedString.Key(kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String)
        let attr = NSMutableAttributedString(string: "plain ")
        attr.append(NSAttributedString(string: "blue", attributes: [key: argb(1, 0, 0, 1)]))

        let line = try XCTUnwrap(LiveTVAetherPlayerViewController.styledLine(from: attr))
        XCTAssertEqual(line.runs.count, 2)
        XCTAssertNil(line.runs[0].backgroundColor)
        XCTAssertEqual(line.runs[1].backgroundColor, UIColor(red: 0, green: 0, blue: 1, alpha: 1))
    }

    func test_cueBoxBackground_isIgnored() throws {
        let key = NSAttributedString.Key(kCMTextMarkupAttribute_BackgroundColorARGB as String)
        let attr = NSAttributedString(string: "boxed", attributes: [key: argb(1, 1, 1, 0)])

        let line = try XCTUnwrap(LiveTVAetherPlayerViewController.styledLine(from: attr))
        XCTAssertNil(line.runs.first?.backgroundColor)
    }
}
