// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlaybackInputTelemetry.swift
//  Rivulet
//
//  Aggregates and reports playback input diagnostics to Sentry.
//

import Foundation
import Sentry

@MainActor
final class PlaybackInputTelemetry {
    static let shared = PlaybackInputTelemetry()

    enum ScrubSurface: String {
        case vod
        case liveTV = "live_tv"
    }

    enum ScrubTransition: String {
        case start
        case speedUp = "speed_up"
        case slowDown = "slow_down"
        case reverse
        case commit
        case cancel
    }

    private var sessionStartedAt = Date()
    private var receivedCount = 0
    private var dedupedCount = 0
    private var coalescedSeekCount = 0
    private var coalescedSeekSecondsTotal: TimeInterval = 0
    private var scrubCommitCount = 0
    private var scrubCancelCount = 0

    private var receivedBySource: [String: Int] = [:]
    private var receivedByAction: [String: Int] = [:]
    private var dedupedBySource: [String: Int] = [:]
    private var scrubTransitionByType: [String: Int] = [:]

    private init() {}

    func recordReceived(action: PlaybackInputAction, source: PlaybackInputSource, isScrubbing: Bool) {
        let actionName = name(for: action)
        let sourceName = source.rawValue

        receivedCount += 1
        increment(&receivedBySource, key: sourceName)
        increment(&receivedByAction, key: actionName)

        let breadcrumb = Breadcrumb(level: .info, category: "playback_input_received")
        breadcrumb.message = actionName
        breadcrumb.data = [
            "action": actionName,
            "source": sourceName,
            "is_scrubbing": isScrubbing
        ]
        SentryBridge.addBreadcrumb(breadcrumb)
    }

    func recordDeduped(
        action: PlaybackInputAction,
        source: PlaybackInputSource,
        window: TimeInterval,
        crossSourceOnly: Bool
    ) {
        let actionName = name(for: action)
        let sourceName = source.rawValue

        dedupedCount += 1
        increment(&dedupedBySource, key: sourceName)

        let breadcrumb = Breadcrumb(level: .info, category: "playback_input_deduped")
        breadcrumb.message = actionName
        breadcrumb.data = [
            "action": actionName,
            "source": sourceName,
            "window_ms": Int(window * 1000),
            "cross_source_only": crossSourceOnly
        ]
        SentryBridge.addBreadcrumb(breadcrumb)
    }

    func recordCoalescedSeek(totalSeconds: TimeInterval, source: PlaybackInputSource) {
        coalescedSeekCount += 1
        coalescedSeekSecondsTotal += totalSeconds

        let breadcrumb = Breadcrumb(level: .info, category: "playback_input_coalesced_seek")
        breadcrumb.message = "Coalesced seek"
        breadcrumb.data = [
            "source": source.rawValue,
            "total_seconds": totalSeconds
        ]
        SentryBridge.addBreadcrumb(breadcrumb)
    }

    func recordScrubTransition(
        surface: ScrubSurface,
        transition: ScrubTransition,
        source: PlaybackInputSource,
        speedBefore: Int? = nil,
        speedAfter: Int? = nil
    ) {
        increment(&scrubTransitionByType, key: transition.rawValue)

        switch transition {
        case .commit:
            scrubCommitCount += 1
        case .cancel:
            scrubCancelCount += 1
        default:
            break
        }

        var data: [String: Any] = [
            "surface": surface.rawValue,
            "transition": transition.rawValue,
            "source": source.rawValue
        ]
        if let speedBefore {
            data["speed_before"] = speedBefore
        }
        if let speedAfter {
            data["speed_after"] = speedAfter
        }

        let breadcrumb = Breadcrumb(level: .info, category: "playback_scrub_transition")
        breadcrumb.message = "\(surface.rawValue):\(transition.rawValue)"
        breadcrumb.data = data
        SentryBridge.addBreadcrumb(breadcrumb)
    }

    func flushSessionSummary(reason: String) {
        let duration = Date().timeIntervalSince(sessionStartedAt)
        guard receivedCount > 0 || dedupedCount > 0 || coalescedSeekCount > 0 || scrubCommitCount > 0 || scrubCancelCount > 0 else {
            resetSession()
            return
        }

        let breadcrumb = Breadcrumb(level: .info, category: "playback_input_session")
        breadcrumb.message = "Playback input session summary"
        breadcrumb.data = [
            "reason": reason,
            "duration_seconds": duration,
            "received_count": receivedCount,
            "deduped_count": dedupedCount,
            "coalesced_seek_count": coalescedSeekCount,
            "coalesced_seek_seconds_total": coalescedSeekSecondsTotal,
            "scrub_commit_count": scrubCommitCount,
            "scrub_cancel_count": scrubCancelCount,
            "received_by_source": receivedBySource,
            "received_by_action": receivedByAction,
            "deduped_by_source": dedupedBySource,
            "scrub_transition_by_type": scrubTransitionByType
        ]
        SentryBridge.addBreadcrumb(breadcrumb)

        resetSession()
    }

    private func resetSession() {
        sessionStartedAt = Date()
        receivedCount = 0
        dedupedCount = 0
        coalescedSeekCount = 0
        coalescedSeekSecondsTotal = 0
        scrubCommitCount = 0
        scrubCancelCount = 0
        receivedBySource.removeAll()
        receivedByAction.removeAll()
        dedupedBySource.removeAll()
        scrubTransitionByType.removeAll()
    }

    private func increment(_ bucket: inout [String: Int], key: String) {
        bucket[key, default: 0] += 1
    }

    private func name(for action: PlaybackInputAction) -> String {
        switch action {
        case .play:
            return "play"
        case .pause:
            return "pause"
        case .playPause:
            return "play_pause"
        case .back:
            return "back"
        case .showInfo:
            return "show_info"
        case .stepSeek(let forward):
            return forward ? "step_seek_forward" : "step_seek_backward"
        case .jumpSeek(let forward):
            return forward ? "jump_seek_forward" : "jump_seek_backward"
        case .seekRelative(let seconds):
            return seconds >= 0 ? "seek_relative_forward" : "seek_relative_backward"
        case .seekAbsolute:
            return "seek_absolute"
        case .scrubNudge(let forward):
            return forward ? "scrub_nudge_forward" : "scrub_nudge_backward"
        case .scrubRelative(let seconds):
            return seconds >= 0 ? "scrub_relative_forward" : "scrub_relative_backward"
        case .scrubCommit:
            return "scrub_commit"
        case .scrubCancel:
            return "scrub_cancel"
        }
    }
}
