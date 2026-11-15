// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TvheadendService.swift
//  Rivulet
//
//  Tvheadend client: server check, channels, guide and stream URLs over its JSON
//  API. The login answers Tvheadend's Digest challenge and never goes in a URL;
//  signed-in streams use a ticketed URL fetched just before each play.
//

import Foundation

/// A Tvheadend server and, unless it allows anonymous streaming, a login on it.
nonisolated struct TvheadendAccount: Sendable, Equatable {
    let server: URL
    let username: String?
    let password: String?

    var isSignedIn: Bool { username != nil }

    var credential: URLCredential? {
        username.map { URLCredential(user: $0, password: password ?? "", persistence: .forSession) }
    }
}

enum TvheadendError: LocalizedError, Equatable {
    /// The server needs a login and none was given.
    case loginRequired
    case invalidLogin
    /// Signed in, but the user lacks the right this call needs.
    case forbidden
    case notTvheadend
    /// The ticket playlist held no stream.
    case noTicket
    case httpError(Int)

    /// nil for an HTTP error, which callers describe as unreachable.
    var errorDescription: String? {
        switch self {
        case .loginRequired: String(localized: "This Tvheadend server needs a username and password.")
        case .invalidLogin: String(localized: "Tvheadend didn't accept that username and password.")
        // Tvheadend also answers a changed password with 403 once signed in.
        case .forbidden: String(localized: "Tvheadend refused this user. Check its password and rights in Tvheadend.")
        case .notTvheadend: String(localized: "That address isn't a Tvheadend server. Check the address and port.")
        case .noTicket: String(localized: "Tvheadend didn't give Rivulet a stream for this user. Check its streaming rights, or update Tvheadend.")
        case .httpError: nil
        }
    }
}

struct TvheadendChannel: Sendable, Equatable {
    let uuid: String
    let name: String
    let number: ChannelNumber?
    let iconURL: URL?
    let group: String?
}

struct TvheadendEvent: Sendable, Equatable {
    let eventId: Int
    let channelUUID: String
    let start: Date
    let stop: Date
    let title: String
    let subtitle: String?
    let description: String?
    /// Tvheadend's on-screen episode text ("S14 E18").
    let episode: String?
    let seriesLink: String?
    let isNew: Bool
    let imageURL: URL?
    /// Tvheadend's `copyright_year`; read only when there is no episode text.
    var year: Int? = nil
}

