// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlaybackDiagnostics.swift
//  Rivulet
//
//  Causal-chain diagnostics for playback startup (see RIVULET-19).
//
//  Why this exists
//  ---------------
//  RIVULET-19 ("HLS transcode session failed to start") is the FALLBACK failing,
//  not the primary. The real bug is whatever made Aether fail first — but that
//  error was computed, classified, and then discarded, so every Sentry event
//  reported the symptom and destroyed the cause.
//
//  A playback startup is a sequence, not an event: route chosen -> Aether tried
//  -> Aether failed (why?) -> HLS fallback built -> preflight polled (what did
//  the server actually say?) -> failed. Any one of those steps can be the real
//  story. This type records the whole sequence and attaches it to whatever error
//  finally surfaces, so a single Sentry event is self-describing.
//
//  Everything here is a no-op when the SDK isn't running (DEBUG), so callers
//  never guard on build configuration.
//

import Foundation
import Sentry

/// Accumulates the full causal chain of a single playback startup attempt and
/// attaches it to any error captured for that attempt.
///
/// One instance per player session. Not thread-safe by design: it is only ever
/// touched from the player's main-actor-isolated view model.
@MainActor
final class PlaybackDiagnostics {

    /// Stable Sentry context block name. Lands as a dedicated section on the event.
    private static let contextKey = "playback"

    /// The media fingerprint: what we were trying to play, and with what streams.
    /// Set once at startup so every subsequent capture carries it.
    private var media: [String: Any] = [:]

    /// The startup story so far, in order. Each entry is one step.
    private var timeline: [String] = []

    /// The ORIGINAL failure, if the primary route already died. This is the
    /// value RIVULET-19 was throwing away.
    private var rootCause: [String: Any]?

    /// What the HLS preflight actually observed, attempt by attempt.
    private var preflightObservations: [String] = []

    /// Whether the source server is reachable only through Plex's relay (a
    /// bandwidth-capped tunnel). Relay sessions fail at Aether open with
    /// AVERROR_INVALIDDATA because the relay 500s raw part fetches; #211 now
    /// routes them to a capped HLS transcode instead. Surfaced as a low-
    /// cardinality TAG (not just context, which isn't searchable) so the relay
    /// share of RIVULET-19 is filterable and that fix's impact is measurable.
    private var isRelay = false
    /// Streaming quality in effect (`original`, `auto`, or a step's kbps) and home/away. Tags, never URLs.
    private var streamQuality: String?
    private var streamLocation: String?

    // MARK: - Media fingerprint

    /// Record what we're playing and how it's encoded. Called once per session,
    /// before the first load attempt.
    ///
    /// The codec/DV/audio fingerprint is the difference between "playback broke"
    /// and "playback breaks on DV P7 + TrueHD", which is an actionable bug.
    func setMedia(_ metadata: PlexMetadata, route: String, startOffset: TimeInterval?, isRelay: Bool = false,
                  quality: String? = nil, location: String? = nil) {
        self.isRelay = isRelay
        streamQuality = quality
        streamLocation = location

        let part = metadata.Media?.first?.Part?.first
        let streams = part?.Stream ?? []
        let video = streams.first { $0.isVideo }
        let audio = streams.first { $0.isAudio }

        media = [
            "route": route,
            "is_relay": isRelay,
            "stream_quality": quality ?? "unknown",
            "stream_location": location ?? "unknown",
            "title": metadata.title ?? "unknown",
            "type": metadata.type ?? "unknown",
            "rating_key": metadata.ratingKey ?? "unknown",
            "container": metadata.Media?.first?.container ?? "unknown",
            "video_codec": video?.codec ?? "unknown",
            "video_codec_id": video?.codecID ?? "unknown",
            "video_profile": video?.profile ?? "unknown",
            // Resolution + HDR + bitrate are the fields most correlated with
            // mid-playback stalls and hangs (a 4K HDR high-bitrate stream is a
            // different animal from a 1080p SDR one). Kept here so a startup
            // failure carries them; the coarse versions also go on the global
            // scope via AppHangContext.setContent so an App Hang is sliceable too.
            "video_resolution": metadata.Media?.first?.videoResolution ?? "unknown",
            "video_width": video?.width ?? -1,
            "video_height": video?.height ?? -1,
            "video_bitrate_kbps": video?.bitrate ?? -1,
            "video_framerate": video?.frameRate ?? -1,
            "video_color_trc": video?.colorTrc ?? "none",
            "is_hdr": video?.isHDR ?? false,
            "hdr_format": metadata.hdrFormatDisplay ?? "SDR",
            "audio_codec": audio?.codec ?? "unknown",
            "audio_channels": audio?.channels ?? -1,
            "has_dolby_vision": metadata.hasDolbyVision,
            "dv_profile": video?.DOVIProfile ?? -1,
            "dv_bl_compat_id": video?.DOVIBLCompatID ?? -1,
            "subtitle_stream_count": streams.filter { $0.isSubtitle }.count,
            // A resumed (seeked) start is materially harder on a Plex transcode
            // than a start at zero. RIVULET-19's sample was 58 minutes in.
            "start_offset": startOffset ?? 0,
            "is_resume": (startOffset ?? 0) > 1
        ]
        step("session_start", detail: route)
    }

