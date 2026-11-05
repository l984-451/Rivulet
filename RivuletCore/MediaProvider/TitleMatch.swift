// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TitleMatch.swift
//  Rivulet
//
//  A title known only by its external ids (a watchlist entry, a TMDB trending
//  row), asked of a server as "do you own this?" through `ownedItems(matching:)`.
//

import Foundation

nonisolated struct TitleMatch: Sendable, Hashable {
    /// `.movie` or `.show`: a movie and a show can share a TMDB number.
    let kind: MediaKind
    /// Lowercase source to id: "tmdb", "imdb", "tvdb".
    let externalIDs: [String: String]
    /// A Plex server indexes only plex:// guids, not the external ids above.
    let plexGUID: String?

    init(kind: MediaKind, externalIDs: [String: String], plexGUID: String?) {
        self.kind = kind
        self.externalIDs = externalIDs
        self.plexGUID = plexGUID
    }

    init(_ trending: TMDBListItem) {
        self.init(kind: trending.mediaType == .movie ? .movie : .show,
                  externalIDs: ["tmdb": String(trending.id)], plexGUID: nil)
    }

    init(_ entry: PlexWatchlistItem) {
        var ids: [String: String] = [:]
        for raw in entry.guids {
            if ids["tmdb"] == nil, let id = PlexMetadata.extractTmdbId(from: raw) { ids["tmdb"] = String(id) }
            if ids["tvdb"] == nil, let id = PlexMetadata.extractTvdbId(from: raw) { ids["tvdb"] = String(id) }
            if ids["imdb"] == nil, let id = PlexMetadata.extractImdbId(from: raw) { ids["imdb"] = id }
        }
        self.init(kind: entry.type == .movie ? .movie : .show, externalIDs: ids, plexGUID: entry.plexGUID)
    }

    /// An item of `kind` holding `ids` is this title when they share any id.
    func matches(kind itemKind: MediaKind, ids: [String: String]) -> Bool {
        itemKind == kind && externalIDs.contains { ids[$0.key] == $0.value }
    }

    /// Item ids for `titles` in title order, each once, at most `limit`. `owned` is what the
    /// server holds: the item's id, kind and external ids (keys lowercase).
    static func orderedIDs(_ titles: [TitleMatch], among owned: [(id: String, kind: MediaKind, ids: [String: String])],
                           limit: Int) -> [String] {
        var index: [String: String] = [:]
        for item in owned {
            for (source, value) in item.ids { index["\(item.kind):\(source):\(value)"] = index["\(item.kind):\(source):\(value)"] ?? item.id }
        }
        var seen = Set<String>()
        var ids: [String] = []
        for title in titles where ids.count < limit {
            let hit = title.externalIDs.sorted { $0.key < $1.key }.lazy.compactMap { index["\(title.kind):\($0.key):\($0.value)"] }.first
            if let hit, seen.insert(hit).inserted { ids.append(hit) }
        }
        return ids
    }
}
