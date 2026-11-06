// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The iOS player's server calls for one provider (Jellyfin, Emby, or any `MediaProvider`),
/// all through the seam. The player reads a Plex-shaped display shim of the item
/// (`ProviderPlaybackMetadata`) while the real stream, session and reports stay here.
@MainActor
final class IOSProviderBackend: IOSPlayerBackend {
    let provider: any MediaProvider
    private let onWatchStateChange: @MainActor () async -> Void
    /// Titles the player can be asked about again (Up Next, playlist entries), by item id.
    private var items: [String: MediaItem] = [:]
    private let ledger = ProviderReportLedger()
    private var startedNativeSessions: Set<String> = []

    init(provider: any MediaProvider, onWatchStateChange: @escaping @MainActor () async -> Void = {}) {
        self.provider = provider
        self.onWatchStateChange = onWatchStateChange
    }

    func register(_ items: [MediaItem]) {
        for item in items { self.items[item.ref.itemID] = item }
    }

    // MARK: - Starting

    /// `item` as a request: the stream and extras from its provider, the quality decision, the resume point.
    func firstPlayback(of item: MediaItem, fromBeginning: Bool, sourceID: String? = nil,
                       quality: StreamingQuality? = nil,
                       throughput: (kbps: Int, at: Date)? = nil) async throws -> IOSPlexPlaybackRequest {
        register([item])
        let playback = try await ProviderPlayback.prepare(
            item: item, provider: provider, version: sourceID.map(VersionChoice.source) ?? .best,
            quality: quality, throughput: throughput, fromBeginning: fromBeginning)
        let start = ProviderPlayback.startOffset(detailOffset: playback.detail.item.userState.viewOffset,
                                                 fromBeginning: fromBeginning)
        return try await request(from: playback, startTime: start, picks: nil)
    }

    func upNextPlayback(for item: PlexMetadata, quality: StreamingQuality?,
                        previous: IOSPlexPlaybackRequest?) async throws -> IOSPlexPlaybackRequest {
        guard let key = item.ratingKey else { throw MediaProviderError.notFound }
        // A downloaded episode plays its file, online or not.
        if let known = items[key], let local = IOSDownloadCenter.shared.localPlayback(for: known) { return local }
        let target: MediaItem
        if let known = items[key] {
            target = known
        } else {
            target = try await provider.fullDetail(for: MediaItemRef(providerID: provider.id, itemID: key)).item
        }
        let measured = previous?.freshMeasurement.flatMap { m in m.kbps.map { ($0, m.at) } }
        return try await firstPlayback(of: target, fromBeginning: false, quality: quality, throughput: measured)
    }

    func reloadedPlayback(of request: IOSPlexPlaybackRequest, quality: StreamingQuality, plan: StreamPlan?,
                          at time: TimeInterval, streams: TrackPicks?) async throws -> IOSPlexPlaybackRequest {
        guard let playback = request.providerPlayback else { throw MediaProviderError.notFound }
        if let silo = provider as? SiloProvider {
            var next = playback
            guard let stream = try await silo.replaceStream(
                for: playback.item.ref, current: playback.stream, sourceID: nil, position: time,
                maxBitrate: plan?.step.map { $0.kbps * 1000 },
                audioStreamIndex: streams?.audio,
                subtitleStreamIndex: streams?.subtitle?.providerStreamIndex,
                forceTranscode: false) else { throw MediaProviderError.notPlayable }
            next.stream = stream
            next.quality.choice = quality
            return try await self.request(from: next, startTime: time, picks: nil, previousStream: playback.stream)
        }
        let next = try await playback.reloaded(quality: quality, plan: plan, at: time, tracks: streams)
        return try await self.request(from: next, startTime: time > 1 ? time : nil, picks: streams)
    }

    func seekPlayback(_ request: IOSPlexPlaybackRequest, at time: TimeInterval) async throws -> IOSPlexPlaybackRequest? {
        guard var playback = request.providerPlayback,
              let stream = try await provider.seekStream(
                for: playback.item.ref, sourceID: playback.stream.source.id,
                playSessionID: playback.stream.playSessionID, position: time) else { return nil }
        playback.stream = stream
        return try await self.request(from: playback, startTime: time, picks: nil)
    }

