// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class RoundedPosterTests: XCTestCase {
    private func pixel(_ image: UIImage, x: Int, y: Int) -> [UInt8] {
        let cg = image.cgImage!
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        return pixel
    }

    func test_render_fillsHostSizeWithOpaqueArtwork() {
        let tile = MediaRowMetrics.poster
        let shape = RoundedPoster.Shape(tile: tile, scale: 2)
        // A wide source must be cropped to fill, not letterboxed.
        let format = UIGraphicsImageRendererFormat.layeredArtwork(scale: 1)
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 100), format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        }.cgImage!
        let image = RoundedPoster.render(source, shape: shape)
        XCTAssertEqual(image.size, tile.hostSize)

        let w = image.cgImage!.width, h = image.cgImage!.height
        XCTAssertEqual(pixel(image, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, x: w - 1, y: h - 1), [255, 0, 0, 255])
    }

    func test_render_preservesSourceTransparency() {
        let tile = MediaRowMetrics.poster
        let source = UIGraphicsImageRenderer(size: tile.art, format: .layeredArtwork(scale: 1)).image { context in
            UIColor.red.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: tile.art.width / 2, y: 0, width: tile.art.width / 2, height: tile.art.height))
        }.cgImage!
        let image = RoundedPoster.render(source, shape: .init(tile: tile, scale: 2))
        let cg = image.cgImage!
        let background = pixel(image, x: cg.width / 4, y: cg.height / 2)
        XCTAssertEqual(background[3], 0)
        let blended = pixel(image, x: cg.width * 3 / 4, y: cg.height / 2)
        XCTAssertEqual(Double(blended[3]), 128, accuracy: 2)
    }

    /// A poster with transparency must be 8 bits a channel. A wide-colour Apple TV renders 16-bit
    /// float by default, and TVPosterView's shadow check reads past the end of such an image
    /// (SIGSEGV in vImage, 1.3.1). The simulator's default is 8-bit, so this pins the format.
    func test_layeredArtwork_isStandardRange() {
        XCTAssertEqual(UIGraphicsImageRendererFormat.layeredArtwork(scale: 2).preferredRange, .standard)
        XCTAssertEqual(UIGraphicsImageRendererFormat.layeredArtwork().scale, UIGraphicsImageRendererFormat.preferred().scale)

        let source = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90)).image { _ in }.cgImage!
        let shape = RoundedPoster.Shape(tile: MediaRowMetrics.poster, scale: 2)
        for image in [RoundedPoster.render(source, shape: shape), PosterCell.blankArtwork, MusicChrome.placeholder()] {
            XCTAssertEqual(image.cgImage?.bitsPerComponent, 8)
            XCTAssertEqual(image.cgImage?.bitsPerPixel, 32)
        }
    }
}
