// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ASSCompositor.swift
//  Rivulet
//
//  Flattens libass's output into at most four images. libass hands back a
//  back-to-front list of 8-bit alpha masks, each with a single colour
//  `0xRRGGBBTT` where TT is TRANSPARENCY (opacity = 255 - TT), placed in frame
//  pixels. Nearby masks are grouped into regions, and each region is blended
//  source-over into its own premultiplied BGRA buffer, so a top sign and the
//  bottom dialogue never share one screen-sized buffer.
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

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    static let maxRegions = 4
    /// Masks closer than this (frame pixels) share a region.
    static let regionGap: CGFloat = 32

    /// Each region's image and rect in frame pixels; empty when nothing is visible.
    /// `brightness` (Subtitle Brightness, 0.4...1) scales each mask's RGB before
    /// blending. Source-over is linear in colour, so this is exactly the composited
    /// pixels' RGB times `brightness` with alpha unchanged, at no per-pixel cost.
    static func composite(_ bitmaps: [Bitmap], brightness: Double = 1) -> [(image: CGImage, rect: CGRect)] {
        let visible = bitmaps.filter { $0.width > 0 && $0.height > 0 && ($0.color & 0xFF) != 0xFF }
        return regions(visible.map(\.rect)).compactMap { region in
            blend(region.members.map { visible[$0] }, in: region.rect, brightness: brightness)
        }
    }

    /// Groups rects into at most `maxRegions` disjoint regions covering all of
    /// them. Members stay in input order, which is libass's paint order.
    static func regions(_ rects: [CGRect], maxRegions: Int = maxRegions,
                        gap: CGFloat = regionGap) -> [(rect: CGRect, members: [Int])] {
        func near(_ a: CGRect, _ b: CGRect) -> Bool { a.insetBy(dx: -gap, dy: -gap).intersects(b) }
        var groups: [(rect: CGRect, members: [Int])] = []
        for (index, rect) in rects.enumerated() {
            if let g = groups.firstIndex(where: { near($0.rect, rect) }) {
                groups[g].rect = groups[g].rect.union(rect)
                groups[g].members.append(index)
            } else {
                groups.append((rect, [index]))
            }
        }
        // A grown union can reach a neighbour; merge those, then the cheapest
        // pairs until the count fits.
        // ponytail: O(groups^2) per merge; fine for the handful libass yields, revisit for karaoke-heavy frames.
        while groups.count > 1 {
            var pick: (a: Int, b: Int)?
            var cheapest = CGFloat.infinity
            search: for a in groups.indices {
                for b in groups.indices where b > a {
                    if near(groups[a].rect, groups[b].rect) { pick = (a, b); break search }
                    guard groups.count > maxRegions else { continue }
                    let union = groups[a].rect.union(groups[b].rect)
                    let cost = area(union) - area(groups[a].rect) - area(groups[b].rect)
                    if cost < cheapest { cheapest = cost; pick = (a, b) }
                }
            }
            guard let (a, b) = pick else { break }
            groups[a].rect = groups[a].rect.union(groups[b].rect)
            groups[a].members = (groups[a].members + groups[b].members).sorted()
            groups.remove(at: b)
        }
        return groups
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private static func blend(_ bitmaps: [Bitmap], in rect: CGRect, brightness: Double) -> (image: CGImage, rect: CGRect)? {
        let minX = Int(rect.minX), minY = Int(rect.minY)
        let width = Int(rect.width), height = Int(rect.height)
        let size = width * height * 4
        // calloc: large blocks arrive as zeroed pages, no fill pass.
        guard size > 0, let raw = calloc(size, 1) else { return nil }
        let dst = raw.bindMemory(to: UInt8.self, capacity: size)

        // ponytail: scalar blend; move to vImage or Accelerate if a dense sign frame is over budget on device.
        for b in bitmaps {
            let color = SubtitleAppearance.dimASSColor(b.color, by: brightness)
            let red = color >> 24
            let green = (color >> 16) & 0xFF
            let blue = (color >> 8) & 0xFF
            let opacity = 255 - (color & 0xFF)
            for row in 0..<b.height {
                let src = b.pixels + row * b.stride
                var o = ((b.y - minY + row) * width + (b.x - minX)) * 4
                for col in 0..<b.width {
                    let a = UInt32(src[col]) * opacity / 255
                    if a != 0 {
                        if dst[o + 3] == 0 {
                            // Nothing under it yet: a plain premultiplied copy.
                            dst[o] = UInt8(blue * a / 255)
                            dst[o + 1] = UInt8(green * a / 255)
                            dst[o + 2] = UInt8(red * a / 255)
                            dst[o + 3] = UInt8(a)
                        } else {
                            // Premultiplied source-over. Each channel stays <= 255
                            // because c * a + d * (255 - a) <= 255 * 255.
                            let inverse = 255 - a
                            dst[o] = UInt8((blue * a + UInt32(dst[o]) * inverse) / 255)
                            dst[o + 1] = UInt8((green * a + UInt32(dst[o + 1]) * inverse) / 255)
                            dst[o + 2] = UInt8((red * a + UInt32(dst[o + 2]) * inverse) / 255)
                            dst[o + 3] = UInt8((255 * a + UInt32(dst[o + 3]) * inverse) / 255)
                        }
                    }
                    o += 4
                }
            }
        }

        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        // The provider owns the buffer and frees it with the image.
        guard let provider = CGDataProvider(dataInfo: nil, data: raw, size: size,
                                            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) })
        else {
            free(raw)
            return nil
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (image, rect)
    }
}
