// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Memory context for hard-to-trace reports (App Hangs, watchdog terminations). A watchdog kill
// carries no stack, so the last footprint on the scope and in the breadcrumbs is the evidence.
// Numbers only, no PII. Every call is a no-op when Sentry is not running.

import Foundation
import os
import Sentry
import UIKit

/// When a periodic sample earns a breadcrumb. The scope context updates on every sample, but a
/// two-hour film would otherwise add 240 crumbs and push the navigation trail out of the 100 kept.
nonisolated struct MemoryCrumbPolicy: Equatable {
    var minDeltaMB = 50
    var maxQuietSeconds: TimeInterval = 300
    private(set) var lastCrumbMB: Int?
    private(set) var lastCrumbAt: Date?

    mutating func shouldCrumb(footprintMB: Int, now: Date) -> Bool {
        guard footprintMB >= 0 else { return false }
        guard let lastCrumbMB, let lastCrumbAt else { return mark(footprintMB, now) }
        if abs(footprintMB - lastCrumbMB) >= minDeltaMB || now.timeIntervalSince(lastCrumbAt) >= maxQuietSeconds {
            return mark(footprintMB, now)
        }
        return false
    }

    private mutating func mark(_ footprintMB: Int, _ now: Date) -> Bool {
        lastCrumbMB = footprintMB
        lastCrumbAt = now
        return true
    }
}

@MainActor
enum MemoryDiagnostics {
    static let sampleInterval: Duration = .seconds(30)

    private static var sampler: Task<Void, Never>?
    private static var policy = MemoryCrumbPolicy()
    private static var observer: NSObjectProtocol?

    /// Current memory numbers: `footprint_mb` is what jetsam measures; `available_mb` is the headroom left.
    static func snapshot() -> [String: Any] {
        [
            "footprint_mb": DiagnosticsHistory.footprintMB(),
            "available_mb": Int(os_proc_available_memory() / 1_048_576),
        ]
    }

    /// Hooks the memory warning. Call once, after Sentry starts.
    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { record("memory_warning", level: .warning) }
        }
        record("sentry_started")
    }

    /// Samples now: refreshes the scope's `memory` context (what a watchdog kill is read from) and,
    /// for a named moment, drops a breadcrumb. `level: .warning` is mirrored as a log.
    static func record(_ reason: String, level: SentryLevel = .debug) {
        var data = snapshot()
        data["reason"] = reason
        publish(data)
        let crumb = Breadcrumb(level: level, category: "memory")
        crumb.message = reason
        crumb.data = data
        SentryBridge.addBreadcrumb(crumb)
    }

    /// Player session opened (route set): sample, then every 30 s until it stops.
    static func playbackDidStart() {
        guard sampler == nil else { return }
        record("playback_start")
        sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: sampleInterval)
                guard !Task.isCancelled else { return }
                sample()
            }
        }
    }

    static func playbackDidStop() {
        guard let running = sampler else { return }
        running.cancel()
        sampler = nil
        record("playback_stop")
    }

    private static func sample() {
        var data = snapshot()
        publish(data)
        guard policy.shouldCrumb(footprintMB: data["footprint_mb"] as? Int ?? -1, now: Date()) else { return }
        data["reason"] = "playback_tick"
        let crumb = Breadcrumb(level: .debug, category: "memory")
        crumb.message = "playback_tick"
        crumb.data = data
        SentryBridge.addBreadcrumb(crumb)
    }

    private static func publish(_ data: [String: Any]) {
        SentryBridge.configureScope { scope in
            scope.setContext(value: data, key: "memory")
        }
    }
}
