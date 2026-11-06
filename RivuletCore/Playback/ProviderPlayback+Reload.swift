// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlayback+Reload.swift
//  Rivulet
//
//  The playing provider stream again: a new quality, a track change on a
//  transcode, a fallback. Each is a new play session on the same version.
//

import Foundation

extension ProviderPlayback {
    /// Where playback starts: the server's resume point unless the user chose the beginning.
    /// Zero means no resume point.
    static func startOffset(detailOffset: TimeInterval, fromBeginning: Bool) -> TimeInterval? {
        fromBeginning || detailOffset <= 0 ? nil : detailOffset
    }

    /// What the stream plays as. A transcode the server picked itself (it would not direct play)
    /// reads as the top step under the file's bitrate, so the player treats it as one.
    var effectivePlan: StreamPlan {
        if quality.plan != .original || stream.source.streamKind == .directPlay { return quality.plan }
        return .transcode(QualityDecision.highestStep(atMost: stream.source.sourceKbps ?? 8000))
    }

    /// The same version as a new play session. `plan` nil decides from `quality`; a transcode
    /// starts at `time` on `tracks` (a provider's own stream ids), and a server
    /// that won't transcode plays the file.
    func reloaded(quality choice: StreamingQuality, plan forced: StreamPlan?, at time: TimeInterval,
                  tracks: TrackPicks? = nil) async throws -> ProviderPlayback {
        var next = self
        let sourceID = stream.source.id
        var settled = quality
        settled.choice = choice
        let plan: StreamPlan
        if let forced {
            plan = forced
        } else {
            if QualityDecision.needsProbe(setting: choice, isRelay: false) {
                settled.throughput = await Self.measure(settled.probeURL, reusing: settled.throughput)
            }
            let file = detail.mediaSources.first { $0.id == sourceID } ?? stream.source
            plan = QualityDecision.decide(setting: choice, sourceKbps: file.sourceKbps,
                                          measuredKbps: settled.throughput?.kbps, isRelay: false)
        }
        settled.plan = plan
        switch plan {
        case .original:
            next.stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
        case .transcode(let step):
            do {
                next.stream = try await provider.transcodeStream(
                    for: item.ref, sourceID: sourceID, startTime: time, maxBitrate: step.kbps * 1000,
                    audioStreamIndex: tracks?.audio, subtitleStreamIndex: tracks?.subtitle?.providerStreamIndex)
            } catch MediaProviderError.transcodeRequired {
                settled.plan = .original
                next.stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
            }
        }
        next.quality = settled
        return next
    }
}

extension ProviderPlayback {
    enum Route: Equatable {
        /// The Plex session: downloads, offline progress, the dashboard's session.
        case plexSession
        case provider
    }

    /// How a host plays an item from `provider`. Plex items need the host's Plex session, and
    /// without one the play fails rather than running Plex through the generic path.
    static func route(for provider: any MediaProvider, hasPlexSession: Bool) throws -> Route {
        guard provider is PlexProvider else { return .provider }
        guard hasPlexSession else { throw MediaProviderError.unreachable }
        return .plexSession
    }
}
