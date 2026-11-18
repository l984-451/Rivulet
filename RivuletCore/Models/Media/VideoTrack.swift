// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VideoTrack.swift
//  Rivulet
//
//  Per-video-stream metadata for the source picker and player UI.
//

import Foundation

struct VideoTrack: Hashable, Sendable, Identifiable {
    let id: String                 // provider-native stream id
    let codec: String              // "hevc", "h264", "av1", "vp9"
    let profile: String?           // "Main 10", "High", etc.
    let level: Int?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let bitrate: Int?
    let videoRange: VideoRange
    let isDefault: Bool
    let scanType: String?           // Plex "progressive" / "interlaced"; nil if unknown
    /// HDR10+ dynamic metadata alongside the range, e.g. a Dolby Vision file that also carries HDR10+.
    var hasHDR10Plus = false
    /// The picture's shape as shown: width over height, corrected for non-square pixels. Nil when unknown.
    var aspectRatio: Double? = nil

    var isInterlaced: Bool { scanType?.lowercased() == "interlaced" }

    enum VideoRange: Hashable, Sendable {
        case sdr
        case hdr10
        case hdr10Plus
        case hlg
        case dolbyVision(profile: Int)   // P5=5, P7=7, P8=8
    }
}

extension VideoTrack {
    /// Width over height, scaled by the pixel aspect ("40:33") when the pixels aren't square.
    static func aspectRatio(width: Int?, height: Int?, pixelAspect: String? = nil) -> Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height) * (ratio(pixelAspect) ?? 1)
    }

    /// "16:9", "2.40:1" or "40:33" as a number.
    static func ratio(_ text: String?) -> Double? {
        let parts = (text ?? "").split(separator: ":")
        guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), a > 0, b > 0 else { return nil }
        return a / b
    }
}
