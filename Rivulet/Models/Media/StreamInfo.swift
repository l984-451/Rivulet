// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StreamInfo.swift
//  Rivulet
//
//  Result of provider.resolveStream(for:sourceID:). The chosen MediaSource
//  with streamURL materialized, plus per-session metadata for progress
//  reporting.
//

import Foundation

/// A provider plan has already decided the subtitle choice, including Off.
/// Player preference code must not replace it with a device-wide default.
enum AuthoritativeSubtitleSelection: Sendable, Equatable {
    case off
    case track(id: String, index: Int)
}

struct StreamInfo: Sendable {
    let source: MediaSource
    let playSessionID: String?
    /// false during HLS transcode where tracks come from the manifest, not from MediaSource fields.
    let trackInfoAvailable: Bool
    /// Ephemeral, plan-scoped transport headers supplied by the owning provider.
    var httpHeaders: [String: String] = [:]
    /// Original delivery location, before any loopback transport, for Home/Away policy.
    var upstreamURL: URL? = nil
    /// The player timeline position supplied by a negotiated playback plan.
    var playerStartTime: TimeInterval? = nil
    /// Source position = player position + this offset for reanchored deliveries.
    var timelineOffset: TimeInterval = 0
    /// False when seeking requires a new provider plan rather than a local player seek.
    var canSeekAnywhere: Bool = true
    /// Uses the existing engine host for sidecar subtitles on negotiated HLS as well as files.
    var prefersAetherPlayback: Bool = false
    /// False when track changes must negotiate the server's desired-track state.
    var canSelectTracksLocally: Bool = true
    /// Native plan facts; nil for older servers and providers without negotiation.
    var negotiatedStatus: MediaNegotiatedStatus? = nil
    /// Non-nil for a provider that owns the initial subtitle decision.
    var authoritativeSubtitleSelection: AuthoritativeSubtitleSelection? = nil
    /// Provider-owned canonical transport, before relay URL rewriting. A new
    /// plan ID alone does not mean the video changed.
    var videoTransport: ProviderVideoTransport? = nil
    var subtitleDelivery: ProviderSubtitleDelivery? = nil
}

/// Ephemeral transport authority: never persist or log its URL/headers.
struct ProviderVideoTransport: Sendable, Equatable {
    let url: URL
    let headers: [String: String]
    let delivery: MediaDelivery
    let container: String?
    let recipe: MediaEffectiveRecipe?
    let qualityID: String?
    let audioID: String?
}

enum ProviderSubtitleDelivery: Sendable, Equatable {
    case off, embedded, sidecar, hlsRendition, video

    var canReplaceCues: Bool {
        switch self {
        case .off, .embedded, .sidecar: true
        case .hlsRendition, .video: false
        }
    }
}

enum ProviderStreamTransition: Equatable {
    case cuesOnly, reloadPreservingDisplay, reload

    static func between(_ previous: StreamInfo, _ next: StreamInfo) -> Self {
        guard previous.prefersAetherPlayback, next.prefersAetherPlayback,
              let session = previous.playSessionID, session == next.playSessionID,
              previous.source.id == next.source.id,
              let old = previous.videoTransport, let new = next.videoTransport,
              old.delivery == new.delivery, old.container == new.container else { return .reload }
        // Burn-in can change the actual video recipe even when optional server
        // recipe fields are absent. Never carry an old HDR decision through it.
        guard let oldSubtitles = previous.subtitleDelivery, let newSubtitles = next.subtitleDelivery,
              oldSubtitles != .video, newSubtitles != .video else { return .reload }
        let sameVideo: Bool
        switch new.delivery {
        case .original, .progressiveRemux, .hlsRemux:
            sameVideo = old.recipe == new.recipe && old.qualityID == new.qualityID
        case .hlsTranscode:
            sameVideo = new.recipe?.videoCodec != nil && new.recipe?.dynamicRange != nil &&
                old.recipe == new.recipe && old.qualityID == new.qualityID
        case .other:
            sameVideo = false
        }
        guard sameVideo else { return .reload }
        if old == new, newSubtitles.canReplaceCues,
           previous.timelineOffset == next.timelineOffset,
           previous.canSeekAnywhere == next.canSeekAnywhere {
            return .cuesOnly
        }
        return .reloadPreservingDisplay
    }
}
