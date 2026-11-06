// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The Plex lookups the Plex player and downloads still take by `PlexMetadata`. Browsing,
/// search, detail and the item actions go through the providers (IOSBrowseStore).
extension IOSPlexSession {
    /// Marks a row and its items as `serverID`'s.
    nonisolated static func onServer(_ items: [PlexMetadata], _ serverID: String?) -> [PlexMetadata] {
        guard serverID != nil else { return items }
        return items.map { item in
            var item = item
            item.serverID = serverID
            return item
        }
    }

    /// Full metadata: markers, chapters, extras, external guids, On Deck.
    func metadata(for item: PlexMetadata) async throws -> PlexMetadata {
        guard let key = item.ratingKey else { return item }
        let (serverURL, token) = try configuration(serverID: item.serverID)
        var full = try await network.getFullMetadata(serverURL: serverURL, authToken: token, ratingKey: key)
        full.serverID = item.serverID
        // On Deck is the next episode on the same server.
        if let onDeck = full.OnDeck?.Metadata { full.OnDeck?.Metadata = Self.onServer(onDeck, item.serverID) }
        return full
    }

    func children(of item: PlexMetadata) async throws -> [PlexMetadata] {
        guard let key = item.ratingKey else { return [] }
        let (serverURL, token) = try configuration(serverID: item.serverID)
        let kids = Self.onServer(try await network.getChildren(serverURL: serverURL, authToken: token, ratingKey: key), item.serverID)
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        // A show's seasons: Specials after the last season (#534).
        return SeasonOrder.specialsLast(kids) { $0.type == "season" ? $0.index : nil }
    }

    /// The episode Play should start for a show or season: On Deck when Plex
    /// has one, otherwise the next unfinished episode of the first real season.
    func playableTarget(for item: PlexMetadata) async throws -> PlexMetadata {
        if item.isPlayable { return item }
        let full = try await metadata(for: item)
        if let next = full.OnDeck?.Metadata?.first { return next }
        var season = full
        if full.type == "show" {
            let seasons = try await children(of: full)
            guard let first = seasons.first(where: { ($0.index ?? 0) > 0 }) ?? seasons.first else {
                throw IOSPlexSessionError.noPlayableURL
            }
            season = first
        }
        guard let episode = Self.nextUp(in: try await children(of: season)) else {
            throw IOSPlexSessionError.noPlayableURL
        }
        return episode
    }

    /// Resume point first, then the first unwatched, then the first episode.
    static func nextUp(in episodes: [PlexMetadata]) -> PlexMetadata? {
        episodes.first(where: \.isInProgress)
            ?? episodes.first(where: { !$0.isWatched })
            ?? episodes.first
    }
}
