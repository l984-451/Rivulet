// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVRecording.swift
//  Rivulet
//
//  Source-neutral DVR types. Plex records through subscriptions, Dispatcharr
//  through recordings and recurring rules; the guide and the player only ever
//  see these.
//

import Foundation

/// One way a source offers to record a programme ("Record Episode", "Record
/// Series" …). Built by the provider and acted on by the same provider; the
/// UI shows the title and hands the option back.
nonisolated struct LiveTVRecordOption: Identifiable, Hashable, Sendable {
    enum Scope: Hashable, Sendable {
        /// This airing only.
        case single
        /// Every airing the rule matches.
        case series
    }

    let id: String
    let title: String
    let scope: Scope
    /// The provider's own description of the option (a Plex template, a
    /// Dispatcharr request body). Opaque outside the provider.
    let payload: String
}

/// A recording a source has scheduled, is making, or has made.
nonisolated struct LiveTVScheduledRecording: Identifiable, Hashable, Sendable {
    enum Status: String, Hashable, Sendable {
        case scheduled
        case recording
        case completed
        case failed
        case cancelled
    }

    let id: String
    let sourceId: String
    let title: String
    let subtitle: String?
    let startTime: Date
    let endTime: Date
    let status: Status
    let channelName: String?
    /// The unified channel id, when the recording's channel is one the guide
    /// knows.
    let channelId: String?
    /// The airing's own identifier (Plex guid), for matching guide cells.
    let programGuid: String?
    /// The rule that made it, when there is one.
    let ruleId: String?
    /// Whether that rule records more than this one airing, so cancelling the
    /// airing and cancelling the series are different actions.
    var ruleIsSeries: Bool = false
    let posterURL: URL?

    /// Whether this recording covers `program` on `channelId`: the same
    /// airing by guid, or the same channel at the same start.
    func covers(_ program: UnifiedProgram) -> Bool {
        if let programGuid, let guid = program.sourceGuid, programGuid == guid,
           abs(startTime.timeIntervalSince(program.startTime)) < 120 {
            return true
        }
        guard let channelId, channelId == program.channelId else { return false }
        return abs(startTime.timeIntervalSince(program.startTime)) < 120
    }
}

/// A standing rule that keeps recording (a Plex subscription, a Dispatcharr
/// series or recurring rule).
nonisolated struct LiveTVRecordingRule: Identifiable, Hashable, Sendable {
    let id: String
    let sourceId: String
    let title: String
    let detail: String?
}

/// Implemented by Live TV sources that can record. The guide and the player
/// ask the data store, which routes to the source that owns the channel.
protocol LiveTVRecordingProvider: LiveTVProvider {
    /// The ways this source can record `program`. Empty when it cannot
    /// (no guide identity, already ended, no DVR configured).
    func recordOptions(for program: UnifiedProgram, on channel: UnifiedChannel) async throws -> [LiveTVRecordOption]
    func record(_ option: LiveTVRecordOption, program: UnifiedProgram, on channel: UnifiedChannel) async throws
    func scheduledRecordings() async throws -> [LiveTVScheduledRecording]
    /// Cancel one airing, leaving any rule that made it in place.
    func cancel(_ recording: LiveTVScheduledRecording) async throws
    func recordingRules() async throws -> [LiveTVRecordingRule]
    /// Remove a rule and what it scheduled.
    func delete(_ rule: LiveTVRecordingRule) async throws
}

nonisolated enum LiveTVRecordingError: LocalizedError {
    case notSupported
    case programEnded
    case noGuideIdentity

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "This source can't record."
        case .programEnded:
            return "This programme has already ended."
        case .noGuideIdentity:
            return "The guide doesn't identify this programme well enough to record it."
        }
    }
}