    // MARK: - Timeline

    /// Append one step to the startup story. Also drops a breadcrumb so the
    /// sequence survives even on an event this instance never sees (an App Hang,
    /// or an OS-level crash mid-startup).
    func step(_ name: String, detail: String? = nil) {
        let entry = detail.map { "\(name): \($0)" } ?? name
        timeline.append(entry)

        let crumb = Breadcrumb(level: .info, category: "playback.startup")
        crumb.message = entry
        SentryBridge.addBreadcrumb(crumb)
    }

    // MARK: - Root cause

    /// Record the failure of the PRIMARY route before falling back.
    ///
    /// This is the whole point of the type. Without it, an Aether failure that
    /// is successfully papered over by the HLS fallback is invisible, and one
    /// that ISN'T gets reported as an HLS bug.
    /// - Parameter engineKind: AetherEngine's own `PlaybackErrorKind` raw
    ///   value, when the failure came from the engine. Sent as its own tag
    ///   rather than folded into `kind`: `DirectPlayFailureKind` has six
    ///   buckets chosen for fallback decisions, and collapsing twenty engine
    ///   kinds into them is exactly what made RIVULET-19 unsplittable.
    /// - Parameter engineUnderlying: domain and code beneath the engine's
    ///   error. For `sourceRefused` / `sourceRateLimited` the code is the
    ///   origin's HTTP status.
    func recordPrimaryFailure(_ error: Error,
                              kind: DirectPlayFailureKind,
                              route: String,
                              engineKind: String? = nil,
                              engineUnderlying: (domain: String?, code: Int?)? = nil) {
        let nsError = error as NSError
        rootCause = [
            "route": route,
            "kind": kind.rawValue,
            "engine_kind": engineKind ?? "none",
            "message": error.localizedDescription,
            "domain": nsError.domain,
            "code": nsError.code,
            "underlying": (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
                .map { "\($0.domain) code=\($0.code): \($0.localizedDescription)" } ?? "none"
        ]
        step("primary_failed", detail: "\(route)/\(kind.rawValue): \(error.localizedDescription)")

        // Capture the primary failure as its OWN event, right now, even if the
        // fallback goes on to succeed. A silently-rescued Aether failure is
        // still a bug we need to see — it's a direct-play miss for that user.
        SentryBridge.capture(error: error) { scope in
            scope.setLevel(.warning)
            scope.setTag(value: "playback", key: "component")
            scope.setTag(value: "primary_route_failed", key: "playback_event")
            scope.setTag(value: route, key: "failed_route")
            scope.setTag(value: kind.rawValue, key: "failure_kind")
            if let engineKind {
                scope.setTag(value: engineKind, key: "engine_failure_kind")
            }
            if let engineUnderlying {
                if let domain = engineUnderlying.domain {
                    scope.setTag(value: domain, key: "engine_underlying_domain")
                }
                if let code = engineUnderlying.code {
                    scope.setTag(value: String(code), key: "engine_underlying_code")
                }
            }
            self.apply(to: scope)
        }
    }

    // MARK: - Failure body probe (RIVULET-19)

    /// Record what the stream URL returned when the aether route failed to open
    /// it, and report it as a Sentry log.
    ///
    /// RIVULET-19 is AVERROR_INVALIDDATA at engine open: the demuxer read a byte
    /// stream and could not parse it as media. The open question is which
    /// non-media body dominates, and the aether route captured nothing about the
    /// response until now. `summary` and `classification` come from
    /// `StreamBodyClassifier`, which draws every value it emits from a fixed
    /// vocabulary and copies nothing out of the response body.
    ///
    /// A log, not an attachment to the event `recordPrimaryFailure` sends: that
    /// event is already in flight by the time a network probe could return, and
    /// a second error per failure only duplicated it. Count by `probe_body_class`
    /// in Explore > Logs.
    ///
    /// SECURITY: no URL and no body text is passed in or attached here. See
    /// `StreamBodyClassifier.describe` for why the body prefix is dropped
    /// entirely rather than redacted.
    func recordFailureBodyProbe(
        summary: String,
        classification: String,
        status: Int,
        error: Error,
        kind: DirectPlayFailureKind
    ) {
        step("aether_failure_body_probe", detail: summary)

        SentryBridge.log(.warn, "Aether failure body probe", attributes: [
            "component": "playback",
            "playback_event": "aether_failure_body_probe",
            "failed_route": "aether",
            "failure_kind": kind.rawValue,
            "probe_body_class": classification,
            "probe_http_status": status,
            "probe_summary": summary,
            "is_relay": isRelay,
            "error": String(describing: error),
            "rating_key": media["rating_key"] as? String ?? "unknown",
        ])
    }

    // MARK: - HLS preflight

    /// Record one poll of the Plex transcode manifest.
    ///
    /// RIVULET-19 fires when 8 of these fail in a row, but the event never said
    /// WHY: a 404 (transcode never started) and a 200-with-empty-manifest
    /// (transcoder started but is starving) are completely different bugs with
    /// completely different fixes.
    func recordPreflightAttempt(_ attempt: Int, outcome: String) {
        preflightObservations.append("#\(attempt) \(outcome)")
    }

    // MARK: - Capture

    /// Capture a playback error with the entire causal chain attached.
    func capture(_ error: Error, event: String, extraTags: [String: String] = [:]) {
        SentryBridge.capture(error: error) { scope in
            scope.setTag(value: "playback", key: "component")
            scope.setTag(value: event, key: "playback_event")
            // Surface the root cause as a TAG, not just context, so Sentry can
            // group and filter by it. "HLS preflight failed" is not searchable;
            // "HLS preflight failed BECAUSE Aether hit demuxInit" is.
            if let kind = self.rootCause?["kind"] as? String {
                scope.setTag(value: kind, key: "root_cause_kind")
            }
            for (key, value) in extraTags {
                scope.setTag(value: value, key: key)
            }
            self.apply(to: scope)
        }
    }

    /// Attach the accumulated chain to a scope.
    private func apply(to scope: Scope) {
        // Low-cardinality tag (unlike the context dict) so relay failures are
        // filterable in Sentry — the relay slice of RIVULET-19 and this cap's
        // impact both hang off `is_relay:true`.
        scope.setTag(value: isRelay ? "true" : "false", key: "is_relay")
        if let streamQuality { scope.setTag(value: streamQuality, key: "stream_quality") }
        if let streamLocation { scope.setTag(value: streamLocation, key: "stream_location") }

        var context = media
        context["timeline"] = timeline
        if let rootCause {
            context["root_cause"] = rootCause
        }
        if !preflightObservations.isEmpty {
            context["hls_preflight"] = preflightObservations
        }
        scope.setContext(value: context, key: Self.contextKey)
    }
}
