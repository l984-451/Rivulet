// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// The sidebar's Home glyph: a solid house with no chimney, as the Apple TV app draws its own
/// (`house.fill` has a chimney). Proportions measured from the TV app on tvOS 27, where the
/// glyph fills 25.75 x 26.25 of a 46 pt box and sits 0.875 pt above its centre.
enum SidebarHomeGlyph {
    static let name = "rivulet.home"

    /// An SF Symbol, or the Home glyph fitted to a `side`-point box.
    @MainActor static func icon(_ name: String, side: CGFloat) -> UIImage? {
        name == Self.name ? image(side: side) : UIImage(systemName: name)
    }

    @MainActor private static var cache: [CGFloat: UIImage] = [:]

    @MainActor static func image(side: CGFloat) -> UIImage {
        if let cached = cache[side] { return cached }
        let s = side / 46
        let w = 25.75 * s, h = 26.25 * s, shoulder = 9.4 * s, doorWidth = 7.0 * s, doorTop = 16.75 * s
        let r = 2.0 * s
        let x0 = (side - w) / 2, y0 = (side - h) / 2 - 0.875 * s
        // The outline inset by r, then stroked 2r with round joins: rounded corners at the measured size.
        let slope = shoulder / (w / 2), lift = r * (1 + slope * slope).squareRoot()
        let mid = w / 2
        let points: [CGPoint] = [
            CGPoint(x: mid, y: lift),
            CGPoint(x: w - r, y: shoulder + lift - r * slope),
            CGPoint(x: w - r, y: h - r),
            CGPoint(x: mid + doorWidth / 2 + r, y: h - r),
            CGPoint(x: mid + doorWidth / 2 + r, y: doorTop - r),
            CGPoint(x: mid - doorWidth / 2 - r, y: doorTop - r),
            CGPoint(x: mid - doorWidth / 2 - r, y: h - r),
            CGPoint(x: r, y: h - r),
            CGPoint(x: r, y: shoulder + lift - r * slope),
        ].map { CGPoint(x: x0 + $0.x, y: y0 + $0.y) }
        let path = UIBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach(path.addLine)
        path.close()
        path.lineWidth = 2 * r
        path.lineJoinStyle = .round
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor.black.setFill(); UIColor.black.setStroke()
            path.fill(); path.stroke()
        }.withRenderingMode(.alwaysTemplate)
        cache[side] = image
        return image
    }
}
