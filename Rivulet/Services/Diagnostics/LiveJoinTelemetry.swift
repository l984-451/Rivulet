// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveJoinTelemetry.swift
//  Rivulet
//
//  Measures how long a Live TV channel takes to reach first frame, split into
//  the phases that actually compose it, and reports them as a Sentry
//  performance transaction.
//
//  WHY THIS EXISTS
//  ---------------
//  AetherEngine 5.19.0 added `LoadOptions.liveJoinProfile = .fastZap`, which
//  shrinks the loopback's TARGETDURATION so the RFC 8216bis live-edge holdback
//  (>= 3 x TARGETDURATION) the first manifest waits on shrinks with it. Upstream
//  measured first frame at +2.0s with it vs +20.0s without, on a strict-realtime
//  origin with a 1s GOP.
//
//  Whether that helps Rivulet depends on two things nobody has measured:
//    1. WHICH ROUTE a channel takes. `liveJoinProfile` is read at exactly one
//       place in the engine (building the loopback segment producer) and is
//       inert on `nativeRemoteHLS`, where AVPlayer talks to the origin directly.
//    2. WHICH PHASE actually dominates. Join time is serial: the Plex tune +
//       decision handshake, then the engine's demux probe (this app allows a 5MB
//       / 5s budget), then the holdback fill. `.fastZap` only addresses the last
//       one.
//
//  So we measure the split and infer, because the engine does NOT expose
//  TARGETDURATION or GOP: a loopback p50 near 18-20s means the holdback
//  dominates and `.fastZap` has real headroom; near 8s means handshake and probe
//  dominate and it does not.
//
//  TWO HARD CONSTRAINTS
//  --------------------
//  - NO URLs LEAVE THE DEVICE. Xtream-style IPTV stream URLs embed credentials
//    in the path (`/live/user/pass/id.ts`). Only derived categorical values are
//    sent: route, source kind, outcome, bucketed duration.
//  - HOST-SIDE WALL CLOCK ONLY. Never enrich these spans from
//    `engine.diagnostics.liveTelemetry`: that sampler does synchronous XPC on the
//    main thread and is the known cause of this app's hangs (AetherEngine#134).
//    It carries no TARGETDURATION anyway, so it would buy a hang risk for
//    nothing.
//

import Foundation
import Sentry

/// One live-join measurement. Created per load attempt and owned by the
/// presenting view controller; a fallback that retries a different URL starts a
/// fresh instance so each attempt is measured on its own.
final class LiveJoinTelemetry {
    private let transaction: (any Span)?
    private let startedAt = Date()

    private var resolveSpan: (any Span)?
    private var loadSpan: (any Span)?
    private var firstFrameSpan: (any Span)?

    /// Finishing is idempotent. The `.playing` sink fires on every resume, not
    /// just the first frame, and the teardown paths overlap with the failure
    /// paths, so every terminal call funnels through this flag.
    private var isFinished = false

    init() {
        transaction = SentryBridge.startTransaction(name: "live.join", operation: "live.join")
        resolveSpan = transaction?.startChild(operation: "resolve")
    }

    /// The Plex tune + decision handshake finished (or passed straight through
    /// for sources that carry a direct stream URL).
    ///
    /// The URL is INSPECTED here and never stored or sent. Keeping the
    /// derivation inside this type is what enforces that: callers hand over the
    /// URL and only a category can come back out.
    func resolveFinished(url: URL, route: LiveJoinRoute) {
        resolveSpan?.finish()
        resolveSpan = nil
        transaction?.setTag(value: route.rawValue, key: "live.route")
        transaction?.setTag(value: Self.sourceKind(for: url), key: "live.source")
        transaction?.setTag(value: Self.scanKind(for: url), key: "live.scan")
        loadSpan = transaction?.startChild(operation: "engine_load")
    }

