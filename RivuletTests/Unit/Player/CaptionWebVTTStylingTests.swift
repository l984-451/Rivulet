// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CaptionWebVTTStylingTests.swift
//  RivuletTests
//
//  WebVTT features the overlay resolves itself: snap-to-lines `line:` numbers,
//  and run backgrounds read off AVPlayer's legible output on the Live TV path.
//

import CoreMedia
import XCTest
@testable import Rivulet

@MainActor
final class CaptionWebVTTStylingTests: XCTestCase {

    private let picture = CGRect(x: 0, y: 60, width: 1920, height: 960)
    private let lineHeight: CGFloat = 50

    // MARK: Line numbers

    func test_lineZero_sitsAtPictureTop() {
        let top = CaptionOverlayView.snappedLineTop(lineNumber: 0, lineHeight: lineHeight,
                                                    boxHeight: 60, picture: picture)
        XCTAssertEqual(top, picture.minY)
    }

    func test_positiveLine_countsDownFromTop() {
        let top = CaptionOverlayView.snappedLineTop(lineNumber: 2, lineHeight: lineHeight,
                                                    boxHeight: 60, picture: picture)
        XCTAssertEqual(top, picture.minY + 100)
    }

    func test_lineMinusOne_putsBoxBottomOnPictureBottom() {
        let top = CaptionOverlayView.snappedLineTop(lineNumber: -1, lineHeight: lineHeight,
                                                    boxHeight: 60, picture: picture)
        XCTAssertEqual(top + 60, picture.maxY)
    }

    func test_lineMinusThree_sitsTwoLinesAboveBottom() {
        let top = CaptionOverlayView.snappedLineTop(lineNumber: -3, lineHeight: lineHeight,
                                                    boxHeight: 60, picture: picture)
        XCTAssertEqual(top + 60, picture.maxY - 100)
    }

    func test_outOfRangeLine_staysInsidePicture() {
        let low = CaptionOverlayView.snappedLineTop(lineNumber: 400, lineHeight: lineHeight,
                                                    boxHeight: 60, picture: picture)
        XCTAssertEqual(low, picture.maxY - 60)
        let high = CaptionOverlayView.snappedLineTop(lineNumber: -400, lineHeight: lineHeight,
                                                     boxHeight: 60, picture: picture)
        XCTAssertEqual(high, picture.minY)
    }

    // MARK: Legible backgrounds

    private func argb(_ a: Double, _ r: Double, _ g: Double, _ b: Double) -> [NSNumber] {
        [a, r, g, b].map { NSNumber(value: $0) }
    }

    func test_legible_characterBackground_becomesRunBackground() throws {
        let key = NSAttributedString.Key(kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String)
        let attr = NSMutableAttributedString(string: "plain ")
        attr.append(NSAttributedString(string: "blue", attributes: [key: argb(1, 0, 0, 1)]))

        let line = try XCTUnwrap(LiveTVAetherPlayerViewController.styledLine(from: attr))
        XCTAssertEqual(line.runs.count, 2)
        XCTAssertNil(line.runs[0].backgroundColor)
        XCTAssertEqual(line.runs[1].backgroundColor, UIColor(red: 0, green: 0, blue: 1, alpha: 1))
    }

    func test_legible_cueBackground_fillsInWhenNoCharacterBackground() throws {
        let key = NSAttributedString.Key(kCMTextMarkupAttribute_BackgroundColorARGB as String)
        let attr = NSAttributedString(string: "boxed", attributes: [key: argb(1, 1, 1, 0)])

        let line = try XCTUnwrap(LiveTVAetherPlayerViewController.styledLine(from: attr))
        XCTAssertEqual(line.runs.first?.backgroundColor, UIColor(red: 1, green: 1, blue: 0, alpha: 1))
    }

    func test_legible_noBackground_staysSilent() throws {
        let line = try XCTUnwrap(
            LiveTVAetherPlayerViewController.styledLine(from: NSAttributedString(string: "plain")))
        XCTAssertNil(line.runs.first?.backgroundColor)
    }
}