    func nativeQualityPlayback(_ request: IOSPlexPlaybackRequest, quality: MediaQualityPreference,
                               at time: TimeInterval) async throws -> IOSPlexPlaybackRequest {
        guard var playback = request.providerPlayback, let silo = provider as? SiloProvider else {
            throw MediaProviderError.notPlayable
        }
        playback.stream = try await silo.restoreQuality(for: playback.item.ref, current: playback.stream,
                                                        position: time, quality: quality)
        playback.nativeRequestedQuality = quality
        return try await self.request(from: playback, startTime: time, picks: nil,
                                      previousStream: request.providerPlayback?.stream)
    }

    /// The player's request for `playback`. A transcode starts on the tracks the saved intents pick
    /// (`picks` when the player made a choice), since a provider burns or selects them at session start.
    private func request(from playback: ProviderPlayback, startTime: TimeInterval?,
                         picks: TrackPicks?, previousStream: StreamInfo? = nil) async throws -> IOSPlexPlaybackRequest {
        var playback = playback
        if let previousStream, let startTime,
           ProviderStreamTransition.between(previousStream, playback.stream) == .cuesOnly {
            // iOS remounts the selected sidecar with its source. An unchanged video plan's
            // original start anchor is not the current playhead.
            playback.stream.playerStartTime = max(0, startTime - playback.stream.timelineOffset)
        }
        var source = playback.stream.source
        var picks = picks
        let plan = playback.effectivePlan
        if plan != .original, playback.stream.negotiatedStatus == nil {
            if picks == nil {
                let shim = ProviderPlaybackMetadata.make(detail: playback.detail, source: source, extras: playback.extras)
                let streams = shim.Media?.first?.Part?.first?.Stream ?? []
                let wanted = TrackIntentResolver.startingPlexSelection(streams: streams)
                let audio = streams.first { $0.isAudio && $0.selected == true }?.id
                let subtitle = SubtitlePick(streams.first { $0.isSubtitle && $0.selected == true }?.id)
                if wanted.audio != audio || wanted.subtitle != subtitle {
                    playback = try await playback.reloaded(quality: playback.quality.choice, plan: plan,
                                                           at: startTime ?? 0, tracks: wanted)
                    source = playback.stream.source
                    picks = wanted
                }
            }
            if let picks { source = ProviderPlaybackMetadata.applying(picks, to: source) }
        }
        guard let url = source.streamURL else { throw MediaProviderError.notPlayable }
        register([playback.detail.item])
        let shim = ProviderPlaybackMetadata.make(detail: playback.detail, source: source, extras: playback.extras)
        let isTranscode = playback.stream.negotiatedStatus == nil && playback.stream.source.streamKind != .directPlay
        let sessionID = playback.stream.playSessionID
        let file = playback.detail.mediaSources.first { $0.id == source.id } ?? source
        return IOSPlexPlaybackRequest(
            item: shim,
            url: url,
            headers: playback.stream.headers,
            markers: shim.Marker ?? [],
            serverURL: "",
            token: "",
            quality: playback.quality.choice,
            plan: plan,
            sourceKbps: file.sourceKbps,
            mediaIndex: 0,
            transcodeSessionID: isTranscode ? sessionID : nil,
            measuredKbps: playback.quality.throughput?.kbps,
            measuredAt: playback.quality.throughput?.at,
            startTime: startTime,
            directPlaySessionID: isTranscode ? nil : sessionID,
            providerPlayback: playback
        )
    }

    // MARK: - Reporting

    @discardableResult
    func reportProgress(for request: IOSPlexPlaybackRequest, time: TimeInterval, state: String) async -> String? {
        // A downloaded file keeps its own resume point; the server hears at the end, or when it is back.
        if request.isLocal {
            IOSDownloadCenter.shared.noteProgress(for: request, offsetMs: Int(time * 1000), watched: false, persist: state != "playing")
            if state == "stopped", let key = request.item.ratingKey {
                IOSOfflineProgress.record(providerID: provider.id, itemID: key, offsetMs: Int(time * 1000),
                                          durationMs: request.item.duration, watched: false, at: Date())
            }
            return nil
        }
        guard let playback = request.providerPlayback else { return nil }
        if request.nativeStream != nil {
            let key = reportKey(request)
            if state == "stopped", !startedNativeSessions.contains(key) {
                await ledger.stop(key, make: { reporter(for: playback) }, fallback: time)
                return nil
            }
            startedNativeSessions.insert(key)
        }
        await ledger.report(reportKey(request), make: { reporter(for: playback) }, state: state, time: time)
        return nil
    }

