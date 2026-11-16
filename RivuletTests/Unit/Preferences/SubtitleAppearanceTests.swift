// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Subtitle Brightness.

import CoreGraphics
import XCTest
@testable import Rivulet

final class SubtitleAppearanceTests: XCTestCase {

    // MARK: Brightness

    private func rgba(_ color: CGColor) throws -> [CGFloat] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(color.converted(to: space, intent: .defaultIntent, options: nil)?.components)
    }

    func test_dim_whiteAtFortyPercent_isOpaqueGrey() throws {
        let c = try rgba(SubtitleAppearance.dim(CGColor(gray: 1, alpha: 1), by: 0.4))
        XCTAssertEqual(c[0], 0.4, accuracy: 0.001)
        XCTAssertEqual(c[1], 0.4, accuracy: 0.001)
        XCTAssertEqual(c[2], 0.4, accuracy: 0.001)
        XCTAssertEqual(c[3], 1, accuracy: 0.001)
    }

    func test_dim_keepsAlpha() throws {
        let c = try rgba(SubtitleAppearance.dim(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.6), by: 0.5))
        XCTAssertEqual(c[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(c[1], 0.25, accuracy: 0.001)
        XCTAssertEqual(c[2], 0, accuracy: 0.001)
        XCTAssertEqual(c[3], 0.6, accuracy: 0.001)
    }

    func test_dim_fullBrightness_returnsColourUnchanged() {
        let white = CGColor(gray: 1, alpha: 1)
        XCTAssertEqual(SubtitleAppearance.dim(white, by: 1), white)
    }

    func test_clamp_holdsToFortyThroughHundred() {
        XCTAssertEqual(SubtitleAppearance.clampBrightness(0.1), 0.4)
        XCTAssertEqual(SubtitleAppearance.clampBrightness(1.5), 1)
        XCTAssertEqual(SubtitleAppearance.clampBrightness(.nan), 1)
        XCTAssertEqual(SubtitleAppearance.clampBrightness(0.7), 0.7)
    }

    func test_dim_belowMinimum_clampsToForty() throws {
        let c = try rgba(SubtitleAppearance.dim(CGColor(gray: 1, alpha: 1), by: 0.1))
        XCTAssertEqual(c[0], 0.4, accuracy: 0.001)
    }

    func test_nextBrightness_stepsDownThenWraps() {
        XCTAssertEqual(SubtitleAppearance.nextBrightness(after: 1), 0.9)
        XCTAssertEqual(SubtitleAppearance.nextBrightness(after: 0.5), 0.4)
        XCTAssertEqual(SubtitleAppearance.nextBrightness(after: 0.4), 1)
    }

    /// The in-player stepper: Right brighter, Left dimmer, stopping at 100% and 40%.
    func test_steppedBrightness_stepsTenPercent_andStopsAtTheEnds() {
        XCTAssertEqual(SubtitleAppearance.steppedBrightness(0.7, by: 1), 0.8)
        XCTAssertEqual(SubtitleAppearance.steppedBrightness(0.7, by: -1), 0.6)
        XCTAssertEqual(SubtitleAppearance.steppedBrightness(1, by: 1), 1)
        XCTAssertEqual(SubtitleAppearance.steppedBrightness(0.4, by: -1), 0.4)
        // An off-grid stored value steps from its nearest option.
        XCTAssertEqual(SubtitleAppearance.steppedBrightness(0.72, by: 1), 0.8)
    }

    /// Caption surfaces restyle on the caption-change notification, so a change must post it.
    func test_settingBrightness_postsTheCaptionChangeNotification() {
        let saved = UserDefaults.standard.object(forKey: SubtitleAppearance.brightnessKey)
        defer { UserDefaults.standard.set(saved, forKey: SubtitleAppearance.brightnessKey) }
        let posted = expectation(forNotification: CaptionAppearance.changedNotification, object: nil)
        SubtitleAppearance.brightness = 0.7
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(SubtitleAppearance.brightness, 0.7)
    }

    func test_dimASSColor_scalesRGB_keepsTransparency() {
        XCTAssertEqual(SubtitleAppearance.dimASSColor(0xFFFFFF00, by: 0.4), 0x66666600)
        XCTAssertEqual(SubtitleAppearance.dimASSColor(0xFF0000_80, by: 0.5), 0x80000080)
        XCTAssertEqual(SubtitleAppearance.dimASSColor(0x12345678, by: 1), 0x12345678)
    }
}
