// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Records each playback startup's chain (route, Aether failure, HLS fallback, preflight)
// and attaches it to the error that surfaces, so one Sentry event carries the cause (RIVULET-19).
// No-op when Sentry is not running.

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

    /// The primary route's failure, if it already died.
    private var rootCause: [String: Any]?

    /// What the HLS preflight actually observed, attempt by attempt.
    private var preflightObservations: [String] = []

    /// The server is reachable only through Plex's relay, which 500s raw part fetches,
    /// so these sessions go to a capped HLS transcode (#211).
    private var isRelay = false
    /// Streaming quality in effect (`original`, `auto`, or a step's kbps) and home/away. Tags, never URLs.
    private var streamQuality: String?
    private var streamLocation: String?

    // MARK: - Media fingerprint

    /// Records what is playing and how it is encoded. Called once per session,
    /// before the first load attempt.
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
            // Resolution, HDR and bitrate correlate most with stalls; coarse copies
            // also go on the global scope through AppHangContext.setContent.
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
            // A resumed start is harder on a Plex transcode than one at zero.
            "start_offset": startOffset ?? 0,
            "is_resume": (startOffset ?? 0) > 1
        ]
        let fingerprint = ["type", "rating_key", "container", "video_codec", "video_profile", "video_resolution",
                           "video_bitrate_kbps", "video_framerate", "hdr_format", "dv_profile", "audio_codec",
                           "audio_channels", "subtitle_stream_count", "stream_quality", "stream_location", "is_relay"]
            .map { "\($0)=\(media[$0].map { "\($0)" } ?? "?")" }.joined(separator: " ")
        DiagLog.notice(.playback, "Session \(route) offset=\(Int(startOffset ?? 0)) \(fingerprint)")
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

    /// Records the primary route's failure before the fallback, and sends it as its own event
    /// even if the fallback succeeds. `engineKind` is the engine's raw `PlaybackErrorKind`, kept
    /// apart from the six-bucket `kind`. For `sourceRefused` / `sourceRateLimited`,
    /// `engineUnderlying.code` is the origin's HTTP status.
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

    /// Logs what the stream URL returned when the aether route failed to open it
    /// (RIVULET-19, AVERROR_INVALIDDATA). A log because the primary-failure event is already sent;
    /// count by `probe_body_class`. Values come from `StreamBodyClassifier`: no URL, no body text.
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

    /// Records one poll of the Plex transcode manifest: a 404 (never started) and an
    /// empty 200 (starving) are different bugs.
    func recordPreflightAttempt(_ attempt: Int, outcome: String) {
        preflightObservations.append("#\(attempt) \(outcome)")
        DiagLog.notice(.playback, "HLS preflight #\(attempt): \(outcome.prefix(160))")
    }

    // MARK: - Capture

    /// Capture a playback error with the entire causal chain attached.
    func capture(_ error: Error, event: String, extraTags: [String: String] = [:]) {
        SentryBridge.capture(error: error) { scope in
            scope.setTag(value: "playback", key: "component")
            scope.setTag(value: event, key: "playback_event")
            // The root cause goes on a tag too, so Sentry can filter by it.
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
        // A tag so relay failures are filterable (`is_relay:true`).
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
