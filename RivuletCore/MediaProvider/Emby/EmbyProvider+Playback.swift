// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyProvider+Playback.swift
//  Rivulet
//
//  PlaybackInfo, the direct-play and hls streams, progress reports and skip markers.
//  Never put a PlaybackInfo body or a stream URL in a log: they carry the user's token.
//

import Foundation
import os

extension EmbyProvider {

    // MARK: - Skip markers

    /// The item's own `Chapters` (the source's copy is missing on 4.8). Empty is normal.
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras {
        guard let item: EmbyItem = try? await client.get("\(itemsPath)/\(itemRef.itemID)") else { return PlaybackExtras() }
        return PlaybackExtras(markers: EmbyMediaMapper.markers(item.chapters ?? [], runtime: EmbyTicks.seconds(item.runTimeTicks)))
    }

    // MARK: - Streams

    /// Direct play when the server says `SupportsDirectPlay` (never judged by `DirectStreamUrl`, which
    /// is set even when it is false), else the hls transcode. A cap below the file's bitrate is
    /// the server refusing direct play, so it lands in the transcode.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        try await resolveStream(for: itemRef, sourceID: sourceID, maxBitrate: maxBitrate, startTime: 0)
    }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?,
                       startTime: TimeInterval) async throws -> StreamInfo {
        let response = try await playbackInfo(itemRef, sourceID: sourceID, direct: true, maxBitrate: maxBitrate)
        let chosen = try choose(from: response, itemRef: itemRef, sourceID: sourceID, maxBitrate: maxBitrate)
        guard chosen.supportsDirectPlay == true else {
            return try await transcodeStream(for: itemRef, sourceID: chosen.id, startTime: startTime, maxBitrate: maxBitrate,
                                             audioStreamIndex: nil, subtitleStreamIndex: nil)
        }
        guard let source = EmbyMediaMapper.mediaSource(
            chosen, itemID: itemRef.itemID, playSessionID: response.playSessionId, baseURL: baseURL, token: client.token
        ) else { throw MediaProviderError.notPlayable }
        return StreamInfo(source: source, playSessionID: response.playSessionId, trackInfoAvailable: true)
    }

    /// H.264 in TS over HLS from `startTime`, a chosen subtitle burned in. A non-H.264 source asks
    /// again with video copy off, since AVPlayer never played the HEVC-in-TS the server copies.
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval,
                         maxBitrate: Int?, audioStreamIndex: Int?, subtitleStreamIndex: Int?) async throws -> StreamInfo {
        func ask(_ source: String?, copy: Bool?) async throws -> (EmbyPlaybackInfoResponse, EmbyMediaSource) {
            let response = try await playbackInfo(
                itemRef, sourceID: source, direct: false, startTime: startTime, maxBitrate: maxBitrate,
                audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex, allowVideoStreamCopy: copy
            )
            return (response, try choose(from: response, itemRef: itemRef, sourceID: source, maxBitrate: maxBitrate))
        }
        var (response, chosen) = try await ask(sourceID, copy: nil)
        let codec = chosen.mediaStreams?.first { $0.type == "Video" }?.codec
        if codec?.lowercased() != "h264" { (response, chosen) = try await ask(chosen.id, copy: false) }

        guard let path = chosen.transcodingUrl, let url = client.resolve(path) else { throw MediaProviderError.transcodeRequired }
        if let id = response.playSessionId {
            let device: String
            if let found = Self.queryValue("DeviceId", in: url) { device = found } else { device = await client.deviceID }
            transcodeSessions.withLock { $0[id] = device }
        }
        guard let source = EmbyMediaMapper.mediaSource(
            chosen, itemID: itemRef.itemID, playSessionID: response.playSessionId, baseURL: baseURL, token: client.token,
            transcodeURL: url
        ) else { throw MediaProviderError.notPlayable }
        return StreamInfo(source: source, playSessionID: response.playSessionId, trackInfoAvailable: true)
    }

    private func playbackInfo(
        _ itemRef: MediaItemRef, sourceID: String?, direct: Bool, startTime: TimeInterval = 0, maxBitrate: Int?,
        audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil, allowVideoStreamCopy: Bool? = nil
    ) async throws -> EmbyPlaybackInfoResponse {
        let response: EmbyPlaybackInfoResponse = try await client.post(
            "Items/\(itemRef.itemID)/PlaybackInfo",
            body: EmbyPlaybackInfoRequest.playback(
                userId: userID, mediaSourceId: sourceID, allowDirectPlay: direct,
                startTimeTicks: startTime > 0 ? EmbyTicks.ticks(startTime) : nil,
                maxStreamingBitrate: maxBitrate,
                audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex,
                allowVideoStreamCopy: allowVideoStreamCopy
            )
        )
        // A bad `MediaSourceId` is a 200 with no sources and `ErrorCode: NoCompatibleStream`.
        guard !(response.mediaSources ?? []).isEmpty else { throw MediaProviderError.notPlayable }
        return response
    }

    /// The version that plays, by `VersionRanking` under the cap. The id is the server's and opaque.
    private func choose(
        from response: EmbyPlaybackInfoResponse, itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?
    ) throws -> EmbyMediaSource {
        let sources = response.mediaSources ?? []
        let ranked = sources.compactMap {
            EmbyMediaMapper.mediaSource($0, itemID: itemRef.itemID, playSessionID: nil, baseURL: baseURL, token: nil)
        }
        guard let id = VersionRanking.choose(sourceID.map(VersionChoice.source) ?? .best, from: ranked,
                                             capKbps: maxBitrate.map { $0 / 1000 })?.id,
              let chosen = sources.first(where: { $0.id == id })
        else { throw MediaProviderError.notPlayable }
        return chosen
    }

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - Reports

    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter {
        EmbyProgressReporter(
            client: client, itemID: itemRef.itemID, mediaSourceID: sourceID, playSessionID: playSessionID,
            transcodeDeviceID: playSessionID.flatMap { id in transcodeSessions.withLock { $0[id] } }
        )
    }

    // MARK: - Track selection

    /// The engine selects tracks; Emby keeps no per-item pick for a client to set.
    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {}
    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {}
}

