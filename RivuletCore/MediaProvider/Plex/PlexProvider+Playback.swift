// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProvider+Playback.swift
//  Rivulet
//
//  Plex through the playback seam: the direct-play stream, the server transcode
//  under a cap, the play session's reporter, and skip markers.
//  Never put a stream URL in a log: they carry the account token.
//

import Foundation
import os

/// What a handed-out stream needs later: its reporter opens the session and ends it.
struct PlexPlaySession: Sendable {
    let ratingKey: String
    /// The playing version's index in the server's Media order, which the transcoder calls `mediaIndex`.
    let mediaIndex: Int
    let durationMs: Int?
    /// Set for a transcode: the playlist and headers the decision request repeats.
    let transcode: (url: URL, headers: [String: String])?
    var createdAt = Date()
    var isTranscode: Bool { transcode != nil }
}

extension PlexProvider {

    // MARK: - Streams

    /// The chosen version as a direct-play file, or the server transcode when `maxBitrate`
    /// (bps) is below what the version needs. A nil cap never transcodes.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        try await resolveStream(for: itemRef, sourceID: sourceID, maxBitrate: maxBitrate, startTime: 0)
    }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?,
                       startTime: TimeInterval) async throws -> StreamInfo {
        let (meta, detail) = try await playableMetadata(itemRef)
        let capKbps = maxBitrate.map { $0 / 1000 }
        guard let chosen = VersionRanking.choose(sourceID.map(VersionChoice.source) ?? .best,
                                                 from: detail.mediaSources, capKbps: capKbps) else {
            throw MediaProviderError.notFound
        }
        if let capKbps, let kbps = chosen.sourceKbps, kbps > capKbps {
            return try await transcode(meta, chosen: chosen, startTime: startTime, maxBitrate: maxBitrate)
        }
        let session = UUID().uuidString
        remember(session, PlexPlaySession(ratingKey: itemRef.itemID, mediaIndex: mediaIndex(of: chosen, in: meta),
                                          durationMs: meta.duration, transcode: nil))
        return StreamInfo(source: chosen, playSessionID: session, trackInfoAvailable: true,
                          headers: Self.directPlayHeaders(token: authToken))
    }

    /// A server transcode from `startTime` at the top step under `maxBitrate`. The track picks
    /// are written to the part first, since Plex reads them when the session starts.
    /// The indices are Plex stream ids; subtitle -1 is off.
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval,
                         maxBitrate: Int?, audioStreamIndex: Int?, subtitleStreamIndex: Int?) async throws -> StreamInfo {
        let (meta, detail) = try await playableMetadata(itemRef)
        guard let chosen = VersionRanking.choose(sourceID.map(VersionChoice.source) ?? .best,
                                                 from: detail.mediaSources) else {
            throw MediaProviderError.notFound
        }
        if audioStreamIndex != nil || subtitleStreamIndex != nil,
           let part = meta.Media?.first(where: { "\($0.id)" == chosen.id })?.Part?.first?.id {
            if let audioStreamIndex {
                await networkManager.setSelectedAudioStream(
                    serverURL: serverURL, authToken: authToken, partId: part, audioStreamID: audioStreamIndex)
            }
            if let subtitleStreamIndex {
                await networkManager.setSelectedSubtitleStream(
                    serverURL: serverURL, authToken: authToken, partId: part,
                    subtitleStreamID: max(subtitleStreamIndex, 0))
            }
        }
        return try await transcode(meta, chosen: chosen, startTime: startTime, maxBitrate: maxBitrate)
    }

    private func transcode(_ meta: PlexMetadata, chosen: MediaSource, startTime: TimeInterval,
                           maxBitrate: Int?) async throws -> StreamInfo {
        let index = mediaIndex(of: chosen, in: meta)
        let step = QualityDecision.highestStep(atMost: maxBitrate.map { $0 / 1000 } ?? .max)
        guard let ratingKey = meta.ratingKey,
              let built = networkManager.buildHLSDirectPlayURL(
                serverURL: serverURL, authToken: authToken, ratingKey: ratingKey, mediaIndex: index,
                offsetMs: Int(startTime * 1000), useDolbyVision: false, forceVideoTranscode: true, step: step)
        else { throw MediaProviderError.notPlayable }
        let session = URLComponents(url: built.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "session" }?.value ?? UUID().uuidString
        remember(session, PlexPlaySession(ratingKey: ratingKey, mediaIndex: index, durationMs: meta.duration,
                                          transcode: (built.url, built.headers)))
        return StreamInfo(source: chosen.transcoded(to: built.url), playSessionID: session,
                          trackInfoAvailable: true, headers: built.headers)
    }

    /// Keeps the session for its reporter. Streams handed out and never reported (a probe's, a
    /// discarded prepare) are dropped after six hours, longer than any title plays.
    private func remember(_ id: String, _ session: PlexPlaySession) {
        playSessions.withLock {
            $0 = $0.filter { -$0.value.createdAt.timeIntervalSinceNow < 6 * 3600 }
            $0[id] = session
        }
    }

    private func playableMetadata(_ itemRef: MediaItemRef) async throws -> (PlexMetadata, MediaItemDetail) {
        let meta = try await plexCall {
            try await networkManager.getFullMetadata(serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID)
        }
        return (meta, PlexMediaMapper.detail(meta, providerID: id, serverURL: serverURL, authToken: authToken))
    }

    private func mediaIndex(of source: MediaSource, in meta: PlexMetadata) -> Int {
        meta.Media?.firstIndex { "\($0.id)" == source.id } ?? 0
    }

    /// Plex wants these on a direct-play fetch as well as the token in the URL.
    static func directPlayHeaders(token: String) -> [String: String] {
        [
            "X-Plex-Token": token,
            "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
            "X-Plex-Platform": PlexAPI.platform,
            "X-Plex-Product": PlexAPI.productName,
            "User-Agent": "\(PlexAPI.productName)/\(PlexAPI.platform)",
            "X-Playback-Session-Id": UUID().uuidString
        ]
    }

    // MARK: - Reports

    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter {
        PlexTimelineReporter(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: itemRef.itemID,
            networkManager: networkManager,
            playSessionID: playSessionID,
            session: playSessionID.flatMap { id in playSessions.withLock { $0[id] } },
            onEnd: { [weak self] in
                guard let playSessionID else { return }
                self?.playSessions.withLock { _ = $0.removeValue(forKey: playSessionID) }
            }
        )
    }

    // MARK: - Markers

    /// Plex's own markers, with IntroDB's for kinds Plex lacks when the user opted in.
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras {
        guard let meta = try? await networkManager.getFullMetadata(
            serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID) else { return PlaybackExtras() }
        let markers = await PlexPlaybackMarkers.markers(for: meta, serverURL: serverURL, token: authToken,
                                                        network: networkManager)
        return PlaybackExtras(markers: PlexPlaybackMarkers.playbackMarkers(markers))
    }
}

extension MediaSource {
    /// The same version, played as the transcode at `url`.
    func transcoded(to url: URL) -> MediaSource {
        MediaSource(id: id, container: container, duration: duration, bitrate: bitrate, fileSize: nil,
                    fileName: fileName, versionName: versionName, videoResolution: videoResolution,
                    videoTracks: videoTracks, audioTracks: audioTracks, subtitleTracks: subtitleTracks,
                    streamKind: .hlsTranscode, streamURL: url)
    }
}
