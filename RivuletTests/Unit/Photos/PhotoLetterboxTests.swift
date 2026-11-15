// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PhotoLetterboxTests: XCTestCase {
    private let screen = CGSize(width: 1920, height: 1080)

    func test_portrait_needsFill() {
        XCTAssertTrue(PhotoLetterbox.needsFill(imageSize: CGSize(width: 3000, height: 4000), screenSize: screen))
    }

    func test_screenAspect_staysBlack() {
        XCTAssertFalse(PhotoLetterbox.needsFill(imageSize: CGSize(width: 3840, height: 2160), screenSize: screen))
    }

    // 16:9.4 is 4.3% narrower than the screen; 16:9.5 would be 5.3% and take the fill.
    func test_within5Percent_staysBlack() {
        XCTAssertFalse(PhotoLetterbox.needsFill(imageSize: CGSize(width: 16, height: 9.4), screenSize: screen))
        XCTAssertTrue(PhotoLetterbox.needsFill(imageSize: CGSize(width: 16, height: 9.5), screenSize: screen))
    }

    func test_widePanorama_needsFill() {
        XCTAssertTrue(PhotoLetterbox.needsFill(imageSize: CGSize(width: 8000, height: 2000), screenSize: screen))
    }

    func test_zeroSize_staysBlack() {
        XCTAssertFalse(PhotoLetterbox.needsFill(imageSize: .zero, screenSize: screen))
    }
}
