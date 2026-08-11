// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexStream.swift
//  Rivulet
//
//  Media stream information (video, audio, subtitle tracks)
//

import Foundation

/// Represents a media stream within a Plex media part
/// streamType: 1 = video, 2 = audio, 3 = subtitle
nonisolated struct PlexStream: Codable, Identifiable, Sendable {
    /// Plex-assigned stream id. `nil` for streams embedded in the video
    /// container (e.g., EIA-608 closed captions with `embeddedInVideo: "1"`),
    /// which Plex omits because they're baked into their parent stream.
    /// Use `id` (computed below) as the stable public identifier.
    let _id: Int?
    let streamType: Int
    /// Stream index within the containing part. Used to synthesize a stable
    /// `id` when Plex omits one.
    let index: Int?
    let codec: String?
    let codecID: String?
    let language: String?
    let languageCode: String?
    let languageTag: String?
    let displayTitle: String?
    let title: String?
    let `default`: Bool?
    let forced: Bool?
    let selected: Bool?

    // Video-specific
    let bitDepth: Int?
    let chromaLocation: String?
    let chromaSubsampling: String?
    let colorPrimaries: String?
    let colorRange: String?
    let colorSpace: String?
    let colorTrc: String?
    let DOVIBLCompatID: Int?
    let DOVIBLPresent: Bool?
    let DOVIELPresent: Bool?
    let DOVILevel: Int?
    let DOVIPresent: Bool?
    let DOVIProfile: Int?
    let DOVIRPUPresent: Bool?
    let DOVIVersion: String?
    let frameRate: Double?
    let height: Int?
    let width: Int?
    let level: Int?
    let profile: String?
    let refFrames: Int?
    let scanType: String?

    // Audio-specific
    let audioChannelLayout: String?
    let channels: Int?
    let bitrate: Int?
    let samplingRate: Int?

    // Subtitle-specific
    let format: String?
    let key: String?           // For external subtitles
    let extendedDisplayTitle: String?
    let hearingImpaired: Bool?

    // MARK: - Identifiable

    /// Stable identifier. Uses Plex's `_id` verbatim when present; otherwise
    /// synthesizes a negative id from `streamType` + `index` so embedded
    /// streams (e.g., closed captions baked into the video) still participate
    /// in `Identifiable` / `ForEach` without colliding with real Plex ids.
    var id: Int {
        if let _id { return _id }
        return -((streamType * 1_000_000) + (index ?? 0) + 1)
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case _id = "id"
        case streamType, index
        case codec, codecID
        case language, languageCode, languageTag
        case displayTitle, title
        case `default`, forced, selected
        case bitDepth, chromaLocation, chromaSubsampling
        case colorPrimaries, colorRange, colorSpace, colorTrc
        case DOVIBLCompatID, DOVIBLPresent, DOVIELPresent
        case DOVILevel, DOVIPresent, DOVIProfile
        case DOVIRPUPresent, DOVIVersion
        case frameRate, height, width, level, profile, refFrames, scanType
        case audioChannelLayout, channels, bitrate, samplingRate
        case format, key, extendedDisplayTitle, hearingImpaired
    }

    // MARK: - Convenience Properties

    var isVideo: Bool { streamType == 1 }
    var isAudio: Bool { streamType == 2 }
    var isSubtitle: Bool { streamType == 3 }

    /// Whether this is an HDR stream
    var isHDR: Bool {
        guard isVideo else { return false }
        // Check for HDR indicators
        if let colorTrc = colorTrc?.lowercased() {
            if colorTrc.contains("smpte2084") || colorTrc.contains("pq") ||
               colorTrc.contains("hlg") || colorTrc.contains("arib-std-b67") {
                return true
            }
        }
        if let colorSpace = colorSpace?.lowercased() {
            if colorSpace.contains("bt2020") {
                return true
            }
        }
        return false
    }

    /// Whether this is Dolby Vision
    var isDolbyVision: Bool {
        DOVIPresent == true || DOVIProfile != nil
    }

    /// Whether this subtitle format requires VLC for proper rendering
    var isAdvancedSubtitle: Bool {
        guard isSubtitle else { return false }
        let advancedFormats = ["ass", "ssa", "pgs", "pgssub", "dvdsub", "dvbsub", "vobsub", "hdmv_pgs_subtitle"]
        if let codec = codec?.lowercased() {
            return advancedFormats.contains(codec)
        }
        if let format = format?.lowercased() {
            return advancedFormats.contains(format)
        }
        return false
    }
}
