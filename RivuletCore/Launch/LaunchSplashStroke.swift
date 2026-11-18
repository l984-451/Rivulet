// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import CoreGraphics

/// The line that draws the launch splash's R: one centre line along the ribbon of `LaunchRiver`,
/// from the top stroke's left tip round the bowl, through the middle and out the tail, plus the strands
/// that fan down-left once the line passes the middle.
///
/// The splash moves the line's head along it, and uncovers the art by `LaunchRiverArrivals.bin`: how far
/// along the line each part of the R is reached. `tools/launch-splash` writes that map from this file,
/// so a change here means running it again.
enum LaunchSplashStroke {
    /// The points are traced on the 772x658 art, top-left origin.
    static let artSize = CGSize(width: 772, height: 658)

    static let line: [CGPoint] = [
        CGPoint(x: 135, y: 32), CGPoint(x: 330, y: 36), CGPoint(x: 515, y: 50), CGPoint(x: 592, y: 92),
        CGPoint(x: 596, y: 142), CGPoint(x: 545, y: 182), CGPoint(x: 430, y: 210), CGPoint(x: 335, y: 245),
        CGPoint(x: 290, y: 305), CGPoint(x: 295, y: 372), CGPoint(x: 340, y: 432), CGPoint(x: 425, y: 482),
        CGPoint(x: 550, y: 532), CGPoint(x: 670, y: 572), CGPoint(x: 772, y: 602),
    ]
    /// How wide the ribbon is along `line`, in art px, from the point each width starts at: the map
    /// gives each stretch the art within half its width.
    static let widths: [(from: Int, width: CGFloat)] = [(0, 140), (3, 150), (7, 400), (10, 250)]
    /// The down-left fan, reached once the line passes point `fanFrom`.
    static let fan: [CGPoint] = [
        CGPoint(x: 300, y: 250), CGPoint(x: 210, y: 320), CGPoint(x: 130, y: 400), CGPoint(x: 50, y: 470),
    ]
    static let fanFrom = 7
    static let fanWidth: CGFloat = 190

    /// A dense polyline with its length so far at each point, so a point along it is a plain distance.
    struct Polyline {
        private(set) var points: [CGPoint] = []
        private(set) var lengths: [CGFloat] = []
        var length: CGFloat { lengths.last ?? 0 }

        mutating func append(_ point: CGPoint) {
            let step = points.last.map { hypot(point.x - $0.x, point.y - $0.y) } ?? 0
            points.append(point)
            lengths.append((lengths.last ?? 0) + step)
        }

        func point(at distance: CGFloat) -> CGPoint {
            guard let first = points.first else { return .zero }
            guard distance > 0 else { return first }
            guard distance < length else { return points[points.count - 1] }
            var low = 0, high = lengths.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if lengths[mid] < distance { low = mid } else { high = mid }
            }
            let span = lengths[high] - lengths[low]
            let fraction = span > 0 ? (distance - lengths[low]) / span : 0
            return CGPoint(x: points[low].x + (points[high].x - points[low].x) * fraction,
                           y: points[low].y + (points[high].y - points[low].y) * fraction)
        }

        func path() -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points)
            return path
        }
    }

    /// `points` (art px) as a smooth Catmull-Rom curve, scaled into `size`, sampled densely. `anchors`
    /// gives the distance along it at which each of `points` lands.
    static func polyline(_ points: [CGPoint], in size: CGSize) -> (Polyline, anchors: [CGFloat]) {
        let p = points.map { CGPoint(x: $0.x / artSize.width * size.width, y: $0.y / artSize.height * size.height) }
        var line = Polyline()
        var anchors: [CGFloat] = [0]
        line.append(p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            for step in 1...20 {
                let t = CGFloat(step) / 20, u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                line.append(CGPoint(x: a * p1.x + b * c1.x + c * c2.x + d * p2.x,
                                    y: a * p1.y + b * c1.y + c * c2.y + d * p2.y))
            }
            anchors.append(line.length)
        }
        return (line, anchors)
    }
}
