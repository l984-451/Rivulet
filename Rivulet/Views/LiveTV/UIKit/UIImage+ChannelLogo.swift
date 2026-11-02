// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

extension UIImage {
    /// The logo to draw on a dark surface: a dark mark turns white, as it would vanish otherwise.
    var legibleChannelLogo: UIImage {
        guard let cgImage, Self.isDarkLogo(cgImage) else { return self }
        return withTintColor(.white, renderingMode: .alwaysOriginal)
    }

    /// A dark mark on a transparent background. An opaque image brings its own background, so it is left out.
    nonisolated static func isDarkLogo(_ source: CGImage) -> Bool {
        let (width, height) = (24, 18)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }

        var luminance = 0.0, alpha = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            luminance += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
            alpha += Double(pixels[i + 3])
        }
        return alpha > 0 && alpha < 0.98 * Double(width * height) * 255 && luminance / alpha < 0.2
    }
}
