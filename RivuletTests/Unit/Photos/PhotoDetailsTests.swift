// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PhotoDetailsTests: XCTestCase {
    func test_conversions() {
        XCTAssertEqual(PhotoDetails.fNumber(apex: 1.3561438531849228), 1.6)
        XCTAssertEqual(PhotoDetails.fNumber(plex: "f/1.6"), 1.6)
        XCTAssertNil(PhotoDetails.fNumber(plex: ""))
        XCTAssertEqual(PhotoDetails.exposureSeconds(plex: "1/5"), 0.2)
        XCTAssertEqual(PhotoDetails.exposureSeconds(plex: "2"), 2)
        XCTAssertEqual(PhotoDetails.exposureText(0.0125), "1/80 s")
        XCTAssertEqual(PhotoDetails.exposureText(2), "2 s")
    }

    func test_cameraLine() {
        XCTAssertEqual(PhotoDetails(make: "Apple", model: "iPhone Air").cameraLine, "Apple iPhone Air")
        XCTAssertEqual(PhotoDetails(make: "Canon", model: "Canon EOS R5").cameraLine, "Canon EOS R5")
        XCTAssertEqual(PhotoDetails(make: "Apple").cameraLine, "Apple")
        XCTAssertNil(PhotoDetails().cameraLine)
    }

    func test_exposureLine() {
        XCTAssertEqual(PhotoDetails(iso: 125).exposureLine, "ISO 125")
        XCTAssertEqual(PhotoDetails(fNumber: 1.6, exposureSeconds: 0.2, iso: 3200, focalLength: 6).exposureLine,
                       "f/1.6 · 1/5 s · ISO 3200 · 6 mm")
        XCTAssertNil(PhotoDetails().exposureLine)
    }

    func test_fileName_isThePathsLastComponent() {
        XCTAssertEqual(PhotoDetails.fileName("/data/pictures/beach.jpg"), "beach.jpg")
        XCTAssertEqual(PhotoDetails.fileName(#"C:\pics\beach.jpg"#), "beach.jpg")
        XCTAssertNil(PhotoDetails.fileName(""))
    }
}
