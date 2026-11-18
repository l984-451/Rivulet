// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ReleaseFixChecks.swift
//  Rivulet
//
//  TEMPORARY, one release only: logs that confirm engine fixes on real hardware
//  (AetherEngine #1053, #971, #1044). Delete this file, its test and every
//  `ReleaseFixChecks` call in the release after the one that ships it.
//

import CoreGraphics
import Foundation
import Sentry
import Synchronization

nonisolated enum ReleaseFixChecks {
    // ponytail: one tracker for every session; multiview slots on the software path interleave their lines.
    private static let seams = Mutex(PTSSeamCheck())

    /// Every engine log line (`EngineLog.structuredHandler`). AE#1053.
    static func engineLine(_ line: String) {
        guard line.hasPrefix("[SW"), let report = seams.withLock({ $0.ingest(line) }),
              SentryBridge.admit("fixcheck.1053", limit: 3) else { return }
        SentryBridge.log(.info, "Fix check AE#1053", attributes: [
            "stream": report.stream,
            "route": report.route,
            "delta": report.delta,
            "max_audio_lead": report.maxAudioLead,
            "starved_seconds": report.starvedSeconds,
            "seconds": report.seconds,
            "healthy": report.healthy,
        ])
    }

    /// A DVB subtitle image as the engine placed it (normalized). AE#971.
    static func dvbSubtitle(position: CGRect, canvas: CGSize, video: CGSize) {
        guard SentryBridge.admit("fixcheck.971", limit: 3) else { return }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        SentryBridge.log(.info, "Fix check AE#971", attributes: [
            "x": Double(position.minX), "y": Double(position.minY),
            "width": Double(position.width), "height": Double(position.height),
            "canvas": "\(Int(canvas.width))x\(Int(canvas.height))",
            "video": "\(Int(video.width))x\(Int(video.height))",
            "in_bounds": unit.insetBy(dx: -0.01, dy: -0.01).contains(position),
        ])
    }

    /// What the engine did with Stereo with Subwoofer on a load ("applied", "unavailable"). AE#1044.
    static func audioShaping(state: String, codec: String?, channels: Int?) {
        guard SentryBridge.admit("fixcheck.1044", limit: 5) else { return }
        SentryBridge.log(.info, "Fix check AE#1044", attributes: [
            "state": state, "codec": codec ?? "none", "channels": channels ?? 0,
        ])
    }
}

/// Follows the audio for 15 s after a software-path timestamp jump. Before AE#1053 the audio
/// lead grew by the size of the jump and the renderer starved for the rest of the session.
nonisolated struct PTSSeamCheck {
    struct Report: Equatable {
        var stream: String
        var route: String
        var delta: Double
        var maxAudioLead = 0.0
        var starvedSeconds = 0
        var seconds = 0

        var healthy: Bool { maxAudioLead < 30 && starvedSeconds * 2 < seconds }
    }

    /// `[SWDiag]` lines come once a second.
    static let window = 15
    private var pending: Report?

    mutating func ingest(_ line: String) -> Report? {
        if line.hasPrefix("[SWHost] PTS discontinuity") {
            if pending == nil { pending = Self.seam(line) }
            return nil
        }
        guard line.hasPrefix("[SWDiag]"), var report = pending else { return nil }
        if let lead = Self.field("aLead", in: line).flatMap(Double.init) {
            report.maxAudioLead = max(report.maxAudioLead, lead)
        }
        // aRend=status/sufficient/error
        if Self.field("aRend", in: line)?.split(separator: "/").dropFirst().first == "n" {
            report.starvedSeconds += 1
        }
        report.seconds += 1
        guard report.seconds >= Self.window else {
            pending = report
            return nil
        }
        pending = nil
        return report
    }

    /// "[SWHost] PTS discontinuity #1 (reader, audio): prevPts=… delta=347.06s -> offset=…"
    static func seam(_ line: String) -> Report? {
        guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")"),
              let delta = field("delta", in: line).flatMap({ Double($0.dropLast()) }) else { return nil }
        let parts = line[line.index(after: open)..<close].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        return Report(stream: parts[1], route: parts[0], delta: delta)
    }

    private static func field(_ name: String, in line: String) -> String? {
        line.split(separator: " ").first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
    }
}
