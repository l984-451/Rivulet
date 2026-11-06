// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlayback+Prepare.swift
//  Rivulet
//
//  Prepares provider items for playback: native negotiation or quality decision,
//  stream and extras. Both apps share the same preparation and reservation lifecycle.
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
                        awaitingExtras: Bool = true,
                        nativeQuality: MediaQualityPreference? = nil) async throws -> ProviderPlayback {
        guard item.isAvailable != false else { throw MediaProviderError.notPlayable }
        var reserved: StreamInfo?
        do {
            if let silo = provider as? SiloProvider {
                let detail = try await provider.fullDetail(for: item.ref)
                let sourceID = VersionRanking.choose(version, from: detail.mediaSources)?.id
                let account = await MainActor.run { SiloSession.account }
                let authority = SiloPlaybackAuthority(providerID: silo.id,
                    accountID: account?.userID ?? silo.profileID, profileID: silo.profileID)
                let seriesID = detail.item.grandparentRef?.itemID ?? item.grandparentRef?.itemID
                    ?? item.dismissalMetadata?.seriesID
                let libraryID = detail.item.libraryID ?? item.libraryID
                let context = SiloPlaybackOverrideContext(authority: authority,
                    libraryID: libraryID, seriesID: seriesID)
                let preferences = SiloPlaybackPreferences(provider: silo)
                let schema = try? await preferences.schema()
                let effective = schema == nil ? nil : (try? await preferences.effective(
                    libraryID: libraryID.flatMap(Int.init), seriesID: seriesID))
                let policy = await SiloPlaybackPolicyStore.shared.resolve(context: context, server: effective,
                    manualQuality: nativeQuality)
                let start = startOffset(detailOffset: detail.item.userState.viewOffset, fromBeginning: fromBeginning) ?? 0
                let stream = try await silo.resolveStream(for: item.ref, sourceID: sourceID, policy: policy,
                                                         startTime: start)
                reserved = stream
                try Task.checkCancellation()
                let extras = awaitingExtras
                    ? await provider.playbackExtras(for: item.ref, sourceID: stream.source.id) : PlaybackExtras()
                try Task.checkCancellation()
                var settled = ProviderQuality()
                settled.choice = .auto
                settled.plan = .original
                var playback = ProviderPlayback(provider: provider, item: item, detail: detail, stream: stream,
                                                extras: extras, quality: settled)
                playback.extrasPending = !awaitingExtras
                if case .value(let quality) = policy.quality { playback.nativeRequestedQuality = quality }
                else { playback.nativeRequestedQuality = .automatic }
                if case .value(let choice) = policy.bufferingPolicy { playback.nativeBufferingPolicy = choice }
                else { playback.nativeBufferingPolicy = .ask }
                return playback
            }
            let detail: MediaItemDetail
            var stream: StreamInfo
            if case .matchingTier = version {
                detail = try await provider.fullDetail(for: item.ref)
                let sourceID = VersionRanking.choose(version, from: detail.mediaSources)?.id
                stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
                reserved = stream
            } else {
                let sourceID: String?
                if case .source(let id) = version { sourceID = id } else { sourceID = nil }
                async let fetched = provider.fullDetail(for: item.ref)
                stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
                reserved = stream
                detail = try await fetched
            }
            try Task.checkCancellation()
            let decided = await decideQuality(quality, version: version, stream: stream,
                                              sources: detail.mediaSources, throughput: throughput)
            var settled = decided.quality
            if decided.quality.plan != .original || decided.sourceID != stream.source.id {
                do {
                    let start = startOffset(detailOffset: detail.item.userState.viewOffset, fromBeginning: fromBeginning) ?? 0
                    let replacement: StreamInfo
                    if let native = try await provider.replaceStream(
                        for: item.ref, current: stream,
                        sourceID: decided.sourceID == stream.source.id ? nil : decided.sourceID,
                        position: start,
                        maxBitrate: decided.quality.plan.step.map { $0.kbps * 1000 },
                        audioStreamIndex: nil, subtitleStreamIndex: nil, forceTranscode: false
                    ) {
                        replacement = native
                    } else {
                        replacement = try await provider.resolveStream(
                            for: item.ref, sourceID: decided.sourceID,
                            maxBitrate: decided.quality.plan.step.map { $0.kbps * 1000 }, startTime: start)
                    }
                    reserved = replacement
                    if replacement.playSessionID != stream.playSessionID {
                        await discardUnplayedStream(stream, provider: provider)
                    }
                    stream = replacement
                    if stream.source.streamKind == .directPlay { settled.plan = .original }
                } catch MediaProviderError.transcodeRequired {
                    // A server that won't transcode still plays the file it already offered.
                    settled.plan = .original
                }
            }
            let extras = awaitingExtras
                ? await provider.playbackExtras(for: item.ref, sourceID: stream.source.id) : PlaybackExtras()
            try Task.checkCancellation()
            var prepared = ProviderPlayback(provider: provider, item: item, detail: detail, stream: stream, extras: extras,
                                            quality: settled)
            prepared.extrasPending = !awaitingExtras
            return prepared
        } catch {
            if let reserved { await discardUnplayedStream(reserved, provider: provider) }
            throw error
        }
    }

    /// Runs independently of a cancelled preparation task so native reservations can close.
    static func discardUnplayedStream(_ stream: StreamInfo, provider: any MediaProvider) async {
        await Task {
            do { _ = try await provider.discardStream(stream) }
            catch { DiagLog.error(.playback, "Unplayed provider session cleanup failed: \(DiagLog.describe(error))") }
        }.value
    }

    /// The plan for an uncapped `stream`, and the version that should play under it.
    /// Probes the direct stream only when Auto has no measurement younger than 10 minutes.
    private static func decideQuality(
        _ quality: StreamingQuality?, version: VersionChoice, stream: StreamInfo, sources: [MediaSource],
        throughput: (kbps: Int, at: Date)?
    ) async -> (quality: ProviderQuality, sourceID: String) {
        let directURL = stream.source.streamKind == .directPlay ? stream.source.streamURL : nil
        var settled = ProviderQuality()
        settled.isHome = StreamingQuality.isHome(serverURL: (stream.upstreamURL ?? stream.source.streamURL)?.absoluteString ?? "")
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

