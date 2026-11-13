// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Keeps current app state (screen, playback route and state, last main-thread checkpoint)
// on the Sentry scope, so an App Hang event says what the user was doing when its frames
// do not symbolicate (RIVULET-41). Every call is a no-op when Sentry is not running.

import Foundation
import Sentry

/// Lightweight, main-actor-only recorder of app state for App Hang triage.
///
/// All work is synchronous and allocation-light: setting a scope tag and
/// appending a breadcrumb. Do NOT call this from inside a tight loop — it is
/// meant for coarse state transitions (screen changes, playback lifecycle,
/// and entry/exit of the few main-thread sections that can block).
@MainActor
enum AppHangContext {

    // MARK: - Tag keys (kept stable so Sentry search/grouping is consistent)

    private enum TagKey {
        static let screen = "app_screen"
        static let playbackRoute = "playback_route"
        static let playbackState = "playback_state"
        static let mainThreadSection = "main_thread_section"
        static let contentResolution = "content_resolution"
        static let contentHDR = "content_hdr"
        static let contentVideoCodec = "content_video_codec"
    }

    // MARK: - Last-known values (so breadcrumbs can carry full context)

    private static var currentScreen = "launch"
    private static var currentRoute = "none"
    private static var currentState = "idle"

    // MARK: - Screen

    /// Record the foreground screen the user is on (e.g. "home", "detail",
    /// "player", "live_tv", "settings", "music"). Coarse-grained on purpose.
    static func setScreen(_ screen: String) {
        guard screen != currentScreen else { return }
        currentScreen = screen
        setTag(TagKey.screen, screen)
        breadcrumb(category: "app_screen", message: screen)
    }

    // MARK: - Playback

    /// Record the active playback route (AVPlayerDirect / LocalRemux / HLS /
    /// Aether / Rivulet). Pass `nil` when playback tears down.
    static func setPlaybackRoute(_ route: String?) {
        let value = route ?? "none"
        guard value != currentRoute else { return }
        currentRoute = value
        setTag(TagKey.playbackRoute, value)
        breadcrumb(category: "playback_route", message: value)
    }

    /// Record the playback lifecycle state (idle/loading/ready/playing/paused/
    /// buffering/ended/failed). Drives the `playback_state` tag so a hang during
    /// e.g. `loading` or `buffering` is immediately distinguishable from one on
    /// a static screen.
    static func setPlaybackState(_ state: String) {
        guard state != currentState else { return }
        currentState = state
        setTag(TagKey.playbackState, state)
        breadcrumb(
            category: "playback_state",
            message: state,
            data: ["route": currentRoute, "screen": currentScreen]
        )
    }

    // MARK: - Content descriptors

    /// Record what the active session is *playing* — resolution, HDR format, and
    /// video codec — as scope tags, so an App Hang captured by the watchdog is
    /// sliceable by content type. A hang during playback that turns out to be
    /// "only on 4K HDR HEVC" is an actionable bug; the same hang with no content
    /// tags is a shrug. Pass coarse, low-cardinality strings (e.g. "4k"/"1080",
    /// "dolby_vision"/"hdr"/"sdr", "hevc"/"h264"). Call `clearContent()` on
    /// teardown so a later hang off the player isn't tagged with stale content.
    static func setContent(resolution: String, hdr: String, videoCodec: String) {
        setTag(TagKey.contentResolution, resolution)
        setTag(TagKey.contentHDR, hdr)
        setTag(TagKey.contentVideoCodec, videoCodec)
        breadcrumb(
            category: "playback_content",
            message: "\(resolution)/\(hdr)/\(videoCodec)",
            data: ["resolution": resolution, "hdr": hdr, "video_codec": videoCodec]
        )
    }

    /// Reset the content tags to "none" when playback tears down.
    static func clearContent() {
        setTag(TagKey.contentResolution, "none")
        setTag(TagKey.contentHDR, "none")
        setTag(TagKey.contentVideoCodec, "none")
    }

    // MARK: - Main-thread blocking sections

    /// Brackets a main-thread section that can block (pair with `exitMainThreadSection` in a
    /// `defer`). A hang inside it is named by the `main_thread_section` tag.
    static func enterMainThreadSection(_ name: String) {
        setTag(TagKey.mainThreadSection, name)
        breadcrumb(category: "main_thread_section", message: "enter:\(name)")
    }

    static func exitMainThreadSection(_ name: String) {
        // Clear the tag back to "none" so a later hang elsewhere isn't
        // misattributed to a section we already left cleanly.
        setTag(TagKey.mainThreadSection, "none")
        breadcrumb(category: "main_thread_section", message: "exit:\(name)")
    }

    /// One-shot checkpoint breadcrumb for a notable main-thread step that isn't
    /// a bracketed section (e.g. "configuring audio session", "decoding poster").
    /// Cheap to sprinkle at suspected slow steps.
    static func checkpoint(_ name: String, data: [String: Any]? = nil) {
        breadcrumb(category: "main_thread_checkpoint", message: name, data: data)
    }

    // MARK: - Private

    private static func setTag(_ key: String, _ value: String) {
        SentryBridge.configureScope { scope in
            scope.setTag(value: value, key: key)
        }
    }

    private static func breadcrumb(
        category: String,
        message: String,
        data: [String: Any]? = nil
    ) {
        // Debug: context for the event they ride on, not worth a log line each.
        let crumb = Breadcrumb(level: .debug, category: category)
        crumb.message = message
        if let data { crumb.data = data }
        SentryBridge.addBreadcrumb(crumb)
    }
}
