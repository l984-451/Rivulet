// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CaptionSizingTests.swift
//  RivuletTests
//
//  Pins caption point size to what AVKit renders (#299, #422). Measured on the
//  tvOS 27.0 simulator against AVPlayerViewController captioning a black HLS
//  stream, one caption profile at a time, compared by ink width and height.
//

import XCTest
@testable import Rivulet

final class CaptionSizingTests: XCTestCase {

    private let presentationHeight: CGFloat = 1080

    /// What AVKit draws at each value the system can report, for any style other
    /// than the built-in Default (edited styles, copies of Default, Classic).
    private let avkitSizes: [(reported: CGFloat, points: CGFloat)] = [
        (0.35, 18.3), (0.60, 31.2), (1.00, 51.9), (1.50, 78.0), (2.00, 104.0)
    ]

    /// AVKit's two-line pitch at Default (46.2pt), 1.0 (51.9pt) and 1.5 (78pt): 66, 76 and 112pt.
    func test_lineSpacing_givesAVKitsLinePitch() {
        for (size, pitch) in [(CGFloat(46.2), CGFloat(66)), (51.9, 76), (78, 112)] {
            let font = UIFont.systemFont(ofSize: size)
            XCTAssertEqual(font.lineHeight + CaptionOverlayView.Metrics.lineSpacing(for: font), pitch, accuracy: 1.5)
        }
    }

    func test_pointSize_matchesAVKitAtEveryReportableSize() {
        for expected in avkitSizes {
            let size = CaptionOverlayView.Metrics.pointSize(
                presentationHeight: presentationHeight, fontScale: expected.reported)
            XCTAssertEqual(size, expected.points, accuracy: 0.6,
                           "At reported \(expected.reported) AVKit draws "
                           + "\(expected.points)pt, got \(size)pt.")
        }
    }

    /// Apple's built-in Default style reports 1.0 but draws 46.2pt, about 11%
    /// under every other style at 1.0. #422 was an edited style drawn at 46.2.
    func test_pointSize_systemDefaultStyle_drawsSmallerThanAnEditedStyleAtTheSameSize() {
        let systemDefault = CaptionOverlayView.Metrics.pointSize(
            presentationHeight: presentationHeight, fontScale: 1.0, isSystemDefault: true)
        let edited = CaptionOverlayView.Metrics.pointSize(
            presentationHeight: presentationHeight, fontScale: 1.0)
        XCTAssertEqual(systemDefault, 46.2, accuracy: 0.6)
        XCTAssertEqual(edited, 51.9, accuracy: 0.6)
    }

    /// A degenerate layout pass must not collapse captions to nothing.
    func test_pointSize_withZeroHeight_fallsBackToTheAssumedPresentation() {
        let size = CaptionOverlayView.Metrics.pointSize(presentationHeight: 0, fontScale: 1.0,
                                                        isSystemDefault: true)
        XCTAssertEqual(size, 46.2, accuracy: 0.6)
    }

    /// An unset or out-of-range system value reads as "no scaling". The API
    /// reports 1.0 for anything off its five-bucket ladder.
    func test_fontScale_treatsNonPositiveAsUnscaled() {
        XCTAssertEqual(CaptionAppearance.fontScale(forRelativeSize: 0), 1.0)
        XCTAssertEqual(CaptionAppearance.fontScale(forRelativeSize: -1), 1.0)
    }

    /// Every value the API can actually return must pass through untouched; the
    /// clamp is a sanity net and must never bind on a real setting.
    func test_fontScale_passesThroughEveryReportableValue() {
        for reported in [0.35, 0.6, 1.0, 1.5, 2.0] as [CGFloat] {
            XCTAssertEqual(CaptionAppearance.fontScale(forRelativeSize: reported), reported,
                           "The clamp must not alter \(reported), which tvOS really reports.")
        }
    }
}
