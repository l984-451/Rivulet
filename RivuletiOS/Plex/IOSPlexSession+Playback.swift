// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Player-facing Plex calls. Every request goes through the shared
/// PlexNetworkManager; this only shapes them for the iOS player.
extension IOSPlexSession {
    func markWatched(_ request: IOSPlexPlaybackRequest) async {
        guard let key = request.item.ratingKey else { return }
        try? await PlexNetworkManager.shared.markWatched(
            serverURL: request.serverURL,
            authToken: request.token,
            ratingKey: key
        )
    }

    /// The episode after `episode`: the next one in its season, else the
    /// first episode of the next season.
    func nextEpisode(after episode: PlexMetadata, in request: IOSPlexPlaybackRequest) async -> PlexMetadata? {
        guard episode.type == "episode", let index = episode.index else { return nil }
        let network = PlexNetworkManager.shared
        func children(_ key: String?) async -> [PlexMetadata] {
            guard let key else { return [] }
            let items = (try? await network.getChildren(serverURL: request.serverURL, authToken: request.token, ratingKey: key)) ?? []
            return items.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        }
        if let next = await children(episode.parentRatingKey).first(where: { ($0.index ?? 0) > index }) {
            return next
        }
        let season = episode.parentIndex ?? 0
        guard let nextSeason = await children(episode.grandparentRatingKey)
            .first(where: { $0.type == "season" && ($0.index ?? 0) > season }) else { return nil }
        return await children(nextSeason.ratingKey).first
    }
}

extension IOSPlexPlaybackRequest {
    /// Plex external subtitle streams (the ones with a `key`), registered with
    /// the engine at load. Mirrors tvOS UniversalPlayerViewModel.aetherExternalSubtitles.
    var sidecarSubtitles: [AetherPlayer.SidecarSubtitle] {
        guard let streams = item.Media?.first?.Part?.first?.Stream else { return [] }
        return streams.filter { $0.isSubtitle && $0.key != nil }.compactMap { stream in
            guard let key = stream.key,
                  var components = URLComponents(string: "\(serverURL)\(key)") else { return nil }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "X-Plex-Token", value: token)]
            guard let url = components.url else { return nil }
            return AetherPlayer.SidecarSubtitle(
                url: url,
                name: stream.displayTitle ?? stream.extendedDisplayTitle,
                language: stream.languageCode ?? stream.language,
                isForced: stream.forced ?? false,
                isHearingImpaired: stream.hearingImpaired ?? false,
                isDefault: stream.default ?? false,
                formatHint: stream.codec
            )
        }
    }
}
