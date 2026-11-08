// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The last few playback sessions, kept on disk so a report shows what played before a freeze.
// Kinds and counts only: no titles, ids or URLs.

import Foundation

nonisolated struct PlaybackSessionRecord: Codable, Sendable, Equatable {
    enum End: String, Codable, Sendable {
        case running, ended, userExit = "user_exit", failed, nextItem = "next_item"
    }

    var id = String(UUID().uuidString.prefix(8))
    var launch = DiagLaunch.id
    var startedAt = Date()
    var route = ""                // aether | hls
    var delivery = ""             // direct_play | transcode
    var mediaType = ""
    var container = ""
    var videoCodec = ""
    var resolution = ""
    var hdr = ""                  // sdr | hdr | dolby_vision (+ profile)
    var bitrateClass = ""
    var audio = ""
    var startLatencyMs: Int?
    var stallCount = 0
    var stallSeconds = 0.0
    var seekCount = 0
    var errors: [String] = []
    var fellBackTo: String?
    var end = End.running
    var endedAt: Date?
    var lastPositionSec = 0

    static func bitrateClass(kbps: Int?) -> String {
        guard let kbps, kbps > 0 else { return "unknown" }
        switch kbps {
        case ..<4_000: return "<4M"
        case ..<10_000: return "4-10M"
        case ..<25_000: return "10-25M"
        case ..<60_000: return "25-60M"
        default: return ">60M"
        }
    }
}

nonisolated final class PlaybackHistory: @unchecked Sendable {
    static let shared = PlaybackHistory(
        file: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Diagnostics/playback-history.json"))

    private let queue = DispatchQueue(label: "com.rivulet.playback-history", qos: .utility)
    private let file: URL
    private let cap: Int
    private var records: [PlaybackSessionRecord]

    init(file: URL, cap: Int = 10) {
        self.file = file
        self.cap = cap
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([PlaybackSessionRecord].self, from: Data(contentsOf: file))) ?? []
    }

    /// Adds a session, dropping the oldest past the cap.
    func begin(_ record: PlaybackSessionRecord) {
        queue.async { [self] in
            records.append(record)
            if records.count > cap { records.removeFirst(records.count - cap) }
            save()
        }
    }

    func update(_ id: String, _ change: @escaping @Sendable (inout PlaybackSessionRecord) -> Void) {
        queue.async { [self] in
            guard let i = records.lastIndex(where: { $0.id == id }) else { return }
            change(&records[i])
            save()
        }
    }

    /// Sessions oldest first, as JSON-safe dictionaries. A session still "running" from an earlier
    /// launch never finished: the app went away mid-play, which is the freeze or crash signature.
    func report() -> [[String: Any]] {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return records.compactMap { record -> [String: Any]? in
                guard let data = try? encoder.encode(record),
                      var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                dict.removeValue(forKey: "id")
                dict.removeValue(forKey: "launch")
                if record.end == .running {
                    dict["end"] = record.launch == DiagLaunch.id ? "running_at_report" : "interrupted_app_exited"
                }
                dict["this_launch"] = record.launch == DiagLaunch.id
                return dict
            }
        }
    }

    /// Waits for pending writes (tests).
    func flush() { queue.sync {} }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
