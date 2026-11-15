// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingCardCompositor.swift
//  Rivulet
//
//  The Apple TV app's Up Next card shows ONE server-made image: the 16:9 still
//  on top, a mirrored, blurred continuation of it in the 48 pt below, under a
//  black gradient. This builds the same image locally, once per still.
//

import CoreGraphics
import CoreImage

nonisolated enum ContinueWatchingCardCompositor {

    /// Height of the mirrored band under the still.
    static let bandHeight: CGFloat = 48
    /// Inset of the title and the status row from the card's edges.
    static let padding: CGFloat = 14

    /// The card edge a title sits on: the artwork's physical left or right.
    enum Side: Sendable {
        case leading, trailing
    }

    // MARK: - Geometry

    /// Every region of the card, in points, top-left origin, from its width.
    struct Geometry: Equatable {
        let card: CGSize
        /// The still: 16:9 at the top.
        let still: CGRect
        /// The band under it.
        let band: CGRect
        /// The blur fades in from this y to full strength at the seam.
        let blurStart: CGFloat
        let blurRadius: CGFloat
        /// Black gradient over the whole card, top to bottom.
        let gradientLocations: [CGFloat]
        let gradientAlphas: [CGFloat]
        /// Largest box the title logo may fill on the leading edge, centred on the still.
        let titleBox: CGRect
        /// The title's lowest bottom edge: the blur ramp's start, clear of the status row.
        let titleFloor: CGFloat

        /// `cardHeight` is for a card whose art fills the whole card (iOS, Mac); the band is only kept clear.
        init(cardWidth width: CGFloat, cardHeight fullBleed: CGFloat? = nil) {
            let bandHeight = ContinueWatchingCardCompositor.bandHeight
            let height = fullBleed ?? ContinueWatchingCardCompositor.height(forWidth: width)
            let stillHeight = height - bandHeight
            titleFloor = stillHeight - 16
            card = CGSize(width: width, height: height)
            still = CGRect(x: 0, y: 0, width: width, height: fullBleed == nil ? stillHeight : height)
            band = CGRect(x: 0, y: stillHeight, width: width, height: bandHeight)
            blurStart = stillHeight - 16
            blurRadius = 8
            // Measured off Apple's served image: clear to the middle, 7% at the seam.
            gradientLocations = [0, 0.5, (stillHeight - 35) / height, stillHeight / height, 1]
            gradientAlphas = [0, 0, 0.03, 0.07, 0.19]
            let titleSize = CGSize(width: (width * 0.4625).rounded(), height: (stillHeight * 0.5333).rounded())
            titleBox = CGRect(x: ContinueWatchingCardCompositor.padding,
                              y: ((stillHeight - titleSize.height) / 2).rounded(),
                              width: titleSize.width, height: titleSize.height)
        }

        /// Vertical shifts of the title box, nearest first, that keep a title
        /// `height` tall, centred in it, between the top padding and the floor.
        func titleOffsets(forHeight height: CGFloat, step: CGFloat = 8) -> [CGFloat] {
            let top = titleBox.midY - height / 2
            let up = min(0, (ContinueWatchingCardCompositor.padding - top).rounded(.up))
            let down = max(0, (titleFloor - top - height).rounded(.down))
            var offsets: [CGFloat] = [0]
            for shift in stride(from: step, to: max(-up, down), by: step) {
                if -shift > up { offsets.append(-shift) }
                if shift < down { offsets.append(shift) }
            }
            if up < 0 { offsets.append(up) }
            if down > 0 { offsets.append(down) }
            return offsets
        }

        /// What a title covers at rest, leading and centred: the fitted logo,
        /// else the fallback title's line, else the whole box.
        func titleFootprint(logoSize: CGSize?, textSize: CGSize? = nil) -> CGRect {
            logoSize.map { ContinueWatchingCardCompositor.aspectFitLeading($0, in: titleBox) }
                ?? textSize.map {
                    CGRect(x: titleBox.minX, y: titleBox.midY - $0.height / 2,
                           width: min($0.width, card.width - 2 * titleBox.minX), height: $0.height)
                } ?? titleBox
        }

        /// A resting footprint shifted down by `offset` and scaled about its
        /// edge on `side`. The trailing side mirrors the leading one.
        func titleRect(_ footprint: CGRect, side: Side, offset: CGFloat = 0, scale: CGFloat = 1) -> CGRect {
            let size = CGSize(width: footprint.width * scale, height: footprint.height * scale)
            return CGRect(x: side == .leading ? footprint.minX : card.width - footprint.minX - size.width,
                          y: footprint.midY - size.height / 2 + offset, width: size.width, height: size.height)
        }
    }

    /// Apple's rule: a 16:9 still plus the band.
    static func height(forWidth width: CGFloat) -> CGFloat {
        (width / 1.7778 + bandHeight).rounded()
    }

    /// `size` scaled to cover `rect`, centred on it.
    static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// `size` scaled to fit `rect`, on its leading edge, centred vertically.
    static func aspectFitLeading(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.minX, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    // MARK: - Render

    static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

    static func bitmap(width: Int, height: Int, alpha: CGImageAlphaInfo = .noneSkipLast) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: alpha.rawValue)
    }

    /// The card's opaque bitmap at `scale` pixels per point. Call off the main thread.
    static func render(still: CGImage, geometry: Geometry, scale: CGFloat) -> CGImage? {
        let width = Int((geometry.card.width * scale).rounded())
        let height = Int((geometry.card.height * scale).rounded())
        guard let base = bitmap(width: width, height: height) else { return nil }

        // Points with a top-left origin, like the geometry.
        base.translateBy(x: 0, y: CGFloat(height))
        base.scaleBy(x: scale, y: -scale)
        base.interpolationQuality = .high

        let rect = aspectFill(CGSize(width: still.width, height: still.height), in: geometry.still)
        let drawStill = {
            base.saveGState()
            base.clip(to: geometry.still)
            base.translateBy(x: rect.minX, y: rect.maxY)
            base.scaleBy(x: 1, y: -1)
            base.draw(still, in: CGRect(origin: .zero, size: rect.size))
            base.restoreGState()
        }
        drawStill()
        // The band is the still reflected about the seam.
        base.saveGState()
        base.clip(to: geometry.band)
        base.translateBy(x: 0, y: 2 * geometry.still.maxY)
        base.scaleBy(x: 1, y: -1)
        drawStill()
        base.restoreGState()

        let colors = geometry.gradientAlphas.map { CGColor(red: 0, green: 0, blue: 0, alpha: $0) } as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: geometry.gradientLocations) {
            base.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: geometry.card.height), options: [])
        }
        guard let sharp = base.makeImage() else { return nil }

        // The blurred copy fades in from nothing above the seam to all of it
        // below, so the reflection never shows an edge. Core Image's origin is
        // bottom-left.
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: (geometry.card.height - geometry.blurStart) * scale),
            "inputColor0": CIColor.black,
            "inputPoint1": CIVector(x: 0, y: geometry.band.height * scale),
            "inputColor1": CIColor.white
        ])?.outputImage
        guard let mask, let out = bitmap(width: width, height: height), let data = out.data else { return sharp }
        let source = CIImage(cgImage: sharp)
        let blurred = source.clampedToExtent()
            .applyingGaussianBlur(sigma: geometry.blurRadius * scale)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: source,
                kCIInputMaskImageKey: mask
            ])
        ciContext.render(blurred, toBitmap: data, rowBytes: out.bytesPerRow, bounds: extent,
                         format: .RGBA8, colorSpace: colorSpace)
        return out.makeImage()
    }

    /// Room around the title box for the logo's shadow.
    static let titleShadowPad: CGFloat = 6

    /// The logo fitted into the title box at display size, with a soft shadow
    /// drawn in: our logos are not art-directed for the still they sit on. The
    /// bitmap covers the box plus `titleShadowPad` on every side.
    /// `strongShadow` is for a logo over a bright or busy part of the still.
    static func renderTitle(logo: CGImage, geometry: Geometry, scale: CGFloat,
                            strongShadow: Bool = false) -> CGImage? {
        let pad = titleShadowPad
        let box = CGRect(origin: CGPoint(x: pad, y: pad), size: geometry.titleBox.size)
        let width = Int(((box.width + 2 * pad) * scale).rounded())
        let height = Int(((box.height + 2 * pad) * scale).rounded())
        guard let context = bitmap(width: width, height: height, alpha: .premultipliedLast) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        context.setShadow(offset: CGSize(width: 0, height: -scale), blur: (strongShadow ? 5 : 3) * scale,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: strongShadow ? 0.6 : 0.35))
        context.draw(logo, in: aspectFitLeading(CGSize(width: logo.width, height: logo.height), in: box))
        return context.makeImage()
    }
}
