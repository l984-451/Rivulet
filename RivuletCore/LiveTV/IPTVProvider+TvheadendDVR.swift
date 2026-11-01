// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IPTVProvider+TvheadendDVR.swift
//  Rivulet
//
//  The `LiveTVRecordingProvider` requirements for a Tvheadend source, reached
//  from IPTVProvider+DVR.swift. A programme's `sourceGuid` is its event id, and
//  a channel's `tvgId` its uuid.
//

import Foundation

extension IPTVProvider {
    /// Signed in, and not known to lack DVR rights.
    nonisolated var tvheadendSupportsRecording: Bool {
        tvheadendAccount?.isSignedIn == true && tvheadendCanRecord != false
    }

    func tvheadendRecordOptions(for program: UnifiedProgram, on channel: UnifiedChannel) throws -> [LiveTVRecordOption] {
        guard program.endTime > Date() else { throw LiveTVRecordingError.programEnded }
        guard program.sourceGuid.flatMap(Int.init) != nil, channel.tvgId != nil else {
            throw LiveTVRecordingError.noGuideIdentity
        }
        var options = [LiveTVRecordOption(id: "\(program.id)#once", title: "Record", scope: .single, payload: "once")]
        if !program.isMovie {
            options.append(LiveTVRecordOption(id: "\(program.id)#all", title: "Record Series", scope: .series,
                                              payload: "all"))
            options.append(LiveTVRecordOption(id: "\(program.id)#new", title: "Record New Episodes", scope: .series,
                                              payload: "new"))
        }
        return options
    }

    func tvheadendRecord(_ option: LiveTVRecordOption, program: UnifiedProgram, on channel: UnifiedChannel,
                         using service: TvheadendService) async throws {
        guard let eventId = program.sourceGuid.flatMap(Int.init), let channelUUID = channel.tvgId else {
            throw LiveTVRecordingError.noGuideIdentity
        }
        switch option.payload {
        case "once":
            try await service.recordEvent(eventId: eventId)
        case "all", "new":
            try await service.recordSeries(eventId: eventId, seriesLink: tvheadendSeriesLinks[eventId],
                                           title: program.title, channelUUID: channelUUID,
                                           newOnly: option.payload == "new")
        default:
            throw LiveTVRecordingError.notSupported
        }
    }

    func tvheadendScheduledRecordings(using service: TvheadendService) async throws -> [LiveTVScheduledRecording] {
        let channels = channelsByUUID()
        return try await service.recordings().map { recording in
            let channel = recording.channelUUID.flatMap { channels[$0] }
            return LiveTVScheduledRecording(
                id: recording.uuid, sourceId: sourceId, title: recording.title, subtitle: recording.subtitle,
                startTime: recording.start, endTime: recording.stop, status: recording.status,
                channelName: recording.channelName ?? channel?.name, channelId: channel?.id,
                programGuid: recording.eventId.map(String.init), ruleId: recording.autorecUUID,
                ruleIsSeries: recording.autorecUUID != nil, posterURL: nil)
        }
        .sorted { $0.startTime < $1.startTime }
    }

    /// One airing: stopped if it is recording (what was recorded is kept),
    /// otherwise cancelled. Any rule that scheduled it stays.
    func tvheadendCancel(_ recording: LiveTVScheduledRecording, using service: TvheadendService) async throws {
        if recording.status == .recording {
            try await service.stop(recordingUUID: recording.id)
        } else {
            try await service.cancel(recordingUUID: recording.id)
        }
    }

    func tvheadendRecordingRules(using service: TvheadendService) async throws -> [LiveTVRecordingRule] {
        let channels = channelsByUUID()
        return try await service.rules().map { rule in
            let mode = rule.newOnly ? "New episodes" : "All episodes"
            return LiveTVRecordingRule(id: rule.uuid, sourceId: sourceId, title: rule.title,
                                       detail: [mode, rule.channelUUID.flatMap { channels[$0]?.name }]
                                           .compactMap { $0 }.joined(separator: " · "))
        }
    }

    private func channelsByUUID() -> [String: UnifiedChannel] {
        Dictionary(cachedChannels.compactMap { channel in channel.tvgId.map { ($0, channel) } },
                   uniquingKeysWith: { first, _ in first })
    }
}
