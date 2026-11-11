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
    var audioTracks: [AudioTrack]
    var subtitleTracks: [SubtitleTrack]

    let streamKind: StreamKind
    let streamURL: URL?            // nil until provider.resolveStream(for:) materializes it

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

    /// 4K or HD, as the Apple TV app labels a title (detail pages); SD gets none, as in Apple's.
    /// `resolutionBadge` is the technical label.
    var definitionBadge: String? {
        guard let video = videoTracks.first else { return nil }
        switch VersionRanking.tier(label: videoResolution, height: video.height) {
        case 2160: return "4K"
        case 720, 1080: return "HD"
        default: return nil
        }
    }

    /// The detail pages' badge row in the Apple TV app's order: definition, range, object audio, then
    /// CC, SDH and AD. Plain codecs are left to the Info popup.
    var detailBadges: [String] {
        var badges = [definitionBadge].compactMap { $0 } + rangeBadges
        if let audio = audioBadge {
            if audio.hasSuffix("Atmos") { badges.append("Atmos") } else if audio.hasPrefix("DTS-X") { badges.append("DTS:X") }
        }
        if subtitleTracks.contains(where: { ["eia_608", "eia_708"].contains($0.codec.lowercased()) }) { badges.append("CC") }
        if subtitleTracks.contains(where: \.isHearingImpaired) { badges.append("SDH") }
        if audioTracks.contains(where: { ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri") }) {
            badges.append("AD")
        }
        return badges
    }

    /// Drawn filled, as Apple draws its definition and HDR badges; CC, SDH and AD stay outlined.
    /// DV and Atmos are logos in Apple's row, so ours stay outlined text.
    static let filledBadges: Set<String> = ["4K", "HD", "HDR", "HDR10+", "HLG"]

    /// Range badges; a Dolby Vision file that also carries HDR10+ gets both (#371).
    var rangeBadges: [String] {
        guard let video = videoTracks.first else { return [] }
        switch video.videoRange {
        case .dolbyVision: return video.hasHDR10Plus ? ["DV", "HDR10+"] : ["DV"]
        case .hdr10Plus: return ["HDR10+"]
        case .hdr10: return video.hasHDR10Plus ? ["HDR10+"] : ["HDR"]
        case .hlg: return ["HLG"]
        case .sdr: return []
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
}
