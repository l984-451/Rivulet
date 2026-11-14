// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreImage
import UIKit
import os

@MainActor
enum ArtworkScrim {
    private nonisolated static let context = CIContext(options: [.workingColorSpace: NSNull()])
    private nonisolated static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let workQueue = DispatchQueue(label: "rivulet.artwork-scrim", qos: .utility)
    // Identity keys avoid retaining artwork beyond the image cache's lifetime.
    private static let imageKeys = NSMapTable<UIImage, ImageKey>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private static let images: NSCache<ImageKey, UIImage> = {
        let cache = NSCache<ImageKey, UIImage>()
        cache.totalCostLimit = 24 << 20
        return cache
    }()

    private final class ImageKey: NSObject {
        let aspectRatio: CGFloat
        init(aspectRatio: CGFloat) { self.aspectRatio = aspectRatio }
    }

    static func cachedImage(for image: UIImage, aspectRatio: CGFloat) -> UIImage? {
        guard let key = imageKeys.object(forKey: image), key.aspectRatio == aspectRatio else { return nil }
        return images.object(forKey: key)
    }

    static func image(for image: UIImage, aspectRatio: CGFloat) async -> UIImage? {
        if let cached = cachedImage(for: image, aspectRatio: aspectRatio) { return cached }
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let rendered: UIImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workQueue.async {
                    guard !cancelled.withLock({ $0 }) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: render(image, color: analyze(image), aspectRatio: aspectRatio))
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        guard !Task.isCancelled, let rendered, let pixels = rendered.cgImage else { return nil }
        let key = ImageKey(aspectRatio: aspectRatio)
        imageKeys.setObject(key, forKey: image)
        images.setObject(rendered, forKey: key, cost: pixels.bytesPerRow * pixels.height)
        return rendered
    }

    nonisolated static func render(_ image: UIImage, color: UIColor?, aspectRatio: CGFloat) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0,
              aspectRatio.isFinite, aspectRatio > 0 else { return nil }
        let maxPixel = min(ImageQuality.thumb.maxPixelSize, max(image.size.width, image.size.height) * image.scale)
        let size = CGSize(width: min(maxPixel, maxPixel * aspectRatio).rounded(),
                          height: min(maxPixel, maxPixel / aspectRatio).rounded())
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let rect = CGRect(origin: .zero, size: size)
            image.draw(in: ContinueWatchingCardCompositor.aspectFill(image.size, in: rect))
            let context = renderer.cgContext
            let tint = color ?? .black
            let tintColors = [CGFloat(0), 0.05, 0.18, 0.35, 0.55, 0.72, 0.86, 0.9].map {
                tint.withAlphaComponent($0).cgColor
            }
            let darkeningColors = [CGFloat(0), 0.0256, 0.0832, 0.1664, 0.2688, 0.3712, 0.4736, 0.5568, 0.6144, 0.64].map {
                UIColor(white: 40 / 255, alpha: $0).cgColor
            }
            for (colors, locations) in [
                (tintColors, [CGFloat(0.66), 0.71, 0.77, 0.81, 0.85, 0.9, 0.94, 1]),
                (darkeningColors, [CGFloat(0.53), 0.59, 0.65, 0.7, 0.74, 0.79, 0.83, 0.87, 0.91, 1]),
            ] {
                if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
                    context.drawLinearGradient(gradient, start: .zero,
                                               end: CGPoint(x: 0, y: size.height), options: [])
                }
            }
        }
    }

    private nonisolated struct ColorBucket {
        var count = 0
        var sum = SIMD3<Double>.zero

        var mean: SIMD3<Double> { count > 0 ? sum / Double(count) : .zero }

        var score: Double {
            let color = mean
            let chroma = color.max() - color.min()
            let weight = min(1, 64 / max(1, chroma))
            let luminance = (color.x * 0.2126 + color.y * 0.7152 + color.z * 0.0722) / 255
            let highlightWeight = luminance > 0.97 ? 0.01 : 1
            return Double(count) * weight * weight * highlightWeight
        }
    }

    nonisolated static func analyze(_ image: UIImage) -> UIColor? {
        guard let input = CIImage(image: image), input.extent.width > 0, input.extent.height > 0 else { return nil }
        let width = 64
        let height = 36
        let sample = input
            .transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / input.extent.width,
                                              y: CGFloat(height) / input.extent.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(sample, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
        var buckets = Array(repeating: ColorBucket(), count: 512 + 64)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha >= 128 else { continue }
            let red = min(255, Int(pixels[offset]) * 255 / alpha)
            let green = min(255, Int(pixels[offset + 1]) * 255 / alpha)
            let blue = min(255, Int(pixels[offset + 2]) * 255 / alpha)
            let fineIndex = (red >> 5) * 64 + (green >> 5) * 8 + (blue >> 5)
            let coarseIndex = 512 + (red >> 6) * 16 + (green >> 6) * 4 + (blue >> 6)
            let color = SIMD3(Double(red), Double(green), Double(blue))
            for index in [fineIndex, coarseIndex] {
                buckets[index].count += 1
                buckets[index].sum += color
            }
        }
        guard let fine = representativeColor(buckets.prefix(512)),
              let coarse = representativeColor(buckets.suffix(64)) else { return nil }
        let color = (fine + coarse) / 2
        return UIColor(red: color.x / 255, green: color.y / 255, blue: color.z / 255, alpha: 1)
    }

    private nonisolated static func representativeColor(_ buckets: ArraySlice<ColorBucket>) -> SIMD3<Double>? {
        let strongest = buckets.filter { $0.count > 0 }
            .map { (mean: $0.mean, score: $0.score, count: $0.count) }
            .sorted { $0.score > $1.score }
            .prefix(3)
        guard let dominant = strongest.first else { return nil }
        let totalCount = buckets.reduce(0) { $0 + $1.count }
        guard dominant.count * 2 < totalCount else { return dominant.mean }
        let totalScore = strongest.reduce(0) { $0 + $1.score }
        let blended = strongest.reduce(SIMD3<Double>.zero) { $0 + $1.mean * $1.score } / totalScore
        return dominant.mean * 0.75 + blended * 0.25
    }
}
