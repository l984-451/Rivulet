// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexNetworkManager+DVR.swift
//  Rivulet
//
//  Plex DVR: recording a programme, listing what is scheduled, and cancelling.
//
//  Plex records through "subscriptions". The flow every Plex client uses:
//
//    1. GET /media/subscriptions/template?guid={airing guid}
//       The server answers with the ways it can record that airing ("this
//       episode", "all episodes", "new episodes only" …). Each option carries
//       a ready-made `parameters` query (hints, airing channels and times,
//       library type) plus the preference `Setting`s with their defaults.
//    2. POST /media/subscriptions?{parameters}&targetLibrarySectionID=…
//       &targetSectionLocationID=…&prefs[id]=value…
//       Creates the rule; one-shot rules cover a single airing.
//
//  Upcoming recordings are grab operations (/media/subscriptions/scheduled);
//  cancelling one airing deletes its grab, removing a series rule deletes the
//  subscription (and every grab it made).
//
//  Everything is parsed by walking the JSON rather than decoding a fixed
//  shape: Setting values arrive as strings, numbers or booleans depending on
//  the setting, and the tune endpoint in the same family is known to vary its
//  nesting by PMS version.
//

import Foundation

/// One way Plex offers to record an airing, from the subscription template.
nonisolated struct PlexSubscriptionTemplateOption: Sendable, Hashable, Codable {
    /// Plex's own label for the option ("Episode", "Show", "Movie" …).
    let title: String
    /// Metadata type of what the rule would record: 1 movie, 2 show, 4 episode.
    let type: Int?
    /// The ready-made query from the template, still percent-encoded.
    let parameters: String
    let targetLibrarySectionID: Int?
    let targetSectionLocationID: Int?
    let librarySectionTitle: String?
    let airingsType: String?
    /// Preference ids and their values (current value, else default), as the
    /// template states them. Sent back unchanged as `prefs[id]=value`.
    let prefs: [String: String]
    /// Whether the server pre-selected this option.
    let selected: Bool
}

/// A scheduled or in-progress Plex DVR grab.
nonisolated struct PlexScheduledGrab: Sendable, Hashable {
    /// The grab operation id (what cancelling one airing deletes).
    let id: String
    let subscriptionId: String?
    /// "scheduled", "inprogress", "complete", "error", "cancelled" …
    let status: String
    let title: String
    let grandparentTitle: String?
    let guid: String?
    let type: String?
    let beginsAt: Date?
    let endsAt: Date?
    let channelIdentifier: String?
    let channelTitle: String?
    let thumb: String?
}

/// A standing Plex recording rule.
nonisolated struct PlexSubscriptionSummary: Sendable, Hashable {
    let id: String
    let title: String
    let type: Int?
    let airingsType: String?
    let librarySectionTitle: String?
    /// How many grabs the rule has lined up right now.
    let scheduledCount: Int
}

extension PlexNetworkManager {

    // MARK: - Recording

    /// The ways the server can record the airing with this guid.
    func getSubscriptionTemplate(
        serverURL: String,
        authToken: String,
        guid: String
    ) async throws -> [PlexSubscriptionTemplateOption] {
        guard var components = URLComponents(string: "\(serverURL)/media/subscriptions/template") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]
        guard let url = components.url else { throw PlexAPIError.invalidURL }

        let data = try await requestData(url, headers: dvrHeaders(authToken: authToken))
        guard let container = Self.mediaContainer(from: data) else { throw PlexAPIError.parsingError }

