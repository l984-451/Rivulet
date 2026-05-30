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
    let fileName: String?          // display name for source picker ("4K HDR", etc.)
    let videoResolution: String?   // provider-computed label: "4k", "1080", "720", "480", "sd"

    let videoTracks: [VideoTrack]  // usually 1, rarely more
    let audioTracks: [AudioTrack]
    let subtitleTracks: [SubtitleTrack]

    let streamKind: StreamKind
    let streamURL: URL?            // nil until provider.resolveStream(for:) materializes it

    enum StreamKind: Sendable, Hashable, Codable {
        case directPlay
        case hlsTranscode
        case progressiveTranscode
    }
}

extension MediaSource {
    /// Display badges for the source picker / hero quality row.
    /// Returns labels like ["4K", "DV", "5.1"] derived from track metadata.
    /// Order is stable: resolution first, then HDR/range, then audio.
    func qualityBadges() -> [String] {
        var badges: [String] = []

        if let video = videoTracks.first {
            if let res = resolutionLabel(video) { badges.append(res) }

            // HDR / DV
            switch video.videoRange {
            case .dolbyVision: badges.append("DV")
            case .hdr10, .hdr10Plus: badges.append("HDR")
            case .hlg: badges.append("HLG")
            case .sdr: break
            }
        }

        // The default audio track (falling back to the first) drives the badge.
        // Shows codec + channel layout for every track, including stereo/mono.
        if let audio = audioTracks.first(where: { $0.isDefault }) ?? audioTracks.first {
            badges.append(audio.qualityLabel)
        }

        return badges
    }

    /// Resolution badge. Prefers the provider-computed `videoResolution`
    /// ("4k"/"1080"/...), which is correct for cropped widescreen content
    /// whose pixel height is below the nominal value; falls back to the video
    /// track's height only when the provider supplies nothing.
    private func resolutionLabel(_ video: VideoTrack) -> String? {
        // Interlaced sources carry an "i" suffix (1080i/576i/480i); progressive
        // gets "p". 4K and 720 have no interlaced broadcast form, so they stay
        // progressive even if a probe oddly claims otherwise. Absent scanType
        // means assume progressive (the common case), so we never mislabel.
        func scan(_ base: String) -> String { base + (video.isInterlaced ? "i" : "p") }

        switch videoResolution?.lowercased() {
        case "4k", "2160": return "4K"
        case "1080":       return scan("1080")
        case "720":        return "720p"
        case "576":        return scan("576")
        case "480", "sd":  return scan("480")
        case .some(let r) where !r.isEmpty: return r.uppercased()  // e.g. "8K"
        default: break
        }
        guard let height = video.height else { return nil }
        switch height {
        case 1600...:    return "4K"
        case 800..<1600: return scan("1080")
        case 620..<800:  return "720p"
        case 500..<620:  return scan("576")
        case 1..<500:    return scan("480")
        default:         return nil
        }
    }
}
