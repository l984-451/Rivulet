// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Subtitle Brightness, layered on top of the system caption style
// (CaptionAppearance). It dims the text colour, not its opacity, for plain,
// libass and picture captions.

import CoreGraphics
import Foundation

nonisolated enum SubtitleAppearance {

    /// Double in 0.4...1.0; absent = 1.0.
    static let brightnessKey = "subtitleBrightness"

    /// Posts the caption-change notification, so every caption surface that
    /// already restyles on a system caption change picks the setting up.
    static func notifyChanged() {
        NotificationCenter.default.post(name: CaptionAppearance.changedNotification, object: nil)
    }

    // MARK: Brightness

    static let minimumBrightness = 0.4
    static let brightnessOptions: [Double] = [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4]

    static func clampBrightness(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, minimumBrightness), 1)
    }

    static var brightness: Double {
        get {
            guard let stored = UserDefaults.standard.object(forKey: brightnessKey) as? Double else { return 1 }
            return clampBrightness(stored)
        }
        set {
            UserDefaults.standard.set(clampBrightness(newValue), forKey: brightnessKey)
            notifyChanged()
        }
    }

    /// The option after `current`, wrapping 40% back to 100% (the Settings row).
    static func nextBrightness(after current: Double) -> Double {
        let index = brightnessOptions.firstIndex { abs($0 - current) < 0.001 } ?? 0
        return brightnessOptions[(index + 1) % brightnessOptions.count]
    }

    /// The player's stepper: Right (+1) is 10% brighter, Left (-1) 10% dimmer,
    /// stopping at 100% and 40%.
    static func steppedBrightness(_ current: Double, by step: Int) -> Double {
        let index = brightnessOptions.firstIndex { abs($0 - current) < 0.001 }
            ?? brightnessOptions.indices.min { abs(brightnessOptions[$0] - current) < abs(brightnessOptions[$1] - current) }
            ?? 0
        // The options run 100% down to 40%, so brighter is a lower index.
        let next = min(max(index - step, 0), brightnessOptions.count - 1)
        return brightnessOptions[next]
    }

    static func brightnessLabel(_ value: Double) -> String {
        "\(Int((clampBrightness(value) * 100).rounded()))%"
    }

    /// Multiplies a colour's RGB by `factor` and keeps its alpha: white at 0.4
    /// becomes opaque 40% grey, not 40%-transparent white.
    static func dim(_ color: CGColor, by factor: Double) -> CGColor {
        let f = CGFloat(clampBrightness(factor))
        guard f < 1 else { return color }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let rgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 4
        else { return color }
        return CGColor(srgbRed: c[0] * f, green: c[1] * f, blue: c[2] * f, alpha: c[3])
    }

    /// Picture subtitles (PGS, VobSub): the same RGB scaling, applied to the drawn pixels only
    /// (black over them with source-atop), alpha unchanged. nil if drawing fails.
    static func dimmedImage(_ image: CGImage, by factor: Double) -> CGImage? {
        let f = clampBrightness(factor)
        guard f < 1,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: rect)
        ctx.setBlendMode(.sourceAtop)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1 - f))
        ctx.fill(rect)
        return ctx.makeImage()
    }

    /// Same as `dim` for a libass `0xRRGGBBTT` colour (TT is transparency, kept).
    static func dimASSColor(_ color: UInt32, by factor: Double) -> UInt32 {
        let f = clampBrightness(factor)
        guard f < 1 else { return color }
        func scale(_ shift: UInt32) -> UInt32 {
            UInt32((Double((color >> shift) & 0xFF) * f).rounded()) << shift
        }
        return scale(24) | scale(16) | scale(8) | (color & 0xFF)
    }
}
