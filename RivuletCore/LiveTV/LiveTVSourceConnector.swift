// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVSourceConnector.swift
//  Rivulet
//
//  Verify-then-add for the three Live TV source kinds, shared by every add-source
//  UI. A source is added only after its check passed; a failure throws the copy
//  to show. Each kind has a synchronous form check (`*Request`) and an async
//  `connect`, so a form can fail fast before it shows a busy state.
//

import Foundation

/// Why a source could not be added, in the words the user sees.
struct LiveTVConnectError: LocalizedError, Equatable {
    let title: String
    let message: String

    var errorDescription: String? { message }

    static func source(_ message: String) -> LiveTVConnectError {
        LiveTVConnectError(title: "Couldn't Add Source", message: message)
    }

    static func plex(_ message: String) -> LiveTVConnectError {
        LiveTVConnectError(title: "Couldn't Add Plex Live TV", message: message)
    }
}

struct LiveTVSourceConnector {
    struct PlexRequest {
        let serverURL: String
        let token: String
        let serverName: String
    }

    struct ServerRequest {
        let baseURL: URL
        let channelProfile: String?
        let username: String
        let password: String
        let service: DispatcharrService
    }

    struct PlaylistRequest {
        let m3uURL: URL
        let epgURL: URL?
    }

    static let defaultServerName = "Live TV"
    static let defaultPlaylistName = "IPTV"

    /// For tests. nil uses each request's usual session.
    var session: URLSession?

    init(session: URLSession? = nil) {
        self.session = session
    }

    // MARK: Plex

    static func plexRequest() throws -> PlexRequest {
        let auth = PlexAuthManager.shared
        guard let serverURL = auth.selectedServerURL,
              let token = auth.selectedServerToken,
              let serverName = auth.savedServerName else {
            throw LiveTVConnectError.plex("Plex server is not connected.")
        }
        return PlexRequest(serverURL: serverURL, token: token, serverName: serverName)
    }

    func connect(_ request: PlexRequest) async throws {
        guard await PlexLiveTVProvider.checkAvailability(serverURL: request.serverURL, authToken: request.token) else {
            throw LiveTVConnectError.plex("No DVR or tuners are set up on this Plex server.")
        }
        let store = LiveTVDataStore.shared
        await store.addPlexSource(provider: PlexLiveTVProvider(serverURL: request.serverURL, authToken: request.token,
                                                               serverName: request.serverName))
        await Self.load(store)
    }

    // MARK: Own server (Dispatcharr)

