// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StartupTimer.swift
//  Rivulet
//
//  Wall-clock startup tracing: prints "[Startup +1234ms] <event>" lines so a
//  launch timeline reads straight out of the device console. Callable from any actor.
//

import Foundation
import os

enum StartupTimer {
    /// Launch reference: when the process started, not first touch. Stored
    /// properties such as the SwiftData container initialise before
    /// `RivuletApp.init`'s body, so first touch would bill them to +0 ms.
    private static let launchUptime = processStartUptime()

    private static let log = Logger(subsystem: "com.bain.Rivulet", category: "Startup")

    /// Process start expressed on the `systemUptime` clock. Falls back to "now"
    /// if the sysctl fails, which just restores the old first-touch behaviour.
    private static func processStartUptime() -> Double {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nowUptime }
        let startWall = Double(info.kp_proc.p_starttime.tv_sec)
            + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        // p_starttime is on the wall clock; convert onto the uptime basis by
        // measuring how long ago it was. Both advance at the same rate over a
        // launch window, so the mixed bases are fine for a diagnostic.
        let elapsed = Date().timeIntervalSince1970 - startWall
        guard elapsed >= 0, elapsed < 600 else { return nowUptime }
        return nowUptime - elapsed
    }

    /// Force the launch reference to be captured now (call as early as possible).
    nonisolated static func arm() { _ = launchUptime }

    /// Log a milestone with elapsed-since-launch. Nonisolated so it can be
    /// called from any executor, including deinit (the module's default
    /// MainActor isolation would otherwise apply).
    nonisolated static func mark(_ event: String) {
        let ms = (ProcessInfo.processInfo.systemUptime - launchUptime) * 1000
        log.info("[Startup +\(Int(ms), privacy: .public)ms] \(event, privacy: .public)")
    }

    /// Time an async block, logging start + duration with the elapsed prefix.
    @discardableResult
    static func measure<T>(_ event: String, _ work: () async throws -> T) async rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        mark("▶︎ \(event)")
        defer {
            let dur = (ProcessInfo.processInfo.systemUptime - start) * 1000
            mark("✓ \(event) — took \(Int(dur))ms")
        }
        return try await work()
    }
}
