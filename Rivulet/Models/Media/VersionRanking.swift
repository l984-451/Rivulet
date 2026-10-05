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

enum VersionChoice: Equatable, Sendable {
    case best
    case source(String)        // Plex Media.id / Jellyfin MediaSource.Id
    case matchingTier(Int)     // a `VersionRanking.tier` value; Up Next keeps it
}

enum VersionRanking {
    struct Key: Comparable {
        let tier: Int
        let range: Int
        let bitrate: Int

        static func < (a: Key, b: Key) -> Bool {
            (a.tier, a.range, a.bitrate) < (b.tier, b.range, b.bitrate)
        }
    }

    /// Resolution class: 2160, 1080, 720, 576, 480, or 0 when unknown. The
    /// provider's label wins over pixel height, which crops below nominal.
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

    static func rangeRank(_ range: VideoTrack.VideoRange) -> Int {
        switch range {
        case .dolbyVision: 4
        case .hdr10Plus: 3
        case .hdr10: 2
        case .hlg: 1
        case .sdr: 0
        }
    }

    static func key(_ source: MediaSource) -> Key {
        let video = source.videoTracks.first
        return Key(tier: tier(label: source.videoResolution, height: video?.height),
                   range: rangeRank(video?.videoRange ?? .sdr),
                   bitrate: source.bitrate ?? 0)
    }

    static func key(_ media: PlexMedia) -> Key {
        let video = (media.Part?.first?.Stream ?? []).lazy.compactMap(PlexMediaMapper.videoTrack).first
        return Key(tier: tier(label: media.videoResolution, height: media.height ?? video?.height),
                   range: rangeRank(video?.videoRange ?? .sdr),
                   bitrate: (media.bitrate ?? 0) * 1000)
    }

    /// Distinct versions, best first.
    static func ordered(_ sources: [MediaSource]) -> [MediaSource] {
        let unique = distinct(sources)
        return rankedIndices(unique.map(key)).map { unique[$0] }
    }

    static func choose(_ choice: VersionChoice, from sources: [MediaSource]) -> MediaSource? {
        let unique = distinct(sources)
        return pick(choice, ids: unique.map(\.id), keys: unique.map(key)).map { unique[$0] }
    }

    /// Moves the chosen version of a server-ordered `Media` array to the front.
    /// `serverIndex` is its original position, which Plex's transcoder calls `mediaIndex`.
    static func select(_ choice: VersionChoice, in media: [PlexMedia]) -> (media: [PlexMedia], serverIndex: Int) {
        guard let index = pick(choice, ids: media.map { "\($0.id)" }, keys: media.map(key)) else {
            return (media, 0)
        }
        var reordered = media
        reordered.insert(reordered.remove(at: index), at: 0)
        return (reordered, index)
    }

    private static func distinct(_ sources: [MediaSource]) -> [MediaSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }

    /// Indices best first; equal keys keep their original order.
    private static func rankedIndices(_ keys: [Key]) -> [Int] {
        keys.indices.sorted { keys[$0] != keys[$1] ? keys[$0] > keys[$1] : $0 < $1 }
    }

    private static func pick(_ choice: VersionChoice, ids: [String], keys: [Key]) -> Int? {
        let ranked = rankedIndices(keys)
        let match: Int? = switch choice {
        case .best: nil
        case .source(let id): ranked.first { ids[$0] == id }
        case .matchingTier(let tier): ranked.first { keys[$0].tier == tier }
        }
        return match ?? ranked.first
    }
}

extension MediaItemDetail {
    /// The version Play uses. Detail badges read this so they describe that file.
    var primarySource: MediaSource? { VersionRanking.ordered(mediaSources).first }
}
