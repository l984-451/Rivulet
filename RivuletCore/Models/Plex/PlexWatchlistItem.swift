// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexWatchlistItem.swift
//  Rivulet
//
//  Lightweight display model for items on a user's Plex Watchlist.
//

import Foundation

nonisolated struct PlexWatchlistItem: Identifiable, Hashable, Codable, Sendable {
    nonisolated enum WatchlistType: String, Codable, Sendable {
        case movie
        case show
    }

    let id: String          // Plex discover ratingKey or first GUID
    let title: String
    let year: Int?
    let type: WatchlistType
    let posterURL: URL?
    let guids: [String]     // tmdb://, imdb://, tvdb://
    /// Primary plex:// guid (the global Plex metadata id). Plex assigns the same plex:// guid to a
    /// title across Discover and the local server for agent-matched items, so this resolves directly
    /// to the owned library item via /library/all?guid=. The external guids above are NOT indexed by
    /// the server for that query, so plexGUID is the reliable ownership key.
    let plexGUID: String?

    init(
        id: String,
        title: String,
        year: Int?,
        type: WatchlistType,
        posterURL: URL?,
        guids: [String],
        plexGUID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.type = type
        self.posterURL = posterURL
        self.guids = guids
        self.plexGUID = plexGUID
    }

    var primaryGUID: String? { guids.first }

    var tmdbId: Int? {
        for g in guids where g.hasPrefix("tmdb://") {
            if let id = Int(g.dropFirst("tmdb://".count)) { return id }
        }
        return nil
    }
}
