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

    /// Frees the server's transcoder; a reload or exit leaves it running otherwise.
    func stopTranscode(_ request: IOSPlexPlaybackRequest) async {
        guard let session = request.transcodeSessionID else { return }
        await network.stopTranscodeSession(serverURL: request.serverURL, authToken: request.token, sessionId: session)
    }

    /// Opens the server's transcode session before the player asks for the playlist.
    func openTranscode(_ request: IOSPlexPlaybackRequest) async {
        guard request.transcodeSessionID != nil else { return }
        await network.startTranscodeDecision(hlsURL: request.url, headers: request.headers)
    }

    /// Sets the part's audio or subtitle stream, which a new transcode session reads.
    /// A subtitle id of 0 turns subtitles off.
    func selectStream(audioID: Int? = nil, subtitleID: Int? = nil, in request: IOSPlexPlaybackRequest) async {
        guard let part = request.item.Media?.first?.Part?.first?.id else { return }
        if let audioID {
            await network.setSelectedAudioStream(
                serverURL: request.serverURL, authToken: request.token, partId: part, audioStreamID: audioID)
        }
        if let subtitleID {
            await network.setSelectedSubtitleStream(
                serverURL: request.serverURL, authToken: request.token, partId: part, subtitleStreamID: subtitleID)
        }
    }
}

extension IOSPlexPlaybackRequest {
    /// Plex external subtitle streams (the ones with a `key`), registered with
    /// the engine at load. Mirrors tvOS UniversalPlayerViewModel.aetherExternalSubtitles.
    /// None on a transcode, which carries the server's own subtitle rendition.
    var sidecarSubtitles: [AetherPlayer.SidecarSubtitle] {
        guard plan == .original, let streams = item.Media?.first?.Part?.first?.Stream else { return [] }
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

    /// The part's Plex audio (2) or subtitle (3) streams as tracks keyed by
    /// Plex stream id: a transcode carries only the stream the server picked.
    func plexTracks(streamType: Int) -> [AetherPlayer.Track] {
        (item.Media?.first?.Part?.first?.Stream ?? []).filter { $0.streamType == streamType }.map { stream in
            AetherPlayer.Track(
                id: stream.id,
                name: stream.displayTitle ?? stream.extendedDisplayTitle ?? "Track \(stream.id)",
                codec: stream.codec ?? "",
                language: stream.languageCode ?? stream.language,
                channels: stream.channels ?? 0,
                isDefault: stream.default ?? false,
                isForced: stream.forced ?? false,
                isHearingImpaired: stream.hearingImpaired ?? false
            )
        }
    }

    /// The stream Plex marks selected on the part.
    func selectedPlexStreamID(streamType: Int) -> Int? {
        item.Media?.first?.Part?.first?.Stream?.first { $0.streamType == streamType && $0.selected == true }?.id
    }
}
