// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IPTVProvider+DVR.swift
//  Rivulet
//
//  Recording through Dispatcharr: one airing, every episode, or new episodes
//  only, and cancelling either. Plain M3U sources share the type but cannot
//  record; `supportsRecording` says which is which, and the data store asks
//  it before treating a source as a recorder.
//
//  The playlist names channels by tvg-id (the channel number by default) and
//  streams them at `/proxy/ts/stream/<uuid>`; the API names them by integer
//  id. The uuid in the stream URL is the join, with the number and then the
//  name as fallbacks for a server set to hand out direct provider URLs.
//

import Foundation

/// Dispatcharr's channels, looked up every way a playlist channel can be
/// matched to one.
nonisolated struct DispatcharrChannelIndex: Sendable {
    let byId: [Int: DispatcharrChannelSummary]
    let byUUID: [String: DispatcharrChannelSummary]
    let byNumber: [Double: DispatcharrChannelSummary]
    let byName: [String: DispatcharrChannelSummary]
    let fetchedAt: Date

    init(_ channels: [DispatcharrChannelSummary], fetchedAt: Date = Date()) {
        byId = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        byUUID = Dictionary(channels.map { ($0.uuid.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        byNumber = Dictionary(channels.compactMap { c in c.channelNumber.map { ($0, c) } },
                              uniquingKeysWith: { first, _ in first })
        byName = Dictionary(channels.compactMap { c in c.name.map { ($0.lowercased(), c) } },
                            uniquingKeysWith: { first, _ in first })
        self.fetchedAt = fetchedAt
    }

    /// The Dispatcharr channel behind a playlist entry.
    func match(streamURL: URL?, number: Int?, name: String) -> DispatcharrChannelSummary? {
        if let uuid = Self.streamUUID(streamURL), let hit = byUUID[uuid] { return hit }
        if let number, let hit = byNumber[Double(number)] { return hit }
        return byName[name.lowercased()]
    }

    /// The channel uuid at the end of a Dispatcharr proxy stream URL.
    static func streamUUID(_ url: URL?) -> String? {
        guard let url, url.path.contains("/proxy/") else { return nil }
        let last = url.lastPathComponent.lowercased()
        return UUID(uuidString: last) != nil ? last : nil
    }
}

nonisolated enum DispatcharrDVRError: LocalizedError {
    case channelNotFound

    var errorDescription: String? {
        "Dispatcharr doesn't list this channel, so it can't record it. Refresh the channel list and try again."
    }
}

/// What a Rivulet rule id says about the Dispatcharr rule it stands for.
/// Series rules have no id of their own on the server.
nonisolated enum DispatcharrRuleID {
    case series(DispatcharrSeriesRule)
    case recurring(Int)

    var encoded: String {
        switch self {
        case .series(let rule):
            let data = (try? JSONEncoder().encode(rule)) ?? Data()
            return "series:" + String(decoding: data, as: UTF8.self)
        case .recurring(let id):
            return "recurring:\(id)"
        }
    }

    init?(_ encoded: String) {
        if encoded.hasPrefix("recurring:"), let id = Int(encoded.dropFirst("recurring:".count)) {
            self = .recurring(id)
        } else if encoded.hasPrefix("series:"),
                  let rule = try? JSONDecoder().decode(DispatcharrSeriesRule.self,
                                                       from: Data(encoded.dropFirst("series:".count).utf8)) {
            self = .series(rule)
        } else {
            return nil
        }
    }
}

extension IPTVProvider: LiveTVRecordingProvider {

    /// Dispatcharr with an API key. Its playlist and guide need no key, so
    /// plenty of sources are set up without one; those simply do not record.
    nonisolated var supportsRecording: Bool {
        sourceType == .dispatcharr && !(apiToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func recordOptions(for program: UnifiedProgram, on channel: UnifiedChannel) async throws -> [LiveTVRecordOption] {
        let service = try dvrService()
        guard program.endTime > Date() else { throw LiveTVRecordingError.programEnded }
        guard let target = try await dispatcharrChannel(for: channel, using: service) else {
            throw DispatcharrDVRError.channelNotFound
        }
        var options = [LiveTVRecordOption(
            id: "\(program.id)#once",
            title: program.isMovie ? "Record Movie" : "Record",
            scope: .single,
            payload: "once"
        )]
        // A series rule matches on the guide's own channel id, so it needs the
        // channel to be mapped to guide data on the server.
        if !program.isMovie, let guide = await epgData(for: target, using: service),
           let tvgId = guide.tvgId, !tvgId.isEmpty {
            options.append(LiveTVRecordOption(id: "\(program.id)#all", title: "Record Series",
                                              scope: .series, payload: "all"))
            options.append(LiveTVRecordOption(id: "\(program.id)#new", title: "Record New Episodes",
                                              scope: .series, payload: "new"))
        }
        return options
    }

    func record(_ option: LiveTVRecordOption, program: UnifiedProgram, on channel: UnifiedChannel) async throws {
        let service = try dvrService()
        guard let target = try await dispatcharrChannel(for: channel, using: service) else {
            throw DispatcharrDVRError.channelNotFound
        }
        let guide = await epgData(for: target, using: service)

        switch option.payload {
        case "all", "new":
            guard let tvgId = guide?.tvgId, !tvgId.isEmpty else { throw LiveTVRecordingError.noGuideIdentity }
            // Pinned to the channel the viewer picked; left unpinned the
            // server records on the lowest-numbered channel carrying the guide.
            try await service.createSeriesRule(tvgId: tvgId, title: program.title, mode: option.payload,
                                               epgSourceId: guide?.epgSource, channelId: target.id)
        default:
            var snapshot = [
                "title": program.title,
                "start_time": DispatcharrDates.format(program.startTime),
                "end_time": DispatcharrDates.format(program.endTime),
            ]
            if let subtitle = program.subtitle { snapshot["sub_title"] = subtitle }
            if let description = program.description { snapshot["description"] = description }
            if let tvgId = guide?.tvgId { snapshot["tvg_id"] = tvgId }
            try await service.createRecording(channelId: target.id, start: program.startTime,
                                              end: program.endTime, program: snapshot)
        }
    }

    func scheduledRecordings() async throws -> [LiveTVScheduledRecording] {
        let service = try dvrService()
        let recordings = try await service.fetchRecordings()
        // Best effort: without rules only the "cancel series" distinction is
        // lost; without the index, the guide cannot mark the programme.
        let rules = (try? await service.fetchSeriesRules()) ?? []
        let index = try? await channelIndex(using: service)
        let now = Date()

        return recordings.map { recording in
            let program = recording.properties.program
            let summary = index?.byId[recording.channel]

            // The programme's own times, not the recording's: the server pads
            // both ends and moves the start of a recording made mid-airing to
            // "now", and the guide matches on the programme.
            let start = DispatcharrDates.parse(program?.startTime) ?? recording.startTime
            let end = DispatcharrDates.parse(program?.endTime) ?? recording.endTime

            var ruleId: String?
            if let ref = recording.properties.rule, ref.type == "recurring", let id = ref.id {
                ruleId = DispatcharrRuleID.recurring(id).encoded
            } else if let program, let rule = rules.first(where: { $0.covers(program) }) {
                ruleId = DispatcharrRuleID.series(rule).encoded
            }

            var result = LiveTVScheduledRecording(
                id: String(recording.id),
                sourceId: sourceId,
                title: program?.title ?? summary?.name ?? "Recording",
                subtitle: program?.subtitle,
                startTime: start,
                endTime: end,
                status: Self.status(of: recording, now: now),
                channelName: summary?.name,
                channelId: summary.flatMap { unifiedChannelId(for: $0) },
                programGuid: nil,
                ruleId: ruleId,
                posterURL: posterURL(recording.properties)
            )
            result.ruleIsSeries = ruleId != nil
            return result
        }
        .sorted { $0.startTime < $1.startTime }
    }

    /// One airing: stopped if it is recording (what was recorded is kept),
    /// otherwise removed. Any rule that scheduled it stays.
    func cancel(_ recording: LiveTVScheduledRecording) async throws {
        let service = try dvrService()
        guard let id = Int(recording.id) else { throw LiveTVRecordingError.notSupported }
        if recording.status == .recording {
            try await service.stopRecording(id: id)
        } else {
            try await service.deleteRecording(id: id)
        }
    }

    func recordingRules() async throws -> [LiveTVRecordingRule] {
        let service = try dvrService()
        var rules: [LiveTVRecordingRule] = []

        for rule in try await service.fetchSeriesRules() {
            let mode = rule.mode == "new" ? "New episodes" : "All episodes"
            rules.append(LiveTVRecordingRule(
                id: DispatcharrRuleID.series(rule).encoded,
                sourceId: sourceId,
                title: (rule.title?.isEmpty == false ? rule.title : nil) ?? rule.tvgId ?? "Series",
                detail: mode
            ))
        }

        let index = try? await channelIndex(using: service)
        for rule in (try? await service.fetchRecurringRules()) ?? [] where rule.enabled {
            let channelName = index?.byId[rule.channel]?.name
            let days = Self.dayNames(rule.daysOfWeek)
            let time = String(rule.startTime.prefix(5))
            rules.append(LiveTVRecordingRule(
                id: DispatcharrRuleID.recurring(rule.id).encoded,
                sourceId: sourceId,
                title: (rule.name?.isEmpty == false ? rule.name : nil) ?? channelName ?? "Repeating Recording",
                detail: [days, time, channelName].compactMap { $0 }.joined(separator: " · ")
            ))
        }
        return rules
    }

    func delete(_ rule: LiveTVRecordingRule) async throws {
        let service = try dvrService()
        switch DispatcharrRuleID(rule.id) {
        case .series(let series):
            try await service.deleteSeriesRule(series)
        case .recurring(let id):
            try await service.deleteRecurringRule(id: id)
        case nil:
            throw LiveTVRecordingError.notSupported
        }
    }

    // MARK: - Lookups

    private func dvrService() throws -> DispatcharrService {
        guard supportsRecording, let dispatcharrService else { throw LiveTVRecordingError.notSupported }
        return dispatcharrService
    }

    /// The server's channel list, refetched every ten minutes: channels are
    /// added and renumbered on the server far less often than that.
    private func channelIndex(using service: DispatcharrService) async throws -> DispatcharrChannelIndex {
        if let index = dvrChannelIndex, Date().timeIntervalSince(index.fetchedAt) < 600 {
            return index
        }
        let index = DispatcharrChannelIndex(try await service.fetchChannelSummaries())
        dvrChannelIndex = index
        return index
    }

    private func dispatcharrChannel(for channel: UnifiedChannel,
                                    using service: DispatcharrService) async throws -> DispatcharrChannelSummary? {
        let index = try await channelIndex(using: service)
        if let hit = index.match(streamURL: channel.streamURL, number: channel.channelNumber, name: channel.name) {
            return hit
        }
        // Added on the server since the index was built.
        dvrChannelIndex = nil
        return try await channelIndex(using: service)
            .match(streamURL: channel.streamURL, number: channel.channelNumber, name: channel.name)
    }

    private func epgData(for channel: DispatcharrChannelSummary,
                         using service: DispatcharrService) async -> DispatcharrEPGData? {
        guard let id = channel.epgDataId else { return nil }
        if let cached = dvrEPGData[id] { return cached }
        guard let data = try? await service.fetchEPGData(id: id) else { return nil }
        dvrEPGData[id] = data
        return data
    }

    /// The playlist channel a server channel is, for guide marks.
    private func unifiedChannelId(for summary: DispatcharrChannelSummary) -> String? {
        let uuid = summary.uuid.lowercased()
        if let byStream = cachedChannels.first(where: { DispatcharrChannelIndex.streamUUID($0.streamURL) == uuid }) {
            return byStream.id
        }
        if let number = summary.channelNumber,
           let byNumber = cachedChannels.first(where: { $0.channelNumber.map(Double.init) == number }) {
            return byNumber.id
        }
        let name = summary.name?.lowercased()
        return cachedChannels.first(where: { $0.name.lowercased() == name })?.id
    }

    private func posterURL(_ properties: DispatcharrRecording.Properties) -> URL? {
        if let poster = properties.posterURL, !poster.isEmpty {
            if poster.hasPrefix("http://") || poster.hasPrefix("https://") { return URL(string: poster) }
            if let base = baseURL { return URL(string: poster, relativeTo: base)?.absoluteURL }
        }
        if let logo = properties.posterLogoId, let base = baseURL {
            return base.appendingPathComponent("api/channels/logos/\(logo)/cache/")
        }
        return nil
    }

    private static func status(of recording: DispatcharrRecording, now: Date) -> LiveTVScheduledRecording.Status {
        switch recording.properties.status {
        case "recording": return .recording
        case "completed", "stopped": return .completed
        case "interrupted": return .failed
        default:
            // A series rule's recordings carry no status until they start.
            if recording.endTime <= now { return .completed }
            if recording.startTime <= now { return .recording }
            return .scheduled
        }
    }

    /// Dispatcharr numbers days from Monday (0) to Sunday (6).
    private static func dayNames(_ days: [Int]) -> String? {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let valid = days.filter { (0...6).contains($0) }.sorted()
        guard !valid.isEmpty else { return nil }
        if valid.count == 7 { return "Every day" }
        if valid == [0, 1, 2, 3, 4] { return "Weekdays" }
        if valid == [5, 6] { return "Weekends" }
        return valid.map { names[$0] }.joined(separator: ", ")
    }
}
