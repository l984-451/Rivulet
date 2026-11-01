// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  XtreamService.swift
//  Rivulet
//
//  Xtream Codes (XC) client for live channels: account check, channel list and
//  the guide URL. Panels disagree on JSON types (the same reply mixes `1` and
//  `"1"`), so replies are walked by hand rather than decoded into strict structs.
//

import Foundation

/// An XC panel login: the server's base URL and the account on it.
struct XtreamAccount: Sendable, Equatable {
    let server: URL
    let username: String
    let password: String
}

/// What `player_api.php` says about the account.
struct XtreamAccountInfo: Sendable, Equatable {
    let expiresAt: Date?
    let maxConnections: Int?
    let activeConnections: Int?
    let allowedFormats: [String]
}

enum XtreamError: Error, Equatable {
    case invalidLogin
    case expired
    case banned
    case disabled
    /// The address answered, but with a web page or something else that isn't
    /// an XC reply.
    case notXtream
    /// A refusal that carried the panel's own reason as text.
    case refused(String)
    case httpError(Int)
}

actor XtreamService {
    let account: XtreamAccount
    let session: URLSession

    init(account: XtreamAccount, session: URLSession? = nil) {
        self.account = account
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = LiveTVClientIdentity.streamHeaders
        self.session = session ?? URLSession(configuration: config)
    }

    // MARK: Address

    /// Splits what a user typed or pasted into the panel's base URL and any login
    /// it carried. A pasted `.../get.php?username=…&password=…` link is the usual
    /// way providers hand these out, so the endpoint and query are cut off and the
    /// login returned for the form to fill in. A path before the endpoint is kept.
    nonisolated static func parseAddress(_ input: String) -> (server: String, username: String?, password: String?) {
        let cleaned = sanitizeURL(input)
        guard !cleaned.isEmpty, var components = URLComponents(string: cleaned) else { return (cleaned, nil, nil) }
        let query = components.queryItems ?? []
        func item(_ name: String) -> String? {
            query.first { $0.name.lowercased() == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        var path = components.path
        for endpoint in ["/player_api.php", "/get.php", "/xmltv.php", "/panel_api.php"] {
            if let range = path.range(of: endpoint, options: .caseInsensitive) {
                path = String(path[..<range.lowerBound])
                break
            }
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        components.query = nil
        components.fragment = nil
        return (components.string ?? cleaned, item("username"), item("password"))
    }

    // MARK: URLs

    nonisolated var guideURL: URL {
        endpoint("xmltv.php", query: [])
    }

    /// `/live/<user>/<pass>/<id>.<ext>`. Each part is one escaped path segment, so
    /// a password holding `/` or `?` cannot change the path.
    nonisolated func streamURL(streamId: String, format: String) -> URL {
        // `appending(component:)` escapes `/`; `appendingPathComponent` does not.
        account.server
            .appending(component: "live")
            .appending(component: account.username)
            .appending(component: account.password)
            .appending(component: "\(streamId).\(format)")
    }

    /// `ts` unless the account rules it out. AetherEngine demuxes TS directly, and
    /// Dispatcharr answers `.m3u8` with TS anyway.
    nonisolated static func streamFormat(allowed: [String]) -> String {
        let allowed = allowed.map { $0.lowercased() }
        if allowed.isEmpty || allowed.contains("ts") { return "ts" }
        return allowed.contains("m3u8") ? "m3u8" : "ts"
    }

    private nonisolated func endpoint(_ name: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: account.server.appendingPathComponent(name),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "username", value: account.username),
                                 URLQueryItem(name: "password", value: account.password)] + query
        // `+` is a space to PHP's query parser, so a literal one must be escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    // MARK: Requests

    /// Checks the login. Asked with no `action`, since some panels answer an
    /// empty `action=` with nothing at all.
    func verify() async throws -> XtreamAccountInfo {
        try Self.accountInfo(from: await json(endpoint("player_api.php", query: [])))
    }

    /// Live channels with their categories as groups, ready for the shared
    /// channel pipeline. A category list that fails only costs the groups.
    func fetchChannels(format: String) async throws -> [M3UParser.ParsedChannel] {
        async let streams = json(endpoint("player_api.php", query: [URLQueryItem(name: "action", value: "get_live_streams")]))
        let categories = try? await json(endpoint("player_api.php",
                                                   query: [URLQueryItem(name: "action", value: "get_live_categories")]))
        return Self.channels(from: try await streams, categories: categories, service: self, format: format)
    }

    private func json(_ url: URL) async throws -> Any {
        let (data, response) = try await BoundedDownload.data(for: URLRequest(url: url),
                                                              limit: BoundedDownload.playlistLimit,
                                                              configuration: session.configuration)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return try Self.parse(data, status: status)
    }

    // MARK: Decoding

    /// The reply as JSON, or the error its status and body describe. Never puts
    /// the body in an error: `player_api.php` echoes the password back.
    nonisolated static func parse(_ data: Data, status: Int) throws -> Any {
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        switch status {
        case 200...299:
            guard let value = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
                  value is [Any] || value is [String: Any] || value is Bool || value is NSNull else {
                throw XtreamError.notXtream
            }
            return value
        case 401, 404, 513:
            // Dispatcharr: 404 unknown user, 401 wrong password. XUI panels: 513, empty body.
            throw XtreamError.invalidLogin
        case 403:
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.count <= 200, !text.contains("<"), !text.hasPrefix("{") {
                throw XtreamError.refused(text)
            }
            throw XtreamError.invalidLogin
        default:
            throw XtreamError.httpError(status)
        }
    }

    nonisolated static func accountInfo(from json: Any, now: Date = Date()) throws -> XtreamAccountInfo {
        guard let root = json as? [String: Any], let user = root["user_info"] as? [String: Any] else {
            throw XtreamError.notXtream
        }
        guard int(user["auth"]) == 1 else { throw XtreamError.invalidLogin }
        switch string(user["status"])?.lowercased() {
        case "banned": throw XtreamError.banned
        case "disabled": throw XtreamError.disabled
        case "expired": throw XtreamError.expired
        default: break
        }
        // 0, "" and null all mean an account with no end date.
        let expiry = int(user["exp_date"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        if let expiry, expiry < now { throw XtreamError.expired }
        return XtreamAccountInfo(expiresAt: expiry,
                                 maxConnections: int(user["max_connections"]),
                                 activeConnections: int(user["active_cons"]),
                                 allowedFormats: (user["allowed_output_formats"] as? [Any])?.compactMap(string) ?? [])
    }

    /// One malformed entry is skipped, not the whole list. Panels send `[]`,
    /// `{}`, `false` or `null` for an empty list.
    nonisolated static func channels(from streams: Any, categories: Any?, service: XtreamService,
                                     format: String) -> [M3UParser.ParsedChannel] {
        var groups: [String: String] = [:]
        for category in categories as? [[String: Any]] ?? [] {
            if let id = string(category["category_id"]), let name = string(category["category_name"]) {
                groups[id] = groups[id] ?? name
            }
        }
        return (streams as? [[String: Any]] ?? []).compactMap { stream in
            // Panels list radio stations as live streams too.
            guard string(stream["stream_type"]) != "radio_streams",
                  let id = string(stream["stream_id"]),
                  let name = string(stream["name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !isSectionHeader(name) else { return nil }
            let number = double(stream["num"]).flatMap { $0 >= 0 && $0 == $0.rounded() ? ChannelNumber(major: Int($0)) : nil }
            return M3UParser.ParsedChannel(
                tvgId: string(stream["epg_channel_id"]),
                tvgName: nil,
                tvgLogo: string(stream["stream_icon"]),
                groupTitle: string(stream["category_id"]).flatMap { groups[$0] },
                channelNumber: number,
                name: name,
                streamURL: service.streamURL(streamId: id, format: format),
                // The panel's id: unlike epg_channel_id it survives renumbering.
                key: "xc\(id)")
        }
    }

    /// Panels pad their lists with dead entries named like `##### 4K UHD #####`
    /// to head each section.
    nonisolated static func isSectionHeader(_ name: String) -> Bool {
        name.hasPrefix("###") || name.hasPrefix("===") || name.hasPrefix("***")
    }

    /// A non-empty string from a string or a number.
    nonisolated static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    nonisolated static func double(_ value: Any?) -> Double? {
        switch value {
        case let string as String: Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        case let number as NSNumber: number.doubleValue
        default: nil
        }
    }

    nonisolated static func int(_ value: Any?) -> Int? {
        double(value).flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil }
    }
}
