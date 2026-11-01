// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TvheadendService+DVR.swift
//  Rivulet
//
//  Tvheadend recording: one airing by event id, a series by series link or by
//  an anchored title rule on the channel, cancel, and rules. Every call answers
//  403 for a user without DVR rights.
//

import Foundation

nonisolated struct TvheadendRecording: Sendable, Equatable {
    let uuid: String
    let title: String
    let subtitle: String?
    let start: Date
    let stop: Date
    let channelUUID: String?
    let channelName: String?
    let eventId: Int?
    let autorecUUID: String?
    let status: LiveTVScheduledRecording.Status
}

nonisolated struct TvheadendRule: Sendable, Equatable {
    let uuid: String
    let title: String
    let channelUUID: String?
    let newOnly: Bool
}

nonisolated enum TvheadendDVRError: LocalizedError {
    case cantRecord

    var errorDescription: String? { "This Tvheadend user can't record." }
}

extension TvheadendService {
    /// Autorec `btype` for "New / premiere" airings.
    private static let newOnlyBroadcastType = 3

    func recordEvent(eventId: Int) async throws {
        try await dvr { try await self.post("api/dvr/entry/create_by_event",
                                            ["event_id": String(eventId), "config_uuid": ""]) }
    }

    /// The series link when the guide has one. Otherwise, and for new episodes
    /// only (a series-link rule can't filter), a title rule on the channel.
    func recordSeries(eventId: Int, seriesLink: String?, title: String, channelUUID: String, newOnly: Bool) async throws {
        if seriesLink != nil, !newOnly {
            try await dvr { try await self.post("api/dvr/autorec/create_by_series",
                                                ["event_id": String(eventId), "config_uuid": ""]) }
            return
        }
        let conf = Self.titleRuleConf(title: title, channelUUID: channelUUID, newOnly: newOnly)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: conf, options: [.sortedKeys]),
                          as: UTF8.self)
        try await dvr { try await self.post("api/dvr/autorec/create", ["conf": json, "config_uuid": ""]) }
    }

    /// Scheduled and in-progress entries only: the full grid carries the whole
    /// recording history and could push upcoming ones past the limit.
    func recordings() async throws -> [TvheadendRecording] {
        try await dvr {
            Self.recordings(from: try await self.json(self.url("api/dvr/entry/grid_upcoming",
                                                               ["limit": "1000", "sort": "start", "dir": "ASC"])))
        }
    }

    func rules() async throws -> [TvheadendRule] {
        try await dvr { Self.rules(from: try await self.json(self.url("api/dvr/autorec/grid", ["limit": "1000"]))) }
    }

    func cancel(recordingUUID: String) async throws {
        try await dvr { try await self.post("api/dvr/entry/cancel", ["uuid": recordingUUID]) }
    }

    /// Ends a recording in progress and keeps what it recorded.
    func stop(recordingUUID: String) async throws {
        try await dvr { try await self.post("api/dvr/entry/stop", ["uuid": recordingUUID]) }
    }

    /// Removes a rule and the airings it scheduled.
    func deleteRule(uuid: String) async throws {
        try await dvr { try await self.post("api/idnode/delete", ["uuid": uuid]) }
    }

    /// Whether this login may record: the DVR list answers 403 when it may not.
    /// nil when the server could not say.
    func canRecord() async -> Bool? {
        do {
            _ = try await json(url("api/dvr/entry/grid", ["limit": "1"]))
            return true
        } catch TvheadendError.forbidden {
            return false
        } catch {
            return nil
        }
    }

    @discardableResult
    private func dvr<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch TvheadendError.forbidden {
            throw TvheadendDVRError.cantRecord
        }
    }

    // MARK: Decoding

    /// An autorec matching exactly `title` on one channel. Tvheadend reads the
    /// title as a regular expression, so it is escaped and anchored.
    nonisolated static func titleRuleConf(title: String, channelUUID: String, newOnly: Bool) -> [String: Any] {
        ["title": "^" + NSRegularExpression.escapedPattern(for: title) + "$",
         "channel": channelUUID,
         "enabled": 1,
         "comment": "Rivulet",
         "btype": newOnly ? newOnlyBroadcastType : 0]
    }

    nonisolated static func recordings(from grid: Any) -> [TvheadendRecording] {
        ((grid as? [String: Any])?["entries"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let uuid = string(entry["uuid"]),
                  let start = (entry["start"] as? NSNumber)?.doubleValue,
                  let stop = (entry["stop"] as? NSNumber)?.doubleValue else { return nil }
            return TvheadendRecording(uuid: uuid, title: string(entry["disp_title"]) ?? "Recording",
                                      subtitle: string(entry["disp_subtitle"]),
                                      start: Date(timeIntervalSince1970: start), stop: Date(timeIntervalSince1970: stop),
                                      channelUUID: string(entry["channel"]), channelName: string(entry["channelname"]),
                                      eventId: ((entry["broadcast"] as? NSNumber)?.intValue).flatMap { $0 > 0 ? $0 : nil },
                                      autorecUUID: string(entry["autorec"]),
                                      status: status(string(entry["sched_status"]) ?? ""))
        }
    }

    /// Measured: `scheduled`, `completedError`. The rest are Tvheadend's other
    /// states; anything unknown counts as failed rather than pending.
    nonisolated static func status(_ schedStatus: String) -> LiveTVScheduledRecording.Status {
        switch schedStatus {
        case "scheduled": .scheduled
        case "recording": .recording
        case "completed", "completedWarning": .completed
        default: .failed
        }
    }

    nonisolated static func rules(from grid: Any) -> [TvheadendRule] {
        ((grid as? [String: Any])?["entries"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let uuid = string(entry["uuid"]) else { return nil }
            return TvheadendRule(uuid: uuid, title: ruleTitle(name: string(entry["name"]), pattern: string(entry["title"])),
                                 channelUUID: string(entry["channel"]),
                                 newOnly: (entry["btype"] as? NSNumber)?.intValue == newOnlyBroadcastType)
        }
    }

    /// A rule's own name, else its title pattern without the anchors and escapes
    /// Rivulet adds.
    nonisolated static func ruleTitle(name: String?, pattern: String?) -> String {
        if let name { return name }
        guard var text = pattern else { return "Series" }
        if text.hasPrefix("^") { text.removeFirst() }
        if text.hasSuffix("$"), !text.hasSuffix("\\$") { text.removeLast() }
        return text.replacing(/\\(.)/) { String($0.output.1) }
    }
}
