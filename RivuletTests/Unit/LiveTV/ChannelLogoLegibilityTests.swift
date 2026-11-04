// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import UIKit
@testable import Rivulet

final class ChannelLogoLegibilityTests: XCTestCase {

    /// A 100x100 image with `rects` filled on a transparent background.
    private func logo(_ rects: [(CGRect, UIColor)]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            for (rect, color) in rects {
                color.setFill()
                context.fill(rect)
            }
        }
    }

    private let mark = CGRect(x: 20, y: 20, width: 60, height: 60)
    private let whole = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func isDark(_ rects: [(CGRect, UIColor)]) -> Bool {
        UIImage.isDarkLogo(logo(rects).cgImage!)
    }

    /// Draws `image` on black and reads the centre pixel.
    private func centreRed(of image: UIImage) -> CGFloat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(drawn.cgImage!, in: CGRect(x: -50, y: -50, width: 100, height: 100))
        return CGFloat(pixel[0]) / 255
    }

    func test_blackMark_isDark() {
        XCTAssertTrue(isDark([(mark, .black)]))
    }

    func test_lightAndColoredMarks_areNot() {
        XCTAssertFalse(isDark([(mark, .white)]))
        XCTAssertFalse(isDark([(mark, .red)]))
    }

    func test_blackMarkWithLightPart_isNot() {
        XCTAssertFalse(isDark([(mark, .black), (CGRect(x: 20, y: 20, width: 60, height: 20), .white)]))
    }

    func test_opaqueImage_bringsItsOwnBackground() {
        XCTAssertFalse(isDark([(whole, .black)]))
    }

    func test_emptyImage_isNot() {
        XCTAssertFalse(isDark([]))
    }

    func test_legibleChannelLogo_whitensOnlyDarkMarks() {
        XCTAssertEqual(centreRed(of: logo([(mark, .black)]).legibleChannelLogo), 1, accuracy: 0.01)
        let red = logo([(mark, .red)])
        XCTAssertTrue(red.legibleChannelLogo === red)
    }
}
