// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

// Writes LaunchRiverArrivals.bin, the launch splash's arrival map: for each pixel of the R (at a quarter
// of the art's size), how far along the drawing line (`LaunchSplashStroke`) it is reached, so the splash
// uncovers the R behind the line's head. Run it again after changing LaunchSplashStroke.swift:
//
//   xcrun swiftc -O -o /tmp/launch-arrivals RivuletCore/Launch/LaunchSplashStroke.swift tools/launch-splash/main.swift
//   /tmp/launch-arrivals RivuletCore/Launch/LaunchRiverArrivals.bin
//
// Format: width and height as little-endian UInt16, then one byte per pixel, rows top-down. 0...254 is the
// fraction of the line's length at which the pixel is reached; 255 is reached by nothing (the sparkle around
// the ribbon, which fades in as the line finishes).
//
// A pixel goes to the nearest stretch of the line whose band (`widths`) reaches it, or to the fan, so a
// narrow stretch never claims ribbon that belongs to a wide one beside it. It is reached a little later the
// further it is from the line (`spread`), so the light widens out from the line as it passes. Where two
// stretches meet, their times jump; `smoothing` passes of averaging with the reached neighbours turn each
// jump into a short ramp, or the art there is uncovered with a hard edge a frame or two apart.

import CoreGraphics
import Foundation

let scaleDown: CGFloat = 4
let spread: CGFloat = 0.5
let smoothing = 3
let art = LaunchSplashStroke.artSize
let width = Int((art.width / scaleDown).rounded(.up)), height = Int((art.height / scaleDown).rounded(.up))
let (line, anchors) = LaunchSplashStroke.polyline(LaunchSplashStroke.line, in: art)
let (fan, _) = LaunchSplashStroke.polyline(LaunchSplashStroke.fan, in: art)
let fanStart = anchors[LaunchSplashStroke.fanFrom]

/// The nearest point to `p` on `poly`, among its stretch from length `from` to `to`: (distance, length along it).
func nearest(_ p: CGPoint, _ poly: LaunchSplashStroke.Polyline, from: CGFloat = 0,
             to: CGFloat = .greatestFiniteMagnitude) -> (CGFloat, CGFloat) {
    var best = (CGFloat.greatestFiniteMagnitude, CGFloat(0))
    let points = poly.points, lengths = poly.lengths
    for i in 0..<(points.count - 1) where lengths[i + 1] >= from && lengths[i] <= to {
        let a = points[i], b = points[i + 1]
        let abx = b.x - a.x, aby = b.y - a.y
        let span = abx * abx + aby * aby
        let t = span > 0 ? max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / span)) : 0
        let dx = a.x + abx * t - p.x, dy = a.y + aby * t - p.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < best.0 { best = (distance, lengths[i] + (lengths[i + 1] - lengths[i]) * t) }
    }
    return best
}

let widths = LaunchSplashStroke.widths
let stretches: [(from: CGFloat, to: CGFloat, reach: CGFloat)] = widths.indices.map { i in
    let to = i + 1 < widths.count ? widths[i + 1].from : anchors.count - 1
    return (anchors[widths[i].from], anchors[to], widths[i].width / 2)
}

var arrivals = [CGFloat?](repeating: nil, count: width * height)
for y in 0..<height {
    for x in 0..<width {
        let p = CGPoint(x: (CGFloat(x) + 0.5) * scaleDown, y: (CGFloat(y) + 0.5) * scaleDown)
        var best: (distance: CGFloat, arrival: CGFloat)?
        for stretch in stretches {
            let (distance, at) = nearest(p, line, from: stretch.from, to: stretch.to)
            if distance <= stretch.reach, distance < (best?.distance ?? .greatestFiniteMagnitude) { best = (distance, at) }
        }
        let (fanDistance, fanAt) = nearest(p, fan)
        if fanDistance <= LaunchSplashStroke.fanWidth / 2, fanDistance < (best?.distance ?? .greatestFiniteMagnitude) {
            best = (fanDistance, fanStart + fanAt)
        }
        guard let best else { continue }
        arrivals[y * width + x] = (best.arrival + best.distance * spread) / line.length
    }
}
for _ in 0..<smoothing {
    var smoothed = arrivals
    for y in 0..<height {
        for x in 0..<width where arrivals[y * width + x] != nil {
            var sum: CGFloat = 0, count: CGFloat = 0
            for ny in max(y - 1, 0)...min(y + 1, height - 1) {
                for nx in max(x - 1, 0)...min(x + 1, width - 1) {
                    if let value = arrivals[ny * width + nx] { sum += value; count += 1 }
                }
            }
            smoothed[y * width + x] = sum / count
        }
    }
    arrivals = smoothed
}
var bytes = [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8)]
for arrival in arrivals {
    bytes.append(arrival.map { UInt8(min(254, max(0, ($0 * 254).rounded()))) } ?? 255)
}
try Data(bytes).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Wrote \(width)x\(height) to \(CommandLine.arguments[1])")
