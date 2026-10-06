// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VersionRanking+MediaSource.swift
//  Rivulet
//
//  The MediaSource side of VersionRanking; the core lives in RivuletCore/Streaming.
//

import Foundation

extension VersionRanking {
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

    /// Distinct versions, best first.
    static func ordered(_ sources: [MediaSource]) -> [MediaSource] {
        let unique = distinct(sources)
        return rankedIndices(unique.map(key)).map { unique[$0] }
    }

    static func choose(_ choice: VersionChoice, from sources: [MediaSource], capKbps: Int? = nil) -> MediaSource? {
        let unique = distinct(sources)
        return pick(choice, ids: unique.map(\.id), keys: unique.map(key), capKbps: capKbps).map { unique[$0] }
    }

    private static func distinct(_ sources: [MediaSource]) -> [MediaSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }
}

extension MediaItemDetail {
    /// The version Play uses. Detail badges read this so they describe that file.
    var primarySource: MediaSource? { VersionRanking.ordered(mediaSources).first }
}
