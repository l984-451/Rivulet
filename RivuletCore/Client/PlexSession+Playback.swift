// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Player-facing Plex calls. Every request goes through the shared
/// PlexNetworkManager; this only shapes them for the iOS player.
extension PlexSession {
    func markWatched(_ request: PlexPlaybackRequest) async {
        guard let key = request.item.ratingKey else { return }
        let at = Date()
        if request.isLocal { ClientHost.offline.noteProgress(for: request, offsetMs: 0, watched: true, persist: true) }
        guard !request.serverURL.isEmpty else { return }
        do {
            // The server usually counted the play itself as the timeline passed its threshold.
            let counted = await PlexNetworkManager.shared.serverCountedPlay(
                serverURL: request.serverURL, authToken: request.token, ratingKey: key,
                playsBefore: request.item.viewCount ?? 0)
            if !counted {
                try await PlexNetworkManager.shared.markWatched(
                    serverURL: request.serverURL,
                    authToken: request.token,
                    ratingKey: key
                )
            }
            if let owner = plexProviderID(of: request) { ClientHost.offline.progressReached(owner, itemID: key, at: at) }
        } catch {
            let duration = request.item.duration
            if let owner = plexProviderID(of: request) {
                ClientHost.offline.recordProgress(providerID: owner, itemID: key, offsetMs: duration ?? 0,
                                          durationMs: duration, watched: true, at: at)
            }
        }
    }

    /// The episode after `episode`: the next one in its season, else the
    /// first episode of the next season. Offline, the next downloaded one.
    func nextEpisode(after episode: PlexMetadata, in request: PlexPlaybackRequest) async -> PlexMetadata? {
        guard episode.type == "episode", let index = episode.index else { return nil }
        let network = PlexNetworkManager.shared
        func children(_ key: String?) async -> [PlexMetadata] {
            guard let key else { return [] }
            let items = (try? await network.getChildren(serverURL: request.serverURL, authToken: request.token, ratingKey: key)) ?? []
            // The next episode is on the same server as this one.
            return Self.onServer(items, episode.serverID).sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        }
        if let next = await children(episode.parentRatingKey).first(where: { ($0.index ?? 0) > index }) {
            return next
        }
        let season = episode.parentIndex ?? 0
        if let nextSeason = await children(episode.grandparentRatingKey)
            .first(where: { $0.type == "season" && ($0.index ?? 0) > season }),
           let next = await children(nextSeason.ratingKey).first {
            return next
        }
        let center = ClientHost.offline
        let server = request.downloadProviderID ?? DownloadIdentity.plexProviderID(machineID: center.currentServerID)
        return DownloadRules.nextDownloaded(
            afterShow: episode.grandparentRatingKey, season: season, episode: index, providerID: server,
            in: center.visibleRecords)?.metadata
    }

    /// Replays progress logged while a server was unreachable, unless the server saw a later view.
    /// True when anything was sent.
    func flushOfflineProgress() async -> Bool {
        let plex = await flushPlexProgress()
        let others = await ClientHost.offline.flushProviders()
        return plex || others
    }

