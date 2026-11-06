// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Player-facing Plex calls. Every request goes through the shared
/// PlexNetworkManager; this only shapes them for the iOS player.
extension IOSPlexSession {
    func markWatched(_ request: IOSPlexPlaybackRequest) async {
        guard let key = request.item.ratingKey else { return }
        let at = Date()
        if request.isLocal { IOSDownloadCenter.shared.noteProgress(for: request, offsetMs: 0, watched: true, persist: true) }
        guard !request.serverURL.isEmpty else { return }
        do {
            try await PlexNetworkManager.shared.markWatched(
                serverURL: request.serverURL,
                authToken: request.token,
                ratingKey: key
            )
            if let owner = plexProviderID(of: request) { IOSOfflineProgress.reached(owner, itemID: key, at: at) }
        } catch {
            let duration = request.item.duration
            if let owner = plexProviderID(of: request) {
                IOSOfflineProgress.record(providerID: owner, itemID: key, offsetMs: duration ?? 0,
                                          durationMs: duration, watched: true, at: at)
            }
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
        let center = IOSDownloadCenter.shared
        let server = request.downloadProviderID ?? DownloadIdentity.plexProviderID(machineID: center.currentServerID)
        return DownloadRules.nextDownloaded(
            afterShow: episode.grandparentRatingKey, season: season, episode: index, providerID: server,
            in: center.visibleRecords)?.metadata
    }

    /// Replays progress logged while a server was unreachable, unless the server saw a later view.
    /// True when anything was sent.
    func flushOfflineProgress() async -> Bool {
        let plex = await flushPlexProgress()
        let others = await IOSOfflineProgress.flushProviders()
        return plex || others
    }

    private func flushPlexProgress() async -> Bool {
        let center = IOSDownloadCenter.shared
        guard !IOSOfflineProgress.isFlushing, let (serverURL, token) = try? configuration(),
              let server = center.currentServerID else { return false }
        let profile = center.currentProfileID
        let key = DownloadIdentity.plexProviderID(machineID: server)
        let due = IOSOfflineProgress.log.entries.filter { DownloadIdentity.matches($0.providerID, key) && $0.profileID == profile }
        guard !due.isEmpty else { return false }
        IOSOfflineProgress.isFlushing = true
        defer { IOSOfflineProgress.isFlushing = false }
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
            remove: { IOSOfflineProgress.remove($0) }
        )
    }

    /// Frees the server's transcoder; a reload or exit leaves it running otherwise.
    func stopTranscode(_ request: IOSPlexPlaybackRequest) async {
        guard let session = request.transcodeSessionID else { return }
        await network.stopTranscodeSession(serverURL: request.serverURL, authToken: request.token, sessionId: session)
    }

    /// Opens the server's play session before the player asks for media: the transcode's,
    /// or a direct-play one so the dashboard shows its bandwidth (#423).
    func openPlaySession(_ request: IOSPlexPlaybackRequest) async {
        if request.transcodeSessionID != nil {
            await network.startTranscodeDecision(hlsURL: request.url, headers: request.headers)
        } else if let session = request.directPlaySessionID, let key = request.item.ratingKey {
            await network.openDirectPlaySession(serverURL: request.serverURL, authToken: request.token,
                                                ratingKey: key, mediaIndex: request.mediaIndex,
                                                sessionIdentifier: session)
        }
    }

    /// Sets the part's audio or subtitle stream, which a new transcode session reads.
    func selectStream(_ picks: TrackPicks, in request: IOSPlexPlaybackRequest) async {
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

/// Progress that failed to reach a server, kept next to the downloads manifest.
@MainActor
enum IOSOfflineProgress {
    private static let url = IOSDownloadTransfer.directory.appending(path: "offline-progress.json")
    private(set) static var log = OfflineProgressLog.load(from: url)
    private static var lastReached: [String: Date] = [:]
    static var isFlushing = false
    private static var isFlushingProviders = false

    /// Queues a position for `providerID` (a download key), for the current profile and, on Jellyfin and
    /// Emby, the signed-in account.
    static func record(providerID: String, itemID: String, offsetMs: Int, durationMs: Int?, watched: Bool, at: Date) {
        let center = IOSDownloadCenter.shared
        // A bare Plex key (server not known) would replay to whichever server is current, and never clear.
        guard providerID != "plex:" else { return }
        // A report that failed after a newer one landed adds nothing.
        guard lastReached["\(providerID)|\(itemID)"].map({ $0 < at }) ?? true else { return }
        let account = account(of: providerID)
        log.record(.init(providerID: providerID, profileID: center.currentProfileID, accountID: account, itemID: itemID,
                         offsetMs: offsetMs, durationMs: durationMs, watched: watched, at: at))
        try? log.save(to: url)
    }

    /// A report landed, so older offline entries for the item are stale.
    static func reached(_ providerID: String, itemID: String, at: Date) {
        let key = "\(providerID)|\(itemID)"
        lastReached[key] = max(at, lastReached[key] ?? at)
        let before = log.entries.count
        log.entries.removeAll { $0.providerID == providerID && $0.itemID == itemID && $0.at <= at }
        if log.entries.count != before { try? log.save(to: url) }
    }

    /// Drops a replayed entry; a newer one coalesced in meanwhile stays.
    static func remove(_ entry: OfflineProgressLog.Entry) {
        log.entries.removeAll { $0 == entry }
        try? log.save(to: url)
    }

    /// The signed-in account of a Jellyfin or Emby download key; Plex entries have none.
    private static func account(of providerID: String) -> String? {
        guard !providerID.hasPrefix("plex:") else { return nil }
        return MediaProviderRegistry.shared.provider(for: providerID)?.accountID
    }

    /// Sends what is queued for the signed-in Jellyfin and Emby servers. True when anything was sent.
    static func flushProviders() async -> Bool {
        guard !isFlushingProviders else { return false }
        isFlushingProviders = true
        defer { isFlushingProviders = false }
        var sent = false
        for provider in MediaProviderRegistry.shared.secondaryProviders where provider.kind != .plex {
            let due = ProviderProgressReplay.due(log.entries, providerID: provider.id, accountID: provider.accountID,
                                                 profileID: IOSDownloadCenter.shared.currentProfileID)
            guard !due.isEmpty else { continue }
            if await ProviderProgressReplay.replay(due, provider: provider, remove: { remove($0) }) { sent = true }
        }
        return sent
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
        if let providerPlayback {
            // A provider's sidecars are its external tracks, with their own URL and auth.
            guard plan == .original else { return [] }
            return providerPlayback.stream.source.subtitleTracks.filter { !$0.isEmbedded }.compactMap { track in
                guard let url = track.externalURL else { return nil }
                return AetherPlayer.SidecarSubtitle(
                    url: url, name: track.extendedTitle ?? track.title, language: track.language,
                    isForced: track.isForced, isHearingImpaired: track.isHearingImpaired,
                    isDefault: track.isDefault, formatHint: track.codec)
            }
        }
        guard plan == .original, let streams = item.Media?.first?.Part?.first?.Stream else { return [] }
        return streams.filter { $0.isSubtitle && $0.key != nil }.compactMap { stream in
            guard let key = stream.key,
                  let url = PlexSidecarURL.url(serverURL: serverURL, key: key, token: token, codec: stream.codec)
            else { return nil }
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
                name: stream.displayTitle ?? stream.extendedDisplayTitle ?? String(localized: "Track \(stream.id)"),
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
