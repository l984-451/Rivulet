// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Player-facing Plex calls. Every request goes through the shared
/// PlexNetworkManager; this only shapes them for the iOS player.
extension IOSPlexSession {
    func markWatched(_ request: IOSPlexPlaybackRequest) async {
        guard let key = request.item.ratingKey else { return }
        let at = Date()
        if request.isLocal { IOSDownloadCenter.shared.noteProgress(ratingKey: key, serverID: request.downloadServerID, offsetMs: 0, watched: true, persist: true) }
        guard !request.serverURL.isEmpty else { return }
        do {
            try await PlexNetworkManager.shared.markWatched(
                serverURL: request.serverURL,
                authToken: request.token,
                ratingKey: key
            )
            IOSOfflineProgress.reached(key, at: at)
        } catch {
            let duration = request.item.duration
            IOSOfflineProgress.failed(key, offsetMs: duration ?? 0, durationMs: duration, watched: true, at: at)
        }
    }

    /// The episode after `episode`: the next one in its season, else the
    /// first episode of the next season. Offline, the next downloaded one.
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
        if let nextSeason = await children(episode.grandparentRatingKey)
            .first(where: { $0.type == "season" && ($0.index ?? 0) > season }),
           let next = await children(nextSeason.ratingKey).first {
            return next
        }
        let position = { (item: PlexMetadata) in (item.parentIndex ?? 0, item.index ?? 0) }
        let center = IOSDownloadCenter.shared
        let server = request.downloadServerID ?? center.currentServerID
        return center.visibleRecords
            .filter { $0.state == .completed && (server == nil || $0.serverID.isEmpty || $0.serverID == server) }
            .map(\.metadata)
            .filter { $0.type == "episode" && $0.grandparentRatingKey == episode.grandparentRatingKey }
            .filter { position($0) > (season, index) }
            .min { position($0) < position($1) }
    }

    /// Replays progress logged while the server was unreachable, unless the server saw a later view.
    /// True when anything was sent.
    func flushOfflineProgress() async -> Bool {
        let center = IOSDownloadCenter.shared
        guard !IOSOfflineProgress.isFlushing, let (serverURL, token) = try? configuration(),
              let server = center.currentServerID else { return false }
        let profile = center.currentProfileID
        let due = IOSOfflineProgress.log.entries.filter { $0.serverID == server && $0.profileID == profile }
        guard !due.isEmpty else { return false }
        IOSOfflineProgress.isFlushing = true
        defer { IOSOfflineProgress.isFlushing = false }
        return await OfflineProgressLog.replay(
            due,
            serverLastViewedAt: { entry in
                let current = try await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: entry.ratingKey)
                return current.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            },
            send: { entry in
                try await network.reportProgress(
                    serverURL: serverURL, authToken: token, ratingKey: entry.ratingKey,
                    timeMs: entry.offsetMs, state: "stopped", duration: entry.durationMs)
                if entry.watched {
                    try await network.markWatched(serverURL: serverURL, authToken: token, ratingKey: entry.ratingKey)
                }
            },
            remove: { IOSOfflineProgress.remove($0) }
        )
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

/// Progress that failed to reach the server, kept next to the downloads manifest.
@MainActor
enum IOSOfflineProgress {
    private static let url = IOSDownloadTransfer.directory.appending(path: "offline-progress.json")
    private(set) static var log = OfflineProgressLog.load(from: url)
    private static var lastReached: [String: Date] = [:]
    static var isFlushing = false

    static func failed(_ ratingKey: String, offsetMs: Int, durationMs: Int?, watched: Bool, at: Date) {
        let center = IOSDownloadCenter.shared
        // A report that failed after a newer one landed adds nothing.
        guard let server = center.currentServerID, lastReached[ratingKey].map({ $0 < at }) ?? true else { return }
        log.record(.init(serverID: server, profileID: center.currentProfileID, ratingKey: ratingKey,
                         offsetMs: offsetMs, durationMs: durationMs, watched: watched, at: at))
        try? log.save(to: url)
    }

    /// A report landed, so older offline entries for the item are stale.
    static func reached(_ ratingKey: String, at: Date) {
        lastReached[ratingKey] = max(at, lastReached[ratingKey] ?? at)
        let before = log.entries.count
        let server = IOSDownloadCenter.shared.currentServerID
        log.entries.removeAll { $0.serverID == server && $0.ratingKey == ratingKey && $0.at <= at }
        if log.entries.count != before { try? log.save(to: url) }
    }

    /// Drops a replayed entry; a newer one coalesced in meanwhile stays.
    static func remove(_ entry: OfflineProgressLog.Entry) {
        log.entries.removeAll { $0 == entry }
        try? log.save(to: url)
    }
}

extension IOSPlexPlaybackRequest {
    /// A downloaded file rather than a server stream.
    var isLocal: Bool { url.isFileURL }

    /// Plex external subtitle streams (the ones with a `key`), registered with
    /// the engine at load. Mirrors tvOS UniversalPlayerViewModel.aetherExternalSubtitles.
    /// None on a transcode, which carries the server's own subtitle rendition.
    var sidecarSubtitles: [AetherPlayer.SidecarSubtitle] {
        if let localSidecars { return localSidecars }
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
