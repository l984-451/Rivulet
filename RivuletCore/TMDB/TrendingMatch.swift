// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TrendingMatch.swift
//  Rivulet
//
//  Which of a server's titles are on TMDB's trending lists, for a hero
//  that has no TMDB index of its own (anything but the selected Plex server).
//

import Foundation

enum TrendingMatch {
    /// The lookup key for one owned title: its TMDB id and type.
    static func key(tmdbID: String, type: TMDBMediaType) -> String { "\(type.rawValue):\(tmdbID)" }

    /// Movies and shows alternating, each list in TMDB's order.
    static func interleave(movies: [TMDBListItem], shows: [TMDBListItem]) -> [TMDBListItem] {
        (0..<max(movies.count, shows.count)).flatMap { i in
            (i < movies.count ? [movies[i]] : []) + (i < shows.count ? [shows[i]] : [])
        }
    }

    /// Owned item ids (`owned` maps `key` to an item id) in trending order, each once, at most `limit`.
    static func ownedIDs(_ trending: [TMDBListItem], owned: [String: String], limit: Int) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for title in trending where ids.count < limit {
            if let id = owned[key(tmdbID: String(title.id), type: title.mediaType)], seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }
}