    /// Categorises the stream source by URL SHAPE only. Never returns any part
    /// of the URL itself: Xtream IPTV paths carry `/live/user/pass/` and Plex
    /// URLs carry tokens.
    nonisolated static func sourceKind(for url: URL) -> String {
        let path = url.path
        if path.hasPrefix("/livetv/sessions/") { return "plex_tuned" }
        if path.contains("/video/:/transcode/universal") { return "plex_transcode" }
        if url.pathExtension.lowercased() == "m3u8" { return "hls" }
        return "raw_stream"
    }

    /// The scan type PMS reported on the tune: `progressive`, `interlaced`, or
    /// `none` when the source carries none (every non-Plex channel). Anything
    /// but progressive counts as interlaced, as in `needsDeinterlacing`.
    nonisolated static func scanKind(for url: URL) -> String {
        guard let scan = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "rivuletLiveScanType" })?.value else { return "none" }
        return scan.lowercased() == "progressive" ? "progressive" : "interlaced"
    }

    /// `loadLive` returned. What remains until `.playing` is the engine's
    /// startup gate: on the loopback that is the live-edge holdback fill.
    /// `videoRoute` is the decode path the engine chose, so a join can be
    /// matched to it (issue #319).
    func loadFinished(videoRoute: String) {
        if let transaction {
            transaction.setTag(value: videoRoute, key: "live.video_route")
            LiveAudioRoute.current().record(on: transaction)
        }
        loadSpan?.finish()
        loadSpan = nil
        firstFrameSpan = transaction?.startChild(operation: "first_frame")
    }

    /// First `.playing` after the load. The join is complete. The codec is
    /// read here, not at load: on the remote-HLS bypass the engine learns it
    /// only once AVPlayer has the stream.
    func joined(codec: String?) {
        if let codec { transaction?.setTag(value: codec, key: "live.codec") }
        finish(outcome: "joined", status: .ok)
    }

    func failed(reason: String) {
        transaction?.setTag(value: reason, key: "live.failure")
        finish(outcome: "failed", status: .internalError)
    }

    /// User navigated away, or the load task was cancelled, before first frame.
    /// Recorded rather than dropped: abandons concentrated in one route are
    /// themselves evidence that joins are too slow.
    func abandoned() {
        finish(outcome: "abandoned", status: .cancelled)
    }

    private func finish(outcome: String, status: SentrySpanStatus) {
        guard !isFinished else { return }
        isFinished = true

        resolveSpan?.finish()
        loadSpan?.finish()
        firstFrameSpan?.finish()
        resolveSpan = nil
        loadSpan = nil
        firstFrameSpan = nil

        let elapsed = Date().timeIntervalSince(startedAt)
        transaction?.setTag(value: outcome, key: "live.outcome")
        // Bucketed as a tag as well as timed as a transaction, so the split is
        // still filterable from the Issues side without a Performance query.
        transaction?.setTag(value: Self.bucket(elapsed), key: "live.join_bucket")
        transaction?.finish(status: status)
    }

    /// Buckets chosen around the decision, not around round numbers: `.standard`
    /// forces TARGETDURATION >= 6 and therefore a holdback >= 18s, so anything
    /// landing in `20_plus` is the holdback, and `0_3` / `3_6` are joins
    /// `.fastZap` could not meaningfully improve.
    private static func bucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3: return "0_3"
        case ..<6: return "3_6"
        case ..<12: return "6_12"
        case ..<20: return "12_20"
        default: return "20_plus"
        }
    }
}

/// Which playback path the engine takes for this channel. Decided by
/// `AetherPlayer.liveRoute(for:forceEngineDemux:)` so it can never drift from
/// the routing the player actually performs.
enum LiveJoinRoute: String {
    /// Engine demuxes and serves a local HLS loopback. `liveJoinProfile`
    /// (and therefore `.fastZap`) applies ONLY here.
    case loopback
    /// AVPlayer is handed the remote URL directly. `liveJoinProfile` is inert.
    case nativeHLS = "native_hls"
}
