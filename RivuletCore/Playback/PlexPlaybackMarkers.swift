// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexPlaybackMarkers.swift
//  Rivulet
//
//  Skip markers for a Plex item: the server's own, plus IntroDB's community
//  ones for kinds Plex has none of. The lookup is opt-in ("useIntroDB").
//

import Foundation

enum PlexPlaybackMarkers {
    /// Plex's markers, then the community ones whose kind Plex lacks, by start.
    static func merged(plex: [PlexMarker], community: [PlexMarker]) -> [PlexMarker] {
        let present = Set(plex.compactMap(\.type))
        let extra = community.filter { marker in marker.type.map { !present.contains($0) } ?? false }
        return (plex + extra).sorted { ($0.startTimeOffset ?? 0) < ($1.startTimeOffset ?? 0) }
    }

    /// The credits marker that opens Up Next: the earliest that reads as end credits.
    /// Not server order: an early "credits" marker would otherwise keep Up Next shut until the file ends.
    static func upNextCredits(_ markers: [PlexMarker], duration: TimeInterval) -> PlexMarker? {
        markers
            .filter { $0.isCredits && $0.endTimeSeconds > $0.startTimeSeconds && readsAsEndCredits($0, duration: duration) }
            .min { $0.startTimeSeconds < $1.startTimeSeconds }
    }

    /// Credits starting in the second half, or under five minutes from the end. `duration` 0 is unknown.
    static func readsAsEndCredits(_ marker: PlexMarker, duration: TimeInterval) -> Bool {
        guard duration > 0 else { return true }
        return marker.startTimeSeconds / duration >= 0.5 || duration - marker.startTimeSeconds < 300
    }

    /// The agnostic markers: known kinds with both ends.
    static func playbackMarkers(_ markers: [PlexMarker]) -> [PlaybackMarker] {
        markers.compactMap { marker in
            guard let kind = marker.type.flatMap(PlaybackMarker.Kind.init(rawValue:)),
                  let start = marker.startTimeOffset, let end = marker.endTimeOffset else { return nil }
            return PlaybackMarker(kind: kind, start: TimeInterval(start) / 1000, end: TimeInterval(end) / 1000)
        }
    }

    /// IntroDB's markers for an episode, keyed on its show's IMDb id (an episode's own guids are
    /// episode-level ids IntroDB rejects). Empty for anything else, or when no id is found.
    static func community(
        for item: PlexMetadata, serverURL: String, token: String, network: PlexNetworkManager,
        lookup: @Sendable (String, Int, Int) async -> [PlexMarker] = { await IntroDBClient().markers(imdbID: $0, season: $1, episode: $2) }
    ) async -> [PlexMarker] {
        guard item.type == "episode", let showKey = item.grandparentRatingKey,
              let season = item.parentIndex, let episode = item.index else { return [] }
        let show = try? await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: showKey, includeGuids: true)
        let guids = (show?.Guid ?? []).compactMap(\.id) + [show?.guid].compactMap { $0 }
        guard let imdbID = guids.compactMap(PlexMetadata.extractImdbId(from:)).first else { return [] }
        return await lookup(imdbID, season, episode)
    }

    /// Plex's markers for `item`, with IntroDB's when the user opted in.
    static func markers(
        for item: PlexMetadata, serverURL: String, token: String, network: PlexNetworkManager
    ) async -> [PlexMarker] {
        let plex = item.Marker ?? []
        guard UserDefaults.standard.bool(forKey: "useIntroDB") else { return merged(plex: plex, community: []) }
        let community = await community(for: item, serverURL: serverURL, token: token, network: network)
        return merged(plex: plex, community: community)
    }
}