    func openPlaySession(_ request: IOSPlexPlaybackRequest) async {
        // Native reservations are already open. Start reporting only once media actually plays.
        guard let playback = request.providerPlayback, request.nativeStream == nil else { return }
        await ledger.open(reportKey(request), make: { reporter(for: playback) }, position: request.startTime ?? 0)
    }

    /// Ends a replaced stream's session, direct play or transcode, at the last position it reported,
    /// so the server frees what it holds without moving the resume point.
    func stopTranscode(_ request: IOSPlexPlaybackRequest) async {
        guard let playback = request.providerPlayback else { return }
        await ledger.stop(reportKey(request), make: { reporter(for: playback) }, fallback: request.startTime ?? 0)
    }

    private func reporter(for playback: ProviderPlayback) -> any ProgressReporter {
        provider.progressReporter(for: playback.item.ref, sourceID: playback.stream.source.id,
                                  playSessionID: playback.stream.playSessionID)
    }

    /// One report per play session; a request with no session id is its own.
    private func reportKey(_ request: IOSPlexPlaybackRequest) -> String {
        request.providerPlayback?.stream.playSessionID ?? request.id
    }

    // MARK: - Items

    func markWatched(_ request: IOSPlexPlaybackRequest) async {
        if request.isLocal, let key = request.item.ratingKey {
            IOSDownloadCenter.shared.noteProgress(for: request, offsetMs: 0, watched: true, persist: true)
            let duration = request.item.duration
            IOSOfflineProgress.record(providerID: provider.id, itemID: key, offsetMs: duration ?? 0,
                                      durationMs: duration, watched: true, at: Date())
            return
        }
        guard let ref = request.providerPlayback?.item.ref else { return }
        try? await provider.markPlayed(ref)
    }

    func nextEpisode(after episode: PlexMetadata, in request: IOSPlexPlaybackRequest) async -> PlexMetadata? {
        guard let key = episode.ratingKey, let current = items[key] ?? request.providerPlayback?.detail.item,
              current.ref.itemID == key else { return nil }
        let result = await EpisodePicker.upNext(after: current, provider: provider)
        register(result.season + [result.next].compactMap { $0 })
        if let next = result.next { return ProviderPlaybackMetadata.listing(item: next) }
        // Offline, or the server has no more: the next episode that is on the device.
        let center = IOSDownloadCenter.shared
        guard let downloaded = DownloadRules.nextDownloaded(
            afterShow: current.grandparentRef?.itemID, season: current.seasonNumber ?? 0, episode: current.episodeNumber ?? 0,
            providerID: provider.id, in: center.visibleRecords) else { return nil }
        register([downloaded.item])
        return ProviderPlaybackMetadata.listing(item: downloaded.item)
    }

    /// The transcode reads its picks from the URL it was built with, so there is nothing to write.
    func selectStream(_ picks: TrackPicks, in request: IOSPlexPlaybackRequest) async {}

    func artworkURL(for item: PlexMetadata, kind: IOSPlexSession.ArtworkKind, width: Int, height: Int) -> URL? {
        guard let key = item.ratingKey, let known = items[key] else { return nil }
        let art: URL? = switch kind {
        case .poster: known.kind == .episode
            ? known.grandparentArtwork?.poster ?? known.artwork.poster : known.artwork.poster
        case .thumb: known.artwork.thumbnail ?? known.artwork.poster
        case .backdrop: known.artwork.backdrop ?? known.artwork.thumbnail
        }
        return art.map { provider.imageURL($0, width: width, height: height) }
    }

    /// Chapters carry no server image path in the shim.
    func imageURL(path: String?, width: Int, height: Int, serverID: String?) -> URL? { nil }

    /// After a stopped report and a scrobble: send what a download queued, then repaint.
    func watchStateDidChange() async {
        _ = await IOSOfflineProgress.flushProviders()
        await onWatchStateChange()
    }
}
