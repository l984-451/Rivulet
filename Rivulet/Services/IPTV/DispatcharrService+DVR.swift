// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DispatcharrService+DVR.swift
//  Rivulet
//
//  Dispatcharr's REST API for recording: channels (to find the API's id for
//  a playlist channel), one-off recordings, series rules and recurring rules.
//  Every call needs the API key; the playlist and guide do not.
//
//  Shapes follow Dispatcharr 0.31 (apps/channels/api_views.py and the web
//  guide's own calls in frontend/src/api.js).
//

import Foundation

// MARK: - API models

/// A channel as `/api/channels/channels/summary/` lists it: enough to tie a
/// playlist channel (whose stream URL ends in the channel's uuid) to the
/// API's integer id and its guide entry.
nonisolated struct DispatcharrChannelSummary: Decodable, Sendable {
    let id: Int
    let uuid: String
    let name: String?
    let channelNumber: Double?
    let epgDataId: Int?

    enum CodingKeys: String, CodingKey {
        case id, uuid, name
        case channelNumber = "channel_number"
        case epgDataId = "epg_data_id"
    }
}

/// The guide entry a channel is mapped to. Series rules match on its
/// `tvg_id`, which is the EPG source's own id for the channel, not the
/// playlist's (that is the channel number unless configured otherwise).
nonisolated struct DispatcharrEPGData: Decodable, Sendable {
    let id: Int
    let tvgId: String?
    let epgSource: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case tvgId = "tvg_id"
        case epgSource = "epg_source"
    }
}

nonisolated struct DispatcharrRecording: Decodable, Sendable {
    let id: Int
    let channel: Int
    let startTime: Date
    let endTime: Date
    let properties: Properties

    /// The subset of `custom_properties` the app reads. The DVR writes many
    /// more keys; each one here decodes on its own so an odd value in one
    /// never drops the recording.
    nonisolated struct Properties: Decodable, Sendable {
        var status: String?
        var program: Program?
        var rule: RuleRef?
        var posterURL: String?
        var posterLogoId: Int?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            program = try? c.decodeIfPresent(Program.self, forKey: .program)
            rule = try? c.decodeIfPresent(RuleRef.self, forKey: .rule)
            posterURL = try? c.decodeIfPresent(String.self, forKey: .posterURL)
            posterLogoId = try? c.decodeIfPresent(Int.self, forKey: .posterLogoId)
        }

        enum CodingKeys: String, CodingKey {
            case status, program, rule
            case posterURL = "poster_url"
            case posterLogoId = "poster_logo_id"
        }
    }

    /// The guide programme the recording was made from, as the DVR copied it.
    nonisolated struct Program: Decodable, Sendable {
        var title: String?
        var subtitle: String?
        var description: String?
        var startTime: String?
        var endTime: String?
        var tvgId: String?
        var epgSourceId: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            startTime = try? c.decodeIfPresent(String.self, forKey: .startTime)
            endTime = try? c.decodeIfPresent(String.self, forKey: .endTime)
            tvgId = try? c.decodeIfPresent(String.self, forKey: .tvgId)
            epgSourceId = DispatcharrLenient.int(c, .epgSourceId)
        }

        enum CodingKeys: String, CodingKey {
            case title, description
            case subtitle = "sub_title"
            case startTime = "start_time"
            case endTime = "end_time"
            case tvgId = "tvg_id"
            case epgSourceId = "epg_source_id"
        }
    }

    /// Set on recordings a recurring rule made.
    nonisolated struct RuleRef: Decodable, Sendable {
        var type: String?
        var id: Int?
        var name: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, channel
        case startTime = "start_time"
        case endTime = "end_time"
        case properties = "custom_properties"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        channel = try c.decode(Int.self, forKey: .channel)
        guard let start = DispatcharrDates.parse(try c.decode(String.self, forKey: .startTime)),
              let end = DispatcharrDates.parse(try c.decode(String.self, forKey: .endTime)) else {
            throw DecodingError.dataCorruptedError(forKey: .startTime, in: c,
                                                   debugDescription: "Unreadable recording time")
        }
        startTime = start
        endTime = end
        properties = (try? c.decodeIfPresent(Properties.self, forKey: .properties)) ?? Properties()
    }
}

/// A series rule. Dispatcharr keeps these in settings rather than a table,
/// so they have no id: a rule is its (tvg_id, title, source).
nonisolated struct DispatcharrSeriesRule: Codable, Sendable, Hashable {
    var tvgId: String?
    var title: String?
    var mode: String?
    var epgSourceId: Int?

    enum CodingKeys: String, CodingKey {
        case title, mode
        case tvgId = "tvg_id"
        case epgSourceId = "epg_source_id"
    }

    init(tvgId: String?, title: String?, mode: String?, epgSourceId: Int?) {
        self.tvgId = tvgId
        self.title = title
        self.mode = mode
        self.epgSourceId = epgSourceId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tvgId = try? c.decodeIfPresent(String.self, forKey: .tvgId)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        epgSourceId = DispatcharrLenient.int(c, .epgSourceId)
    }

    /// Whether this rule is the one behind a recording of `program`: same
    /// guide channel, and the same title unless the rule matches any title.
    func covers(_ program: DispatcharrRecording.Program) -> Bool {
        guard (tvgId ?? "") == (program.tvgId ?? "") else { return false }
        if let title, !title.isEmpty, title != program.title { return false }
        if let epgSourceId, let other = program.epgSourceId, epgSourceId != other { return false }
        return true
    }
}