    private func flushPlexProgress() async -> Bool {
        let center = ClientHost.offline
        guard !center.isFlushing, let (serverURL, token) = try? configuration(),
              let server = center.currentServerID else { return false }
        let profile = center.currentProfileID
        let key = DownloadIdentity.plexProviderID(machineID: server)
        let due = center.progressEntries.filter { DownloadIdentity.matches($0.providerID, key) && $0.profileID == profile }
        guard !due.isEmpty else { return false }
        center.isFlushing = true
        defer { center.isFlushing = false }
        return await OfflineProgressLog.replay(
            due,
            serverLastViewedAt: { entry in
                let current = try await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: entry.itemID)
                return current.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            },
            send: { entry in
                try await network.reportProgress(
                    serverURL: serverURL, authToken: token, ratingKey: entry.itemID,
                    timeMs: entry.offsetMs, state: "stopped", duration: entry.durationMs)
                if entry.watched {
                    try await network.markWatched(serverURL: serverURL, authToken: token, ratingKey: entry.itemID)
                }
            },
            remove: { center.removeProgress($0) }
        )
    }

    /// Frees the server's transcoder; a reload or exit leaves it running otherwise.
    func stopTranscode(_ request: PlexPlaybackRequest) async {
        guard let session = request.transcodeSessionID else { return }
        await network.stopTranscodeSession(serverURL: request.serverURL, authToken: request.token, sessionId: session)
    }

    /// Opens the server's play session before the player asks for media: the transcode's,
    /// or a direct-play one so the dashboard shows its bandwidth (#423).
    func openPlaySession(_ request: PlexPlaybackRequest) async {
        if request.transcodeSessionID != nil {
            await network.startTranscodeDecision(hlsURL: request.url, headers: request.headers)
        } else if let session = request.directPlaySessionID, let key = request.item.ratingKey {
            await network.openDirectPlaySession(serverURL: request.serverURL, authToken: request.token,
                                                ratingKey: key, mediaIndex: request.mediaIndex,
                                                sessionIdentifier: session)
        }
    }

    /// Sets the part's audio or subtitle stream, which a new transcode session reads.
    func selectStream(_ picks: TrackPicks, in request: PlexPlaybackRequest) async {
        guard let part = request.item.Media?.first?.Part?.first?.id else { return }
        if let audioID = picks.audio {
            await network.setSelectedAudioStream(
                serverURL: request.serverURL, authToken: request.token, partId: part, audioStreamID: audioID)
        }
        if let subtitle = picks.subtitle {
            await network.setSelectedSubtitleStream(
                serverURL: request.serverURL, authToken: request.token, partId: part, subtitleStreamID: subtitle.plexStreamID)
        }
    }
}

extension PlexPlaybackRequest {
    /// A downloaded file rather than a server stream.
    var isLocal: Bool { url.isFileURL }

    /// Plex external subtitle streams (the ones with a `key`), registered with
    /// the engine at load. Mirrors tvOS UniversalPlayerViewModel.aetherExternalSubtitles.
    /// None on a transcode, which carries the server's own subtitle rendition.
    var sidecarSubtitles: [SubtitleSidecar] { sidecarSubtitles(in: nil) }

    /// True when Plex stacks the playing version from several files (#399). A transcode or a
    /// download plays the first file only, so those stay single.
    var isStacked: Bool {
        !isLocal && providerPlayback == nil && (item.Media?.first?.Part?.count ?? 0) > 1
    }

    /// Every file of a stacked title, nil for one file or when a file has no length.
    var stackedParts: StackedParts<StackedPartFile>? {
        guard isStacked, plan == .original, let parts = item.Media?.first?.Part else { return nil }
        var files: [(file: StackedPartFile, duration: TimeInterval?)] = []
        for part in parts {
            guard let key = part.key, let url = PlexSession.directPlayURL(serverURL: serverURL, token: token, partKey: key)
            else { return nil }
            files.append((StackedPartFile(url: url, sidecars: sidecarSubtitles(in: part)),
                          part.duration.map { TimeInterval($0) / 1000 }))
        }
        return StackedParts(files)
    }

    private func sidecarSubtitles(in part: PlexPart?) -> [SubtitleSidecar] {
        if let localSidecars { return localSidecars }
        if let providerPlayback {
            // A provider's sidecars are its external tracks, with their own URL and auth.
            guard plan == .original else { return [] }
            return providerPlayback.stream.source.subtitleTracks.filter { !$0.isEmbedded }.compactMap { track in
                guard let url = track.externalURL else { return nil }
                return SubtitleSidecar(
                    url: url, name: track.extendedTitle ?? track.title, language: track.language,
                    isForced: track.isForced, isHearingImpaired: track.isHearingImpaired,
                    isDefault: track.isDefault, formatHint: track.codec)
            }
        }
        guard plan == .original, let streams = (part ?? item.Media?.first?.Part?.first)?.Stream else { return [] }
        return streams.filter { $0.isSubtitle && $0.key != nil }.compactMap { stream in
            guard let key = stream.key,
                  let url = PlexSidecarURL.url(serverURL: serverURL, key: key, token: token, codec: stream.codec)
            else { return nil }
            return SubtitleSidecar(
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
