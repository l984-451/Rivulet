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
    let scanType: String?          // Plex "progressive" / "interlaced"; nil if unknown

    /// True when the source is interlaced (1080i/576i/480i). Plex reports the
    /// scan type per video stream; when it's absent we assume progressive (the
    /// common case), so we never wrongly tag progressive content as interlaced.
    var isInterlaced: Bool { scanType?.lowercased() == "interlaced" }

    enum VideoRange: Hashable, Sendable {
        case sdr
        case hdr10
        case hdr10Plus
        case hlg
        case dolbyVision(profile: Int)   // P5=5, P7=7, P8=8
    }
}
