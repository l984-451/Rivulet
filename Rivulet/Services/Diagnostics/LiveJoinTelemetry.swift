// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Times a Live TV join to first frame, split into resolve (Plex tune and
// decision), engine load and first frame, as the Sentry `live.join` transaction.
// No URL leaves the device: Xtream paths embed credentials, so only categories are sent.
// Do not read `engine.diagnostics.liveTelemetry` here: it does sync XPC on main (AetherEngine#134).

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

    /// Every child span, so the transaction's tags can be copied onto them.
    private let spanLock = NSLock()
    private var allSpans: [any Span] = []

    /// Starts `tune` / `decision` child spans under `resolve`; install with
    /// `LiveResolveTiming.$begin.withValue` around the resolve call.
    var phaseHook: (@Sendable (String) -> (@Sendable () -> Void))? {
        guard let parent = resolveSpan else { return nil }
        return { [weak self] name in
            let span = parent.startChild(operation: name)
            self?.track(span)
            return { if !span.isFinished { span.finish() } }   // ended early and again in defer
        }
    }

    private func track(_ span: any Span) {
        spanLock.lock(); allSpans.append(span); spanLock.unlock()
    }

    init() {
        transaction = SentryBridge.startTransaction(name: "live.join", operation: "live.join")
        resolveSpan = transaction?.startChild(operation: "resolve")
        if let resolveSpan { track(resolveSpan) }
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
        if let loadSpan { track(loadSpan) }
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

    /// `loadLive` returned. What remains is the wait for the first frame on
    /// screen: on the software path, the first decodable picture (#323).
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
        if let firstFrameSpan { track(firstFrameSpan) }
    }

    /// First frame on screen after the load. The join is complete. The codec is
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
        // Child spans carry the transaction's tags so they filter by route.
        if let tags = transaction?.tags {
            spanLock.lock(); let spans = allSpans; spanLock.unlock()
            for span in spans { for (key, value) in tags { span.setTag(value: value, key: key) } }
        }
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
