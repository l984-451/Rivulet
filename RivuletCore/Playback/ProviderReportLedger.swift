// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderReportLedger.swift
//  Rivulet
//
//  One provider reporter per play session, with the lifecycle a player needs: start once,
//  resume after the item ended, stop a replaced session at its last position.
//

import Foundation

@MainActor
final class ProviderReportLedger {
    private struct Entry {
        let reporter: any ProgressReporter
        var started = false
        /// Sent `stopped` after an ended item; a later "playing" starts it again.
        var stopped = false
        /// Replaced by a new session: nothing more is sent.
        var retired = false
        var position: TimeInterval = 0
    }

    private var entries: [String: Entry] = [:]

    /// A player report: "playing", "paused" or "stopped". The first opens the session.
    func report(_ key: String, make: () -> any ProgressReporter, state: String, time: TimeInterval) async {
        var entry = entries[key] ?? Entry(reporter: make())
        guard !entry.retired else { return }
        if entry.stopped {
            // The viewer sought back into the ended item and carried on: a fresh start.
            guard state == "playing" else { return }
            entry.stopped = false
            entry.started = false
        }
        let needsStart = !entry.started
        entry.started = true
        entry.position = time
        entry.stopped = state == "stopped"
        entries[key] = entry
        if needsStart {
            do {
                try await entry.reporter.start(position: time)
            } catch {
                entries[key]?.started = false
                if state != "stopped" { return }
            }
        }
        guard entries[key]?.retired == false else { return }
        switch state {
        case "paused": await entry.reporter.paused(at: time)
        case "stopped": await entry.reporter.stopped(at: time)
        default: await entry.reporter.progress(position: time)
        }
    }

    /// Opens the session before the player asks for media.
    func open(_ key: String, make: () -> any ProgressReporter, position: TimeInterval) async {
        guard entries[key] == nil else { return }
        let entry = Entry(reporter: make(), started: true, position: position)
        entries[key] = entry
        do {
            try await entry.reporter.start(position: position)
        } catch {
            entries[key]?.started = false
        }
    }

    /// Retires a session at its explicit final position, or its last report when replacing a stream.
    /// One that already ended sends nothing, and none reopens.
    func stop(_ key: String, make: () -> any ProgressReporter, fallback: TimeInterval, finalPosition: TimeInterval? = nil) async {
        var entry = entries[key] ?? Entry(reporter: make())
        guard !entry.retired else { return }
        let alreadyEnded = entry.stopped
        entry.retired = true
        entries[key] = entry
        guard !alreadyEnded else { return }
        await entry.reporter.stopped(at: finalPosition ?? (entry.position > 0 ? entry.position : fallback))
    }
}