/// `Sessions/Playing*` for one playback. Emby writes the resume point and the played flag from
/// these (stopping past 90% marks the item played), so they are the whole watch-state story
/// while playing. A report with no PlaySessionId is dropped: `Playing` is a 400 without one,
/// and a `Stopped` that does not match its `Playing` changes nothing.
struct EmbyProgressReporter: ProgressReporter {
    let client: EmbyClient
    let itemID: String
    let mediaSourceID: String?
    let playSessionID: String?
    /// Set for an hls transcode: the device its encode runs under, so `stopped` can end it.
    let transcodeDeviceID: String?

    private func report(_ position: TimeInterval, paused: Bool) -> EmbyPlaybackReport? {
        guard let playSessionID else { return nil }
        return EmbyPlaybackReport(
            itemId: itemID, mediaSourceId: mediaSourceID, playSessionId: playSessionID,
            positionTicks: EmbyTicks.ticks(position), isPaused: paused,
            canSeek: true, playMethod: transcodeDeviceID == nil ? "DirectPlay" : "Transcode"
        )
    }

    private func send(_ path: String, _ position: TimeInterval, paused: Bool) async {
        guard let body = report(position, paused: paused) else { return }
        try? await client.post(path, body: body)
    }

    func start(position: TimeInterval) async {
        await send("Sessions/Playing", position, paused: false)
    }

    func progress(position: TimeInterval) async {
        await send("Sessions/Playing/Progress", position, paused: false)
    }

    func paused(at position: TimeInterval) async {
        await send("Sessions/Playing/Progress", position, paused: true)
    }

    func stopped(at position: TimeInterval) async {
        await send("Sessions/Playing/Stopped", position, paused: false)
        // The server reaps an idle encode after minutes; this frees it now. Both parameters are
        // needed: with either missing it answers 204 and stops nothing.
        guard let transcodeDeviceID, let playSessionID else { return }
        try? await client.delete("Videos/ActiveEncodings", query: [
            URLQueryItem(name: "DeviceId", value: transcodeDeviceID),
            URLQueryItem(name: "PlaySessionId", value: playSessionID)
        ])
    }
}
