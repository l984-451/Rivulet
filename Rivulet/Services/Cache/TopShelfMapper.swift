// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfMapper.swift
//  Rivulet
//
//  Pure mapping from Plex Continue Watching metadata to Top Shelf items.
//  Extracted from PlexDataStore.updateTopShelfCache so the movie-inclusion
//  behavior (GitHub #194) is unit-testable without network/auth singletons.
//

import Foundation

enum TopShelfMapper {

    /// Map dedicated `/hubs/continueWatching` metadata into Top Shelf items.
    /// - Dedupes by ratingKey (first wins), sorts by lastViewedAt desc, caps at `limit`.
    /// - Always emits an item when `ratingKey` exists — never drops movies (or any
    ///   item) for missing art. Backdrop is preferred; poster is the fallback the
    ///   extension uses when `wideImageURL` is empty.
    static func items(
        from metadata: [PlexMetadata],
        serverURL: String,
        token: String,
        limit: Int = 5
    ) -> [TopShelfItem] {
        // Dedupe by ratingKey, keep first occurrence.
        var seen = Set<String>()
        var deduped: [PlexMetadata] = []
        for m in metadata {
            guard let key = m.ratingKey, !seen.contains(key) else { continue }
            seen.insert(key)
            deduped.append(m)
        }
        // Most-recent first.
        deduped.sort { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }

        return deduped.prefix(limit).compactMap { m -> TopShelfItem? in
            guard let ratingKey = m.ratingKey else { return nil }
            let isEpisode = m.type == "episode"

            // Bare episode name for the carousel — the show name rides the line
            // above (contextTitle) Apple-TV+-style, so no "SxxExx - " prefix here
            // (that's what `fullEpisodeTitle` would add).
            let title = m.title ?? "Unknown"
            let subtitle = isEpisode ? m.grandparentTitle : nil

            // Tall poster (kept for fallback) — episode prefers show poster.
            let posterPath = isEpisode
                ? (m.grandparentThumb ?? m.parentThumb ?? m.thumb)
                : m.thumb
            // Wide 16:9 backdrop — episode prefers show backdrop.
            let widePath = isEpisode
                ? (m.grandparentArt ?? m.parentThumb ?? m.thumb)
                : (m.art ?? m.thumb)

            let lastWatched = m.lastViewedAt
                .map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .distantPast

            return TopShelfItem(
                ratingKey: ratingKey,
                title: title,
                subtitle: subtitle,
                imageURL: absoluteURL(posterPath, serverURL: serverURL, token: token),
                wideImageURL: absoluteURL(widePath, serverURL: serverURL, token: token),
                logoImageURL: "",
                compositeFileName: nil,
                progress: m.watchProgress ?? 0,
                type: m.type ?? "movie",
                lastWatched: lastWatched,
                serverIdentifier: serverURL
            )
        }
    }

    /// Recently Added fallback for an empty Continue Watching: unwatched movies, shows and
    /// episodes, newest `addedAt` first (stable), deduped, capped at `limit`.
    static func recentlyAddedItems(
        from metadata: [PlexMetadata],
        serverURL: String,
        token: String,
        limit: Int = 5
    ) -> [TopShelfItem] {
        let playable = metadata.filter { ["movie", "show", "episode"].contains($0.type ?? "") && !$0.isWatched }
        let newest = playable.enumerated()
            .sorted { ($0.element.addedAt ?? 0, $1.offset) > ($1.element.addedAt ?? 0, $0.offset) }
            .map(\.element)
        // Unwatched, so no lastViewedAt: `items` keeps this order.
        return items(from: newest, serverURL: serverURL, token: token, limit: limit)
    }

    /// Map a non-Plex Continue Watching row (Jellyfin) into Top Shelf items.
    /// The logo is known up front, so the composer skips its Plex lookup.
    static func items(from mediaItems: [MediaItem], limit: Int = 5) -> [TopShelfItem] {
        mediaItems.prefix(limit).map { m in
            let isEpisode = m.kind == .episode
            let show = isEpisode ? m.grandparentArtwork : nil
            let poster = show?.poster ?? m.artwork.poster
            let wide = m.artwork.backdrop ?? show?.backdrop ?? m.artwork.thumbnail
            return TopShelfItem(
                ratingKey: m.ref.itemID,
                title: m.title,
                subtitle: isEpisode ? m.seriesTitle : nil,
                imageURL: poster?.absoluteString ?? "",
                wideImageURL: wide?.absoluteString ?? "",
                logoImageURL: m.artwork.logo?.absoluteString ?? "",
                compositeFileName: nil,
                progress: m.watchProgress ?? 0,
                type: isEpisode ? "episode" : "movie",
                lastWatched: m.userState.lastViewedAt ?? .distantPast,
                serverIdentifier: m.ref.providerID
            )
        }
    }

    /// Every server's items in one list, most recently watched first. Ties
    /// (items never watched, like Up Next) keep their server's order.
    static func merge(_ lists: [TopShelfItem]..., limit: Int = 5) -> [TopShelfItem] {
        let all = lists.flatMap { $0 }.enumerated()
            .sorted { ($0.element.lastWatched, $1.offset) > ($1.element.lastWatched, $0.offset) }
        return all.prefix(limit).map(\.element)
    }

    /// Resolve a Plex image path to an absolute, token-bearing URL string.
    /// Returns "" when the path is nil/empty (extension treats empty as "fall back").
    private static func absoluteURL(_ path: String?, serverURL: String, token: String) -> String {
        guard let path, !path.isEmpty else { return "" }
        let isAbsolute = path.hasPrefix("http")
        var url = isAbsolute ? path : "\(serverURL)\(path)"
        // An absolute URL on another host (a metadata CDN) must not receive the token.
        if !url.contains("X-Plex-Token"), !isAbsolute || URL(string: path)?.host == URL(string: serverURL)?.host {
            url += url.contains("?") ? "&" : "?"
            url += "X-Plex-Token=\(token)"
        }
        return url
    }
}