/// `GET /api/channels/series-rules/` wraps the list.
nonisolated struct DispatcharrSeriesRuleList: Decodable, Sendable {
    let rules: [DispatcharrSeriesRule]
}

nonisolated struct DispatcharrRecurringRule: Decodable, Sendable {
    let id: Int
    let channel: Int
    let daysOfWeek: [Int]
    let startTime: String
    let endTime: String
    let enabled: Bool
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, channel, enabled, name
        case daysOfWeek = "days_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        channel = try c.decode(Int.self, forKey: .channel)
        daysOfWeek = (try? c.decodeIfPresent([Int].self, forKey: .daysOfWeek)) ?? []
        startTime = (try? c.decodeIfPresent(String.self, forKey: .startTime)) ?? ""
        endTime = (try? c.decodeIfPresent(String.self, forKey: .endTime)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        name = try? c.decodeIfPresent(String.self, forKey: .name)
    }
}

// MARK: - Decoding helpers

nonisolated enum DispatcharrDates {
    /// Django writes ISO 8601 with an offset, with or without fractional
    /// seconds ("2026-07-09T14:00:00Z", "2026-07-09T14:00:00.123456+00:00").
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

nonisolated enum DispatcharrLenient {
    /// An integer the server may store as a number or a numeric string.
    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }
}

// MARK: - Calls

extension DispatcharrService {

    func fetchChannelSummaries() async throws -> [DispatcharrChannelSummary] {
        try await getJSON("api/channels/channels/summary/")
    }

    func fetchEPGData(id: Int) async throws -> DispatcharrEPGData {
        try await getJSON("api/epg/epgdata/\(id)/")
    }

    func fetchRecordings() async throws -> [DispatcharrRecording] {
        try await getJSON("api/channels/recordings/")
    }

    /// Record one airing. The programme goes along so the server applies its
    /// own padding and names the file from the guide, as the web guide does.
    func createRecording(channelId: Int, start: Date, end: Date,
                         program: [String: String]) async throws {
        let body: [String: Any] = [
            "channel": "\(channelId)",
            "start_time": DispatcharrDates.format(start),
            "end_time": DispatcharrDates.format(end),
            "custom_properties": ["program": program],
        ]
        _ = try await send("api/channels/recordings/", method: "POST", json: body)
    }

    func deleteRecording(id: Int) async throws {
        _ = try await send("api/channels/recordings/\(id)/", method: "DELETE")
    }

    /// End a recording in progress, keeping what has been recorded.
    func stopRecording(id: Int) async throws {
        _ = try await send("api/channels/recordings/\(id)/stop/", method: "POST")
    }

    func fetchSeriesRules() async throws -> [DispatcharrSeriesRule] {
        let envelope: DispatcharrSeriesRuleList = try await getJSON("api/channels/series-rules/")
        return envelope.rules
    }

    /// Save a series rule and have the server schedule what it matches now.
    /// The web guide makes the same two calls, in this order.
    func createSeriesRule(tvgId: String, title: String, mode: String,
                          epgSourceId: Int?, channelId: Int?) async throws {
        var body: [String: Any] = ["tvg_id": tvgId, "title": title, "mode": mode]
        if let epgSourceId { body["epg_source_id"] = epgSourceId }
        if let channelId { body["channel_id"] = channelId }
        _ = try await send("api/channels/series-rules/", method: "POST", json: body)
        _ = try await send("api/channels/series-rules/evaluate/", method: "POST", json: ["tvg_id": tvgId])
    }

    /// Remove a series rule. The server also drops the future recordings it
    /// made.
    func deleteSeriesRule(_ rule: DispatcharrSeriesRule) async throws {
        var query = [URLQueryItem(name: "tvg_id", value: rule.tvgId ?? "")]
        if let title = rule.title { query.append(URLQueryItem(name: "title", value: title)) }
        if let source = rule.epgSourceId { query.append(URLQueryItem(name: "epg_source_id", value: String(source))) }
        _ = try await send("api/channels/series-rules/", method: "DELETE", query: query)
    }

    func fetchRecurringRules() async throws -> [DispatcharrRecurringRule] {
        try await getJSON("api/channels/recurring-rules/")
    }

    func deleteRecurringRule(id: Int) async throws {
        _ = try await send("api/channels/recurring-rules/\(id)/", method: "DELETE")
    }

    // MARK: Plumbing

    private func getJSON<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(path, method: "GET")
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ path: String, method: String, query: [URLQueryItem] = [],
                      json: [String: Any]? = nil) async throws -> Data {
        guard apiToken?.isEmpty == false else { throw DispatcharrError.unauthorized }
        var url = baseURL.appendingPathComponent(path)
        // appendingPathComponent drops a trailing slash; Django routes want it.
        if path.hasSuffix("/"), !url.absoluteString.hasSuffix("/") {
            url = URL(string: url.absoluteString + "/") ?? url
        }
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = authenticatedRequest(for: url, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
    }
}
