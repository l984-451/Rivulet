// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VersionRanking.swift
//  Rivulet
//
//  Which file of a multi-version item plays. One rule for Plex and every
//  MediaProvider: resolution tier, then dynamic range, then bitrate.
//

import Foundation

nonisolated enum VersionChoice: Equatable, Sendable {
    case best
    case source(String)        // Plex Media.id / Jellyfin MediaSource.Id
    case matchingTier(Int)     // a `VersionRanking.tier` value; Up Next keeps it
}

nonisolated enum VersionRanking {
    struct Key: Comparable, Sendable {
        let tier: Int
        let range: Int
        /// Bits per second; 0 when unknown.
        let bitrate: Int

        static func < (a: Key, b: Key) -> Bool {
            (a.tier, a.range, a.bitrate) < (b.tier, b.range, b.bitrate)
        }
    }

    /// Resolution class: 2160, 1080, 720, 576, 480, or 0 when unknown.
    /// The provider's label wins over pixel height, which crops below nominal.
    static func tier(label: String?, height: Int?) -> Int {
        switch label?.lowercased() {
        case "4k", "2160": return 2160
        case "1080": return 1080
        case "720": return 720
        case "576": return 576
        case "480", "sd": return 480
        default: break
        }
        guard let height else { return 0 }
        switch height {
        case 1600...: return 2160
        case 800..<1600: return 1080
        case 620..<800: return 720
        case 500..<620: return 576
        case 1..<500: return 480
        default: return 0
        }
    }

    /// Range rank matches `PlexMediaMapper.videoTrack`: DV 4, HDR10 2, HLG 1, SDR 0.
    static func key(_ media: PlexMedia) -> Key {
        let video = (media.Part?.first?.Stream ?? []).first { $0.streamType == 1 }
        let range: Int = if video?.DOVIPresent == true {
            4
        } else if video?.colorTrc == "smpte2084" && video?.colorPrimaries == "bt2020" {
            2
        } else if video?.colorTrc == "arib-std-b67" {
            1
        } else {
            0
        }
        return Key(tier: tier(label: media.videoResolution, height: media.height ?? video?.height),
                   range: range,
                   bitrate: (media.bitrate ?? 0) * 1000)
    }

    /// Moves the chosen version of a server-ordered `Media` array to the front.
    /// `serverIndex` is its original position, which Plex's transcoder calls `mediaIndex`.
    static func select(_ choice: VersionChoice, in media: [PlexMedia],
                       capKbps: Int? = nil) -> (media: [PlexMedia], serverIndex: Int) {
        guard let index = pick(choice, ids: media.map { "\($0.id)" }, keys: media.map(key), capKbps: capKbps) else {
            return (media, 0)
        }
        var reordered = media
        reordered.insert(reordered.remove(at: index), at: 0)
        return (reordered, index)
    }

    /// Indices best first; equal keys keep their original order.
    static func rankedIndices(_ keys: [Key]) -> [Int] {
        keys.indices.sorted { keys[$0] != keys[$1] ? keys[$0] > keys[$1] : $0 < $1 }
    }

    /// Under a cap, `.best` and `.matchingTier` prefer a version that fits without
    /// dropping below the tier the cap's step would give; `.source` ignores the cap.
    static func pick(_ choice: VersionChoice, ids: [String], keys: [Key], capKbps: Int? = nil) -> Int? {
        let ranked = rankedIndices(keys)
        let pool: [Int]
        switch choice {
        case .best:
            pool = ranked
        case .source(let id):
            return ranked.first { ids[$0] == id } ?? ranked.first
        case .matchingTier(let tier):
            let matching = ranked.filter { keys[$0].tier == tier }
            pool = matching.isEmpty ? ranked : matching
        }
        guard let capKbps else { return pool.first }
        let minTier = QualityDecision.highestStep(atMost: capKbps).tier
        let eligible = pool.filter { keys[$0].bitrate > 0 && keys[$0].tier >= minTier }
        return eligible.first { keys[$0].bitrate <= capKbps * 1000 }
            ?? eligible.min { keys[$0].bitrate < keys[$1].bitrate }
            ?? pool.first
    }
}