        var options: [PlexSubscriptionTemplateOption] = []
        for template in Self.array(container["SubscriptionTemplate"]) {
            for subscription in Self.array(template["MediaSubscription"]) {
                guard let parameters = subscription["parameters"] as? String, !parameters.isEmpty else { continue }
                var prefs: [String: String] = [:]
                for setting in Self.array(subscription["Setting"]) {
                    guard let id = setting["id"] as? String, !id.isEmpty,
                          let value = Self.settingString(setting["value"]) ?? Self.settingString(setting["default"])
                    else { continue }
                    prefs[id] = value
                }
                options.append(PlexSubscriptionTemplateOption(
                    title: (subscription["title"] as? String) ?? "Record",
                    type: Self.int(subscription["type"]),
                    parameters: parameters,
                    targetLibrarySectionID: Self.int(subscription["targetLibrarySectionID"]),
                    targetSectionLocationID: Self.int(subscription["targetSectionLocationID"]),
                    librarySectionTitle: subscription["librarySectionTitle"] as? String,
                    airingsType: subscription["airingsType"] as? String,
                    prefs: prefs,
                    selected: Self.bool(subscription["selected"]) ?? false
                ))
            }
        }
        return options
    }

    /// Create the recording rule a template option describes.
    func createSubscription(
        serverURL: String,
        authToken: String,
        option: PlexSubscriptionTemplateOption
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/media/subscriptions") else {
            throw PlexAPIError.invalidURL
        }
        // The template's query is rebuilt item by item rather than spliced in
        // as a string: its `hints[…]` names carry brackets, which a raw
        // percent-encoded query is not allowed to contain.
        var items = Self.queryItems(fromEncodedQuery: option.parameters)
        let named = Set(items.map(\.name))
        if let section = option.targetLibrarySectionID, !named.contains("targetLibrarySectionID") {
            items.append(URLQueryItem(name: "targetLibrarySectionID", value: String(section)))
        }
        if let location = option.targetSectionLocationID, !named.contains("targetSectionLocationID") {
            items.append(URLQueryItem(name: "targetSectionLocationID", value: String(location)))
        }
        if !named.contains("includeGrabs") {
            items.append(URLQueryItem(name: "includeGrabs", value: "1"))
        }
        for (id, value) in option.prefs.sorted(by: { $0.key < $1.key }) where !named.contains("prefs[\(id)]") {
            items.append(URLQueryItem(name: "prefs[\(id)]", value: value))
        }
        components.queryItems = items
        guard let url = components.url else { throw PlexAPIError.invalidURL }

        _ = try await requestData(url, method: "POST", headers: dvrHeaders(authToken: authToken))
    }

    /// Every upcoming or in-progress recording on the server.
    func getScheduledRecordings(
        serverURL: String,
        authToken: String
    ) async throws -> [PlexScheduledGrab] {
        guard let url = URL(string: "\(serverURL)/media/subscriptions/scheduled") else {
            throw PlexAPIError.invalidURL
        }
        let data = try await requestData(url, headers: dvrHeaders(authToken: authToken))
        guard let container = Self.mediaContainer(from: data) else { throw PlexAPIError.parsingError }
        return Self.array(container["MediaGrabOperation"]).compactMap(Self.grab(from:))
    }

    /// Standing recording rules.
    func getSubscriptions(
        serverURL: String,
        authToken: String
    ) async throws -> [PlexSubscriptionSummary] {
        guard var components = URLComponents(string: "\(serverURL)/media/subscriptions") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "includeGrabs", value: "1")]
        guard let url = components.url else { throw PlexAPIError.invalidURL }

        let data = try await requestData(url, headers: dvrHeaders(authToken: authToken))
        guard let container = Self.mediaContainer(from: data) else { throw PlexAPIError.parsingError }
        return Self.array(container["MediaSubscription"]).compactMap { subscription in
            guard let id = Self.string(subscription["key"]) ?? Self.string(subscription["id"]) else { return nil }
            let grabs = Self.array(subscription["MediaGrabOperation"])
            return PlexSubscriptionSummary(
                id: Self.lastPathComponent(id),
                title: (subscription["title"] as? String) ?? "Recording",
                type: Self.int(subscription["type"]),
                airingsType: subscription["airingsType"] as? String,
                librarySectionTitle: subscription["librarySectionTitle"] as? String,
                scheduledCount: grabs.filter { ($0["status"] as? String) == "scheduled" }.count
            )
        }
    }

    /// Remove a recording rule, cancelling every grab it made.
    func deleteSubscription(serverURL: String, authToken: String, id: String) async throws {
        guard let url = URL(string: "\(serverURL)/media/subscriptions/\(Self.pathSafe(id))") else {
            throw PlexAPIError.invalidURL
        }
        _ = try await requestData(url, method: "DELETE", headers: dvrHeaders(authToken: authToken))
    }

    /// Cancel one scheduled or in-progress airing, leaving its rule in place.
    func cancelGrab(serverURL: String, authToken: String, operationId: String) async throws {
        guard let url = URL(string: "\(serverURL)/media/grabbers/operations/\(Self.pathSafe(operationId))") else {
            throw PlexAPIError.invalidURL
        }
        _ = try await requestData(url, method: "DELETE", headers: dvrHeaders(authToken: authToken))
    }

    // MARK: - Parsing helpers

    private func dvrHeaders(authToken: String) -> [String: String] {
        var headers = plexHeaders(authToken: authToken)
        headers["Accept"] = "application/json"
        return headers
    }

    private static func mediaContainer(from data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["MediaContainer"] as? [String: Any]
    }

    /// A JSON value that may be one object or an array of them.
    private static func array(_ value: Any?) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        if let single = value as? [String: Any] { return [single] }
        return []
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let string as String: return string == "1" || string.lowercased() == "true"
        default: return nil
        }
    }

    /// A Setting value as Plex's own clients send it back: booleans as
    /// true/false, whole numbers without a fraction.
    private static func settingString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            // JSON booleans arrive as NSNumber too; tell them apart by type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let double = number.doubleValue
            if double.rounded() == double { return String(Int(double)) }
            return number.stringValue
        default:
            return nil
        }
    }

    private static func grab(from operation: [String: Any]) -> PlexScheduledGrab? {
        guard let id = string(operation["id"]) ?? string(operation["key"]).map(lastPathComponent) else { return nil }
        let metadata = array(operation["Metadata"]).first ?? array(operation["Video"]).first ?? [:]
        let media = array(metadata["Media"]).first ?? [:]
        func date(_ value: Any?) -> Date? {
            guard let seconds = int(value), seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        let isEpisode = (metadata["type"] as? String) == "episode"
        return PlexScheduledGrab(
            id: id,
            subscriptionId: string(operation["mediaSubscriptionID"]),
            status: (operation["status"] as? String) ?? "scheduled",
            title: (metadata["title"] as? String) ?? "Recording",
            grandparentTitle: metadata["grandparentTitle"] as? String,
            guid: metadata["guid"] as? String,
            type: metadata["type"] as? String,
            beginsAt: date(media["beginsAt"]) ?? date(metadata["beginsAt"]),
            endsAt: date(media["endsAt"]) ?? date(metadata["endsAt"]),
            channelIdentifier: string(media["channelIdentifier"]),
            channelTitle: (media["channelTitle"] as? String) ?? (media["channelCallSign"] as? String),
            thumb: (isEpisode ? (metadata["grandparentThumb"] as? String) : nil) ?? (metadata["thumb"] as? String)
        )
    }

    /// Splits an already percent-encoded query into items, decoding each side
    /// once so `URLComponents` can encode it again, exactly once.
    static func queryItems(fromEncodedQuery query: String) -> [URLQueryItem] {
        let trimmed = query.hasPrefix("?") ? String(query.dropFirst()) : query
        return trimmed.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1
                ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
                : nil
            return URLQueryItem(name: name, value: value)
        }
    }

    /// "/media/subscriptions/12" and "12" both name subscription 12.
    private static func lastPathComponent(_ value: String) -> String {
        value.split(separator: "/").last.map(String.init) ?? value
    }

    private static func pathSafe(_ id: String) -> String {
        lastPathComponent(id).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }
}
