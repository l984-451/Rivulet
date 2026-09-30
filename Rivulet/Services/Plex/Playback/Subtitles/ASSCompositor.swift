// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ASSCompositor.swift
//  Rivulet
//
//  Flattens libass's output into one image. libass hands back a back-to-front
//  list of 8-bit alpha masks, each with a single colour `0xRRGGBBTT` where TT
//  is TRANSPARENCY (opacity = 255 - TT), placed in frame pixels. Blended
//  source-over into one premultiplied BGRA buffer covering their union.
//

import CoreGraphics
import Foundation

nonisolated enum ASSCompositor {

    struct Bitmap {
        let width: Int
        let height: Int
        let stride: Int
        let pixels: UnsafePointer<UInt8>
        let color: UInt32
        let x: Int
        let y: Int
    }

    /// The union of `bitmaps` as one image plus its rect in frame pixels, or
    /// nil when nothing is visible.
    static func composite(_ bitmaps: [Bitmap]) -> (image: CGImage, rect: CGRect)? {
        let visible = bitmaps.filter { $0.width > 0 && $0.height > 0 && ($0.color & 0xFF) != 0xFF }
        guard let first = visible.first else { return nil }

        var minX = first.x, minY = first.y
        var maxX = first.x + first.width, maxY = first.y + first.height
        for b in visible.dropFirst() {
            minX = min(minX, b.x); minY = min(minY, b.y)
            maxX = max(maxX, b.x + b.width); maxY = max(maxY, b.y + b.height)
        }
        let width = maxX - minX, height = maxY - minY
        var buffer = [UInt8](repeating: 0, count: width * height * 4)

        // ponytail: scalar blend; move to vImage or Accelerate if Task 8 shows a dense sign frame over budget.
        buffer.withUnsafeMutableBufferPointer { dst in
            for b in visible {
                let red = b.color >> 24
                let green = (b.color >> 16) & 0xFF
                let blue = (b.color >> 8) & 0xFF
                let opacity = 255 - (b.color & 0xFF)
                for row in 0..<b.height {
                    let src = b.pixels + row * b.stride
                    var o = ((b.y - minY + row) * width + (b.x - minX)) * 4
                    for col in 0..<b.width {
                        let a = UInt32(src[col]) * opacity / 255
                        if a != 0 {
                            // Premultiplied source-over. Each channel stays <= 255
                            // because c * a + d * (255 - a) <= 255 * 255.
                            let inverse = 255 - a
                            dst[o] = UInt8((blue * a + UInt32(dst[o]) * inverse) / 255)
                            dst[o + 1] = UInt8((green * a + UInt32(dst[o + 1]) * inverse) / 255)
                            dst[o + 2] = UInt8((red * a + UInt32(dst[o + 2]) * inverse) / 255)
                            dst[o + 3] = UInt8((255 * a + UInt32(dst[o + 3]) * inverse) / 255)
                        }
                        o += 4
                    }
                }
            }
        }

        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(buffer) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (image, CGRect(x: minX, y: minY, width: width, height: height))
    }
}
