// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  UpNextRowState.swift
//  Rivulet
//
//  Card status for the Up Next pane: position relative to the playing
//  episode wins over watch history (so a rewatch shows queue order, not
//  the stale "watched" badge from the prior viewing).
//

import Foundation

enum UpNextRowState: Equatable {
    case watched
    case nowPlaying
    case upNext
    case future

    static func state(for episode: PlexMetadata, in episodes: [PlexMetadata],
                       currentRatingKey: String?) -> UpNextRowState {
        if let currentRatingKey, episode.ratingKey == currentRatingKey { return .nowPlaying }
        let currentPosition = episodes.firstIndex { $0.ratingKey == currentRatingKey }
        let position = episodes.firstIndex { $0.ratingKey == episode.ratingKey }
        if let currentPosition, let position, position > currentPosition {
            return position == currentPosition + 1 ? .upNext : .future
        }
        if (episode.viewCount ?? 0) > 0 { return .watched }
        return .future
    }
}
