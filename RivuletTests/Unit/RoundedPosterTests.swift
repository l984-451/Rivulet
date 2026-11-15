// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// #581: posters carry the Apple TV app's 20 pt corner in the image itself.
@MainActor
final class RoundedPosterTests: XCTestCase {
    private func alpha(_ image: UIImage, x: Int, y: Int) -> UInt8 {
        let cg = image.cgImage!
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        return pixel[3]
    }

    func test_render_fillsHostSizeWithClearCorners() {
        let tile = MediaRowMetrics.poster
        let shape = RoundedPoster.Shape(tile: tile, scale: 2)
        // A wide source must be cropped to fill, not letterboxed.
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 100)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        }.cgImage!
        let image = RoundedPoster.render(source, shape: shape)
        XCTAssertEqual(image.size, tile.hostSize)

        let w = image.cgImage!.width, h = image.cgImage!.height
        XCTAssertEqual(alpha(image, x: 0, y: 0), 0, "top-left corner is cut")
        XCTAssertEqual(alpha(image, x: w - 1, y: h - 1), 0, "bottom-right corner is cut")
        XCTAssertEqual(alpha(image, x: w / 2, y: 0), 255, "top edge is filled")
        XCTAssertEqual(alpha(image, x: 0, y: h / 2), 255, "side edge is filled")
        // 4 pt in from both edges is cut by a ~21 pt corner but not by tvOS 26's ~6 pt one.
        XCTAssertEqual(alpha(image, x: 4 * 2, y: 4 * 2), 0, "corner is ~20 pt, not the system's")
        XCTAssertEqual(alpha(image, x: 40 * 2, y: 40 * 2), 255)
    }
}