    func serverRequest(address: String, username: String, password: String,
                       channelProfile: String) throws -> ServerRequest {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveTVConnectError.source("Enter your server's address first.")
        }
        let cleaned = sanitizeURL(address)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.isEmpty == password.isEmpty else {
            throw LiveTVConnectError.source("Enter both your username and password, or neither.")
        }
        // A typed profile wins; otherwise one pasted as .../output/m3u/Kids is kept,
        // since Dispatcharr scopes the playlist only by that path segment.
        let split = DispatcharrService.splitEndpointPath(from: cleaned)
        let profile = DispatcharrService.normalizedProfile(channelProfile) ?? split.channelProfile
        guard let url = URL(string: split.baseURL) else {
            throw LiveTVConnectError.source("Couldn't reach that server. Check the address and port.")
        }
        return ServerRequest(baseURL: url, channelProfile: profile, username: username, password: password,
                             service: DispatcharrService(baseURL: url, channelProfile: profile, session: session))
    }

    func connect(_ request: ServerRequest, name: String) async throws {
        let channels: [M3UParser.ParsedChannel]
        do {
            channels = try await request.service.fetchChannels()
        } catch {
            throw LiveTVConnectError.source(Self.failureCopy(for: error))
        }
        guard !channels.isEmpty else {
            // An empty playlist with a profile set is nearly always a profile
            // name the server does not have, so point at the field.
            throw LiveTVConnectError.source(request.channelProfile == nil
                ? "Connected, but found no channels."
                : "Connected, but that channel profile has no channels. Check the name.")
        }
        // Watching needs no sign-in; recording does. The sign-in is traded for
        // the user's API key here and the password dropped.
        var token: String?
        if !request.username.isEmpty {
            do {
                token = try await request.service.fetchAPIKey(username: request.username, password: request.password)
            } catch {
                throw LiveTVConnectError.source(Self.signInFailureCopy(for: error))
            }
        }
        let store = LiveTVDataStore.shared
        await store.addDispatcharrSource(baseURL: request.baseURL, name: name.isEmpty ? Self.defaultServerName : name,
                                         apiToken: token, channelProfile: request.channelProfile)
        await Self.load(store)
    }

    // MARK: Playlist URL

    static func playlistRequest(m3uURL: String, epgURL: String) throws -> PlaylistRequest {
        guard !m3uURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveTVConnectError.source("Enter your playlist URL first.")
        }
        guard let m3u = URL(string: sanitizeURL(m3uURL)) else {
            throw LiveTVConnectError.source("That playlist URL doesn't look right. Check it and try again.")
        }
        return PlaylistRequest(m3uURL: m3u, epgURL: epgURL.isEmpty ? nil : URL(string: sanitizeURL(epgURL)))
    }

    func connect(_ request: PlaylistRequest, name: String) async throws {
        do {
            // The same parse the source itself uses, so a playlist that passes
            // here is one that will load.
            let (data, response) = try await (session ?? .shared).data(from: request.m3uURL)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200...299: break
                case 401, 403: throw DispatcharrError.unauthorized
                default: throw DispatcharrError.httpError(http.statusCode)
                }
            }
            let channels = try await M3UParser().parse(data: data)
            guard !channels.isEmpty else {
                throw LiveTVConnectError.source("Connected, but found no channels.")
            }
        } catch let error as LiveTVConnectError {
            throw error
        } catch {
            throw LiveTVConnectError.source(Self.failureCopy(for: error))
        }
        let store = LiveTVDataStore.shared
        await store.addM3USource(m3uURL: request.m3uURL, epgURL: request.epgURL,
                                 name: name.isEmpty ? Self.defaultPlaylistName : name)
        await Self.load(store)
    }

    // MARK: Shared

    private static func load(_ store: LiveTVDataStore) async {
        await store.loadChannels()
        await store.loadEPG(startDate: Date(), hours: 6)
    }

    /// The failure collapsed to one of three causes the user can act on.
    static func failureCopy(for error: Error) -> String {
        if let dispatcharr = error as? DispatcharrError {
            switch dispatcharr {
            case .unauthorized: return "That server refused Rivulet."
            case .invalidResponse, .notFound, .serverError, .httpError:
                return "Couldn't reach that server. Check the address and port."
            }
        }
        if error is M3UParseError {
            return "Connected, but found no channels."
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorUserAuthenticationRequired {
            return "That server refused Rivulet."
        }
        return "Couldn't reach that server. Check the address and port."
    }

    /// The channels already loaded, so the server is reachable: what failed is
    /// the sign-in itself.
    static func signInFailureCopy(for error: Error) -> String {
        switch error as? DispatcharrError {
        case .unauthorized:
            return "Dispatcharr didn't accept that username and password."
        case .notFound:
            return "That server has no Dispatcharr sign-in. Clear the username and password."
        case .httpError(429):
            return "Too many sign-in attempts. Wait a minute and try again."
        default:
            return "Couldn't sign in to Dispatcharr. Try again."
        }
    }

    // MARK: Server address suggestions

    /// Host for the address placeholder and presets: the Plex server's when it
    /// is on the local network, since many run both on one box.
    static var suggestedHost: String {
        suggestedHost(plexServerURL: PlexAuthManager.shared.selectedServerURL)
    }

    static func suggestedHost(plexServerURL: String?) -> String {
        if let host = plexServerURL.flatMap(URL.init(string:))?.host, isLocalIP(host) {
            return host
        }
        return "192.168.1.100"
    }

    /// One-press fills for the server address, by app.
    static func serverSuggestions(host: String) -> [(label: String, value: String)] {
        [
            ("Dispatcharr", "http://\(host):9191"),
            ("Threadfin", "http://\(host):34400"),
            ("xTeVe", "http://\(host):34400"),
            ("ErsatzTV", "http://\(host):8409"),
            ("Cabernet", "http://\(host):6077")
        ]
    }

    private static func isLocalIP(_ host: String) -> Bool {
        host.hasPrefix("192.168.") || host.hasPrefix("10.") ||
        host.hasPrefix("172.16.") || host.hasPrefix("172.17.") ||
        host.hasPrefix("172.18.") || host.hasPrefix("172.19.") ||
        host.hasPrefix("172.2") || host.hasPrefix("172.30.") ||
        host.hasPrefix("172.31.") || host == "localhost" || host == "127.0.0.1"
    }
}

/// Fixes the URL typos a TV keyboard invites (doubled schemes, `htpp://`),
/// forces a scheme, and drops a trailing slash.
func sanitizeURL(_ input: String) -> String {
    var url = input.trimmingCharacters(in: .whitespacesAndNewlines)

    // Empty in, empty out: otherwise "" becomes "http:/", which reads as a
    // filled-in field and defeats every isEmpty check.
    guard !url.isEmpty else { return "" }

    let typoPatterns = [
        "http://http://", "https://https://",
        "http://https://", "https://http://",
        "hhttp://", "htttp://", "hhtp://", "htpp://",
        "httpss://", "htps://"
    ]

    for typo in typoPatterns {
        if url.lowercased().hasPrefix(typo) {
            let isSecure = typo.contains("https") || url.lowercased().hasPrefix("https")
            let correctProtocol = isSecure ? "https://" : "http://"
            url = correctProtocol + String(url.dropFirst(typo.count))
            break
        }
    }

    if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
        url = "http://" + url
    }

    if url.hasSuffix("/") {
        url = String(url.dropLast())
    }

    return url
}