actor TvheadendService {
    let account: TvheadendAccount
    let session: URLSession

    init(account: TvheadendAccount, session: URLSession? = nil) {
        self.account = account
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = LiveTVClientIdentity.streamHeaders
        self.session = session ?? URLSession(configuration: config)
    }

    // MARK: URLs

    nonisolated func streamURL(channelUUID: String) -> URL {
        url("stream/channel/\(channelUUID)", ["profile": "pass"])
    }

    nonisolated func url(_ path: String, _ query: KeyValuePairs<String, String> = [:]) -> URL {
        var components = URLComponents(url: account.server.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    // MARK: Requests

    /// Passes when the address answers as Tvheadend. Every valid user may read
    /// serverinfo, so a 403 here means the login itself was refused.
    func verify() async throws {
        let info = try await json(url("api/serverinfo"), loginCheck: true)
        guard (info as? [String: Any])?["sw_version"] != nil else { throw TvheadendError.notTvheadend }
    }

    /// Enabled channels. A tag list that fails only costs the groups.
    func fetchChannels() async throws -> [TvheadendChannel] {
        async let grid = json(url("api/channel/grid", ["limit": "10000"]))
        let tags = try? await json(url("api/channeltag/grid", ["limit": "1000"]))
        return Self.channels(from: try await grid, tags: tags, server: account.server, signedIn: account.isSignedIn)
    }

    /// The guide airing between `from` and `to`, earliest first. A DVB guide runs
    /// to two weeks, so asking for all of it would hold tens of megabytes of JSON.
    func fetchEvents(from: Date, to: Date) async throws -> [TvheadendEvent] {
        Self.events(from: try await json(eventsURL(from: from, to: to), limit: BoundedDownload.guideLimit))
    }

    nonisolated func eventsURL(from: Date, to: Date) -> URL {
        let clauses: [[String: Any]] = [
            ["field": "stop", "type": "numeric", "comparison": "gt", "value": Int(from.timeIntervalSince1970)],
            ["field": "start", "type": "numeric", "comparison": "lt", "value": Int(to.timeIntervalSince1970)]
        ]
        let filter = String(decoding: (try? JSONSerialization.data(withJSONObject: clauses, options: [.sortedKeys])) ?? Data(),
                            as: UTF8.self)
        return url("api/epg/events/grid", ["limit": "50000", "sort": "start", "dir": "ASC", "filter": filter])
    }

    /// A stream URL carrying a fresh ticket. Tickets expire after five minutes,
    /// so this is fetched for every play and never cached.
    func ticketedStreamURL(channelUUID: String) async throws -> URL {
        let data = try await fetch(url("playlist/ticket/channel/\(channelUUID)"), limit: BoundedDownload.playlistLimit)
        guard let url = Self.ticketURL(fromPlaylist: data, server: account.server) else {
            throw TvheadendError.noTicket
        }
        return url
    }

    func json(_ url: URL, loginCheck: Bool = false, limit: Int = BoundedDownload.playlistLimit) async throws -> Any {
        let (data, response) = try await BoundedDownload.data(for: URLRequest(url: url), limit: limit,
                                                              configuration: session.configuration,
                                                              credential: account.credential)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        return try Self.parse(data, status: status, signedIn: account.isSignedIn, loginCheck: loginCheck)
    }

    /// A form POST to the API. Tvheadend answers some writes with an empty body.
    func post(_ path: String, _ form: [String: String]) async throws -> Any? {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)
        let (data, response) = try await BoundedDownload.data(for: request, limit: BoundedDownload.playlistLimit,
                                                              configuration: session.configuration,
                                                              credential: account.credential)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if (200...299).contains(status), data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D }) { return nil }
        return try Self.parse(data, status: status, signedIn: account.isSignedIn)
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        let (data, response) = try await BoundedDownload.data(for: URLRequest(url: url), limit: limit,
                                                              configuration: session.configuration,
                                                              credential: account.credential)
        try Self.check((response as? HTTPURLResponse)?.statusCode ?? 200, signedIn: account.isSignedIn)
        return data
    }

    /// `application/x-www-form-urlencoded`, escaping everything but unreserved
    /// characters: a title's `&`, `=` or `+` must not split the form.
    nonisolated static func formBody(_ form: [String: String]) -> Data {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        return Data(form.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&").utf8)
    }

    // MARK: Decoding

    /// The reply as JSON, or the error its status describes. Never puts the body
    /// in an error.
    nonisolated static func parse(_ data: Data, status: Int, signedIn: Bool, loginCheck: Bool = false) throws -> Any {
        try check(status, signedIn: signedIn, loginCheck: loginCheck)
        guard let value = try? JSONSerialization.jsonObject(with: data), value is [String: Any] else {
            throw TvheadendError.notTvheadend
        }
        return value
    }

    /// Tvheadend answers a missing login with 401 and a refused one with 403.
    nonisolated static func check(_ status: Int, signedIn: Bool, loginCheck: Bool = false) throws {
        switch status {
        case 200...299: return
        case 401: throw signedIn ? TvheadendError.invalidLogin : TvheadendError.loginRequired
        case 403: throw signedIn && loginCheck ? TvheadendError.invalidLogin : TvheadendError.forbidden
        default: throw TvheadendError.httpError(status)
        }
    }

    /// Enabled channels in grid order. The group is the first tag that is not on
    /// every channel: Tvheadend's type and provider tags are, so they say nothing.
    nonisolated static func channels(from grid: Any, tags: Any?, server: URL, signedIn: Bool) -> [TvheadendChannel] {
        let entries = ((grid as? [String: Any])?["entries"] as? [[String: Any]] ?? [])
            .filter { $0["enabled"] as? Bool != false }
        let tagLists = entries.map { Set($0["tags"] as? [String] ?? []) }
        let everywhere = tagLists.dropFirst().reduce(tagLists.first ?? []) { $0.intersection($1) }
        let tagNames: [(uuid: String, name: String)] = ((tags as? [String: Any])?["entries"] as? [[String: Any]] ?? [])
            .compactMap { tag in
                guard tag["enabled"] as? Bool != false, tag["internal"] as? Bool != true,
                      let uuid = string(tag["uuid"]), let name = string(tag["name"]),
                      !everywhere.contains(uuid) else { return nil }
                return (uuid, name)
            }

        return zip(entries, tagLists).compactMap { entry, channelTags in
            guard let uuid = string(entry["uuid"]), let name = string(entry["name"]) else { return nil }
            let number = (entry["number"] as? NSNumber).flatMap { ChannelNumber($0.stringValue) }.flatMap { $0.major > 0 ? $0 : nil }
            return TvheadendChannel(uuid: uuid, name: name, number: number,
                                    iconURL: icon(entry, server: server, signedIn: signedIn),
                                    group: tagNames.first { channelTags.contains($0.uuid) }?.name)
        }
    }

    /// The channel's own web icon, else Tvheadend's copy. The imagecache needs the
    /// login, which the image loader does not send, so signed-in sources skip it.
    private nonisolated static func icon(_ entry: [String: Any], server: URL, signedIn: Bool) -> URL? {
        for candidate in [string(entry["icon"]), string(entry["icon_public_url"])].compactMap({ $0 }) {
            let lower = candidate.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: candidate) }
        }
        guard !signedIn, let cached = string(entry["icon_public_url"]), cached.hasPrefix("imagecache/") else { return nil }
        return server.appending(path: cached)
    }

    nonisolated static func events(from grid: Any) -> [TvheadendEvent] {
        ((grid as? [String: Any])?["entries"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let eventId = (entry["eventId"] as? NSNumber)?.intValue,
                  let channel = string(entry["channelUuid"]),
                  let start = (entry["start"] as? NSNumber)?.doubleValue,
                  let stop = (entry["stop"] as? NSNumber)?.doubleValue, stop > start,
                  let title = string(entry["title"]) else { return nil }
            var year: Int?
            if string(entry["episodeOnscreen"]) == nil, let value = (entry["copyright_year"] as? NSNumber)?.intValue, value > 0 {
                year = value
            }
            return TvheadendEvent(eventId: eventId, channelUUID: channel,
                                  start: Date(timeIntervalSince1970: start), stop: Date(timeIntervalSince1970: stop),
                                  title: title, subtitle: string(entry["subtitle"]),
                                  description: string(entry["description"]) ?? string(entry["summary"]),
                                  episode: string(entry["episodeOnscreen"]),
                                  seriesLink: string(entry["serieslinkUri"]),
                                  isNew: (entry["new"] as? NSNumber)?.boolValue ?? false,
                                  // XMLTV-fed guides keep the feed's `&amp;`.
                                  // Only absolute URLs: the imagecache copy needs a login the loader lacks.
                                  imageURL: string(entry["image"]).flatMap {
                                      URL(string: $0.replacingOccurrences(of: "&amp;", with: "&"))
                                  }.flatMap { $0.scheme?.lowercased().hasPrefix("http") == true ? $0 : nil },
                                  year: year)
        }
    }

    /// The first stream line of a ticket playlist, resolved against the server.
    nonisolated static func ticketURL(fromPlaylist data: Data, server: URL) -> URL? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { URL(string: $0, relativeTo: server)?.absoluteURL }
    }

    nonisolated static func string(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }
}
