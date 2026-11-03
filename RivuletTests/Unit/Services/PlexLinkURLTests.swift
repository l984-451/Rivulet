// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The plex.tv/link URL the sign-in card shows as a QR code and iOS opens.

import CoreImage
import XCTest
@testable import Rivulet

final class PlexLinkURLTests: XCTestCase {

    /// The link page with the PIN filled in: the URL Plex's own PIN QR image encodes.
    func testLinkURLOpensTheLinkPageWithThePinFilledIn() {
        XCTAssertEqual(PlexAuthManager.linkURL(code: "4QVF").absoluteString,
                       "https://www.plex.tv/link/?pin=4QVF")
    }

    func testLinkURLEscapesTheCode() {
        XCTAssertEqual(PlexAuthManager.linkURL(code: "A&B").absoluteString,
                       "https://www.plex.tv/link/?pin=A%26B")
    }

    /// The tile's QR decodes back to the link URL.
    func testQRCodeCarriesTheLinkURL() throws {
        let url = PlexAuthManager.linkURL(code: "4QVF").absoluteString
        let image = try XCTUnwrap(QRCodeImage.make(url, side: 200, scale: 1))
        XCTAssertLessThanOrEqual(image.size.width, 200)
        XCTAssertEqual(image.size.width, image.size.height)

        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: try XCTUnwrap(image.cgImage)))
        XCTAssertEqual((features.first as? CIQRCodeFeature)?.messageString, url)
    }
}
