// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// An artwork's representative color, for the episode card's tinted fade. Apple's TV app gets
// this color from its server; Rivulet reads it once per image from a 16x9 sample, off the main thread.

import UIKit

@MainActor
enum ArtworkTint {
    private static let queue = DispatchQueue(label: "rivulet.artwork-tint", qos: .utility)
    private static let cache = NSCache<NSURL, UIColor>()

    static func cached(for url: URL) -> UIColor? { cache.object(forKey: url as NSURL) }

    static func color(for url: URL, image: UIImage) async -> UIColor? {
        if let hit = cached(for: url) { return hit }
        guard let cgImage = image.cgImage else { return nil }
        let color = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: sample(cgImage)) }
        }
        if let color { cache.setObject(color, forKey: url as NSURL) }
        return color
    }

    /// The most common color by coarse bucket, favoring saturated buckets over grays and near-white.
    nonisolated static func sample(_ image: CGImage) -> UIColor? {
        let (width, height) = (16, 9)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var counts = [Int](repeating: 0, count: 64)
        var sums = [SIMD3<Double>](repeating: .zero, count: 64)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = SIMD3(Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
            let index = (Int(pixels[offset]) >> 6) * 16 + (Int(pixels[offset + 1]) >> 6) * 4 + (Int(pixels[offset + 2]) >> 6)
            counts[index] += 1
            sums[index] += rgb
        }
        let best = counts.indices.filter { counts[$0] > 0 }.max { score(counts[$0], sums[$0]) < score(counts[$1], sums[$1]) }
        guard let best else { return nil }
        let mean = sums[best] / Double(counts[best])
        return UIColor(red: mean.x / 255, green: mean.y / 255, blue: mean.z / 255, alpha: 1)
    }

    private nonisolated static func score(_ count: Int, _ sum: SIMD3<Double>) -> Double {
        let mean = sum / Double(count)
        let chroma = mean.max() - mean.min()
        let luminance = (mean.x * 0.2126 + mean.y * 0.7152 + mean.z * 0.0722) / 255
        return Double(count) * (0.5 + chroma / 255) * (luminance > 0.95 ? 0.05 : 1)
    }
}
