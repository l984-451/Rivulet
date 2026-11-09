// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlayback+Prepare.swift
//  Rivulet
//
//  Prepares any provider item for playback: quality decision, stream, extras.
//  Nothing in it knows which backend it is talking to; both apps share it.
//

import Foundation

extension ProviderPlayback {
    /// Everything the player needs for `item`, fetched from its provider. The
    /// detail and the stream run concurrently unless a tier match needs the
    /// version list first; the extras wait for the stream so they ask about
    /// the source that will actually play. `quality` is the player session's
    /// pick; nil follows the Home or Away setting. A capped transcode starts at the resume point
    /// (zero from the beginning). `awaitingExtras: false` returns before the markers are fetched,
    /// for a caller that applies them when they arrive.
    static func prepare(item: MediaItem, provider: any MediaProvider,
                        version: VersionChoice = .best, quality: StreamingQuality? = nil,
                        throughput: (kbps: Int, at: Date)? = nil, fromBeginning: Bool = false,
                        explicitStartOffset: TimeInterval? = nil,
                        awaitingExtras: Bool = true) async throws -> ProviderPlayback {
        let detail: MediaItemDetail
        var stream: StreamInfo
        if case .matchingTier = version {
            detail = try await provider.fullDetail(for: item.ref)
            let sourceID = VersionRanking.choose(version, from: detail.mediaSources)?.id
            stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
        } else {
            let sourceID: String?
            if case .source(let id) = version { sourceID = id } else { sourceID = nil }
            async let fetched = provider.fullDetail(for: item.ref)
            stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
            detail = try await fetched
        }
        let decided = await decideQuality(quality, version: version, stream: stream,
                                          sources: detail.mediaSources, throughput: throughput)
        var settled = decided.quality
        if decided.quality.plan != .original || decided.sourceID != stream.source.id {
            do {
                let start = explicitStartOffset
                    ?? startOffset(detailOffset: detail.item.userState.viewOffset, fromBeginning: fromBeginning)
                stream = try await provider.resolveStream(for: item.ref, sourceID: decided.sourceID,
                                                          maxBitrate: decided.quality.plan.step.map { $0.kbps * 1000 },
                                                          startTime: start ?? 0)
                // The server found it fits after all.
                if stream.source.streamKind == .directPlay { settled.plan = .original }
            } catch MediaProviderError.transcodeRequired {
                // A server that won't transcode still plays the file it already offered.
                settled.plan = .original
            }
        }
        let extras = awaitingExtras
            ? await provider.playbackExtras(for: item.ref, sourceID: stream.source.id) : PlaybackExtras()
        var prepared = ProviderPlayback(provider: provider, item: item, detail: detail, stream: stream, extras: extras,
                                        quality: settled)
        prepared.extrasPending = !awaitingExtras
        return prepared
    }

    /// The plan for an uncapped `stream`, and the version that should play under it.
    /// Probes the direct stream only when Auto has no measurement younger than 10 minutes.
    private static func decideQuality(
        _ quality: StreamingQuality?, version: VersionChoice, stream: StreamInfo, sources: [MediaSource],
        throughput: (kbps: Int, at: Date)?
    ) async -> (quality: ProviderQuality, sourceID: String) {
        let directURL = stream.source.streamKind == .directPlay ? stream.source.streamURL : nil
        var settled = ProviderQuality()
        settled.isHome = StreamingQuality.isHome(serverURL: stream.source.streamURL?.absoluteString ?? "")
        settled.choice = quality ?? StreamingQuality.setting(home: settled.isHome)
        settled.probeURL = directURL
        if QualityDecision.needsProbe(setting: settled.choice, isRelay: false) {
            settled.throughput = await measure(directURL, reusing: throughput)
        }
        let measured = settled.throughput?.kbps
        let cap = QualityDecision.capKbps(setting: settled.choice, measuredKbps: measured, isRelay: false)
        let sourceID = cap.flatMap { VersionRanking.choose(version, from: sources, capKbps: $0)?.id } ?? stream.source.id
        let source = sources.first { $0.id == sourceID } ?? stream.source
        settled.plan = QualityDecision.decide(setting: settled.choice, sourceKbps: source.sourceKbps,
                                              measuredKbps: measured, isRelay: false)
        return (settled, sourceID)
    }

    /// `last` while it is younger than 10 minutes, else a fresh probe of `url`; nil when that fails.
    static func measure(_ url: URL?, reusing last: (kbps: Int, at: Date)?) async -> (kbps: Int, at: Date)? {
        if let last, Date().timeIntervalSince(last.at) < 600 { return last }
        guard let url, let kbps = await ThroughputProbe.measure(url: url) else { return nil }
        return (kbps, Date())
    }
}

extension MediaSource {
    /// Container bitrate in kbps, or size over duration when the provider omits it.
    var sourceKbps: Int? {
        if let bitrate, bitrate > 0 { return bitrate / 1000 }
        guard let fileSize, duration > 0 else { return nil }
        return Int(Double(fileSize) * 8 / duration / 1000)
    }
}

