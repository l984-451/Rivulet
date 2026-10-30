// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaSource.swift
//  Rivulet
//
//  One playable variant of an item. Most items have exactly one;
//  Plex/Jellyfin return multiple when a title has multiple file versions
//  (4K + 1080p, etc.).
//

import Foundation

struct MediaSource: Hashable, Sendable, Identifiable {
    let id: String                 // provider-native (Plex Media.id / Jellyfin Id)
    let container: String?         // "mkv", "mp4", "ts", "m2ts", "webm"
    let duration: TimeInterval     // seconds
    let bitrate: Int?              // bits/second
    let fileSize: Int64?           // bytes; nil for transcoded streams
    let fileName: String?          // Plex: file path. Jellyfin: the source's Name
    var versionName: String? = nil // the provider's name for this version (Jellyfin "Directors Cut"); nil on Plex
    let videoResolution: String?   // provider-computed label: "4k", "1080", "720", "480", "sd"

    let videoTracks: [VideoTrack]  // usually 1, rarely more
    let audioTracks: [AudioTrack]
    let subtitleTracks: [SubtitleTrack]

    let streamKind: StreamKind
    let streamURL: URL?            // nil until provider.resolveStream(for:) materializes it
    /// Nil uses legacy item-level chapters; an explicit empty list means this version has none.
    var chapters: [MediaChapter]? = nil

    enum StreamKind: Sendable, Hashable, Codable {
        case directPlay
        case hlsTranscode
        case progressiveTranscode
    }
}

extension MediaSource {
    /// Display badges for the hero quality row, e.g. ["4K", "DV", "E-AC3 5.1"].
    /// Order is stable: resolution first, then HDR/range, then audio.
    func qualityBadges() -> [String] {
        ([resolutionBadge] + rangeBadges + [audioBadge]).compactMap { $0 }
    }

    var resolutionBadge: String? { videoTracks.first.flatMap(resolutionLabel) }

    /// Range badges; a Dolby Vision file that also carries HDR10+ gets both (#371).
    var rangeBadges: [String] {
        guard let video = videoTracks.first else { return [] }
        switch video.videoRange {
        case .dolbyVision: return video.hasHDR10Plus ? ["DV", "HDR10+"] : ["DV"]
        case .hdr10Plus: return ["HDR10+"]
        case .hdr10: return video.hasHDR10Plus ? ["HDR10+"] : ["HDR"]
        case .hlg: return ["HLG"]
        case .hdr: return ["HDR"]
        case .sdr, .unknown: return []
        }
    }

    var rangeBadge: String? { rangeBadges.isEmpty ? nil : rangeBadges.joined(separator: " · ") }

    var audioBadge: String? {
        (audioTracks.first(where: { $0.isDefault }) ?? audioTracks.first)?.qualityLabel
    }

    /// Provider label first, pixel height as the fallback (see `VersionRanking.tier`).
    /// Appends "i" for interlaced.
    private func resolutionLabel(_ video: VideoTrack) -> String? {
        func scan(_ base: String) -> String {
            video.isInterlaced ? "\(base)i" : "\(base)p"
        }
        if let raw = videoResolution, !raw.isEmpty, VersionRanking.tier(label: raw, height: nil) == 0 {
            return raw.uppercased()
        }
        switch VersionRanking.tier(label: videoResolution, height: video.height) {
        case 2160: return "4K"
        case 1080: return scan("1080")
        case 720:  return "720p"   // 720 has no interlaced broadcast form
        case 576:  return scan("576")
        case 480:  return scan("480")
        default:   return nil
        }
    }


    var technicalInformation: [(String, String)] {
        var rows: [(String, String)] = []
        if let container, !container.isEmpty { rows.append(("Container", container.uppercased())) }
        if let fileName, !fileName.isEmpty { rows.append(("File", fileName)) }
        if duration.isFinite, duration > 0 { rows.append(("File Duration", String(format: "%.0f s", duration))) }
        if let fileSize, fileSize > 0 {
            rows.append(("File Size", ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))
        }
        if let bitrate, bitrate > 0 { rows.append(("Bitrate", String(format: "%.2f Mbps", Double(bitrate) / 1_000_000))) }
        for (index, video) in videoTracks.enumerated() {
            let name = videoTracks.count > 1 ? "Video \(index + 1)" : "Video"
            let codec = [video.codec == "unknown" ? nil : video.codec.uppercased(), video.profile]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !codec.isEmpty { rows.append((name, codec)) }
            if let range = video.sourceRangeLabel { rows.append(("Dynamic Range", range)) }
            if video.hasHDR10Plus, video.videoRange != .hdr10Plus { rows.append(("HDR10+", "Yes")) }
            if let base = video.compatibleRangeLabel { rows.append(("Compatible Base Range", base)) }
            if let width = video.width, let height = video.height, width > 0, height > 0 {
                rows.append(("Dimensions", "\(width) × \(height)"))
            } else if let resolutionBadge { rows.append(("Resolution", resolutionBadge)) }
            if let rate = video.frameRate, rate.isFinite, rate > 0 { rows.append(("Frame Rate", String(format: "%.3f fps", rate))) }
            if let level = video.level, level > 0 { rows.append(("Video Codec Level", "\(level)")) }
            if let bitrate = video.bitrate, bitrate > 0 {
                rows.append(("Video Bitrate", String(format: "%.2f Mbps", Double(bitrate) / 1_000_000)))
            }
            if let scan = video.scanType, !scan.isEmpty { rows.append(("Scan", scan.capitalized)) }
            if let depth = video.bitDepth, depth > 0 { rows.append(("Video Bit Depth", "\(depth)-bit")) }
            if let value = video.aspectRatio { rows.append(("Aspect Ratio", value)) }
            if let value = video.pixelFormat { rows.append(("Pixel Format", value)) }
            if let value = video.colorPrimaries { rows.append(("Color Primaries", value)) }
            if let value = video.colorTransfer { rows.append(("Transfer", value)) }
            if let value = video.colorSpace { rows.append(("Color Space", value)) }
            if let value = video.colorRange { rows.append(("Color Range", value)) }
            if let level = video.dolbyVisionLevel, level > 0 { rows.append(("Dolby Vision Level", "\(level)")) }
            if let compat = video.dolbyVisionCompatibilityID { rows.append(("Dolby Vision Compatibility ID", "\(compat)")) }
        }
        for (index, audio) in audioTracks.enumerated() {
            var facts = [audio.qualityLabel]
            if let language = audio.language, !language.isEmpty { facts.append(language) }
            if let rate = audio.samplingRate, rate > 0 { facts.append("\(rate) Hz") }
            if let depth = audio.bitDepth, depth > 0 { facts.append("\(depth)-bit") }
            if let bitrate = audio.bitrate, bitrate > 0 { facts.append("\(bitrate / 1000) kbps") }
            rows.append(("Audio \(index + 1)", facts.joined(separator: " · ")))
        }
        return rows
    }
}

extension VideoTrack {
    var sourceRangeLabel: String? {
        switch videoRange {
        case .unknown: return nil
        case .sdr: return "SDR"
        case .hdr: return "HDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .hlg: return "HLG"
        case .dolbyVision(let profile):
            var label = profile > 0 ? "Dolby Vision P\(profile)" : "Dolby Vision"
            if let layer = dolbyVisionEnhancementLayer?.lowercased(), ["fel", "mel"].contains(layer) {
                label += " \(layer.uppercased())"
            }
            return label
        }
    }
}
