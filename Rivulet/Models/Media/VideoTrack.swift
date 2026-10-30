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
    var bitDepth: Int? = nil
    var pixelFormat: String? = nil
    var aspectRatio: String? = nil
    var colorPrimaries: String? = nil
    var colorTransfer: String? = nil
    var colorSpace: String? = nil
    var colorRange: String? = nil
    var dolbyVisionLevel: Int? = nil
    var dolbyVisionCompatibilityID: Int? = nil
    var dolbyVisionEnhancementLayer: String? = nil
    var compatibleRangeLabel: String? = nil

    var isInterlaced: Bool { scanType?.lowercased() == "interlaced" }

    enum VideoRange: Hashable, Sendable {
        case sdr
        case unknown
        case hdr                         // HDR known, exact format unknown
        case hdr10
        case hdr10Plus
        case hlg
        case dolbyVision(profile: Int)   // P5=5, P7=7, P8=8
    }
}
