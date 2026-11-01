// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DispatcharrService.swift
//  Rivulet
//
//  Service for interacting with Dispatcharr IPTV server
//  Dispatcharr provides M3U and XMLTV EPG endpoints at /output/m3u and /output/epg
//

import Foundation

/// Service for fetching data from a Dispatcharr server
actor DispatcharrService {

    // MARK: - Properties

    let baseURL: URL
    let apiToken: String?

    /// Dispatcharr channel profile for the playlist and guide, or nil for every
    /// channel. It is a path segment (`m3u/<profile>`); the API key does not scope
    /// output (#246).
    let channelProfile: String?

    let session: URLSession

    // MARK: - Initialization

    init(baseURL: URL, apiToken: String? = nil, channelProfile: String? = nil,
         session: URLSession? = nil) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.channelProfile = Self.normalizedProfile(channelProfile)

        // Configure session with reasonable timeouts for potentially large M3U/EPG files
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120  // EPG files can be large
        self.session = session ?? URLSession(configuration: config)
    }

    /// Create a DispatcharrService from a URL string, cleaning up the URL if needed
    ///
    /// An explicit `channelProfile` always wins. When none is passed, a profile
    /// found in the pasted URL is adopted, because a user who pastes
    /// `.../output/m3u/Kids` is telling us exactly which profile they want, and
    /// silently discarding it is what made every channel come back (issue #246).
    static func create(from urlString: String, apiToken: String? = nil,
                       channelProfile: String? = nil) -> DispatcharrService? {
        let split = splitEndpointPath(from: urlString)
        guard let url = URL(string: split.baseURL) else {
            return nil
        }
        let profile = normalizedProfile(channelProfile) ?? split.channelProfile
        return DispatcharrService(baseURL: url, apiToken: apiToken, channelProfile: profile)
    }

    /// Splits a pasted address into the server base URL and the channel profile
    /// after `/output/m3u` or `/output/epg`. Keep that trailing segment (#246).
    static func splitEndpointPath(from urlString: String) -> (baseURL: String, channelProfile: String?) {
        // Clean up the URL string
        var cleanedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing slash if present
        if cleanedURL.hasSuffix("/") {
            cleanedURL = String(cleanedURL.dropLast())
        }

        // Add http:// if no scheme
        if !cleanedURL.hasPrefix("http://") && !cleanedURL.hasPrefix("https://") {
            cleanedURL = "http://\(cleanedURL)"
        }

        for endpoint in ["/output/m3u", "/output/epg"] {
            guard let range = cleanedURL.range(of: endpoint, options: .caseInsensitive) else { continue }

            let base = String(cleanedURL[..<range.lowerBound])
            var remainder = String(cleanedURL[range.upperBound...])

            // A query string or fragment is not part of the profile name, and
            // Dispatcharr's route matches a single segment, so anything past the
            // next slash is not ours to interpret.
            if let cut = remainder.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                remainder = String(remainder[..<cut])
            }
            let segment = remainder.split(separator: "/", omittingEmptySubsequences: true)
                .first.map(String.init)

            // A pasted profile arrives percent-encoded, because that is how a
            // browser hands back a name containing a space. Decode it here so
            // exactly one encode happens at request time and "Kids%20TV" does
            // not become the double-encoded "Kids%2520TV".
            return (base, normalizedProfile(segment?.removingPercentEncoding ?? segment))
        }

        return (cleanedURL, nil)
    }

    /// Trims a profile name and treats whitespace-only as no profile at all, so a
    /// user who opens the field and backs out does not get an empty path segment.
    static func normalizedProfile(_ profile: String?) -> String? {
        guard let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Public Methods

    /// Fetch the M3U playlist from Dispatcharr
    /// - Returns: Raw M3U data
    func fetchM3U() async throws -> Data {
        let url = m3uURL
        let request = authenticatedRequest(for: url)

        let (data, response) = try await BoundedDownload.data(
            for: request, limit: BoundedDownload.playlistLimit, configuration: session.configuration)

        try validateResponse(response)

        return data
    }

    /// Fetch the XMLTV EPG from Dispatcharr
    /// - Returns: Raw XMLTV data
    func fetchEPG() async throws -> Data {
        let url = epgURL
        let request = authenticatedRequest(for: url)

        let (data, response) = try await BoundedDownload.data(
            for: request, limit: BoundedDownload.guideLimit, configuration: session.configuration)

        try validateResponse(response)

        return data
    }

    /// Check if the Dispatcharr server is reachable and responding
    /// - Returns: Status information about the server
    func getStatus() async throws -> DispatcharrStatus {
        // Try to fetch a small portion of the M3U to verify connectivity
        let request = authenticatedRequest(for: m3uURL, method: "HEAD")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DispatcharrError.invalidResponse
        }

        let isAvailable = (200...299).contains(httpResponse.statusCode)

        return DispatcharrStatus(
            baseURL: baseURL,
            isAvailable: isAvailable,
            statusCode: httpResponse.statusCode,
            checkedAt: Date()
        )
    }

    /// Fetch and parse channels from Dispatcharr
    /// - Returns: Parsed channels ready for use
    func fetchChannels() async throws -> [M3UParser.ParsedChannel] {
        let data = try await fetchM3U()
        let parser = M3UParser()
        return try await parser.parse(data: data)
    }

    /// Fetch and parse EPG from Dispatcharr
    /// - Returns: Parsed EPG data
    func fetchParsedEPG(filter: XMLTVParser.GuideFilter? = nil) async throws -> XMLTVParser.ParseResult {
        let data = try await fetchEPG()
        let parser = XMLTVParser()
        return try await parser.parse(data: data, filter: filter)
    }

    /// Signs in as a Dispatcharr user and returns that user's API key, so
    /// nobody types a 54-character key on a TV remote. The password is used
    /// for this exchange only and never stored.
    ///
    /// A key is created only when the account has none: Dispatcharr's
    /// generate REPLACES the user's key, which would break every other app
    /// already using it.
    func fetchAPIKey(username: String, password: String) async throws -> String {
        struct Tokens: Decodable { let access: String }
        struct Key: Decodable { let key: String? }

        var login = URLRequest(url: baseURL.appendingPathComponent("api/accounts/token", isDirectory: true))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        let (tokenData, tokenResponse) = try await session.data(for: login)
        try validateResponse(tokenResponse)
        let access = try JSONDecoder().decode(Tokens.self, from: tokenData).access

        func keyRequest(_ path: String, method: String) -> URLRequest {
            var request = URLRequest(url: baseURL.appendingPathComponent(path, isDirectory: true))
            request.httpMethod = method
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            return request
        }
        let (data, response) = try await session.data(for: keyRequest("api/accounts/api-keys", method: "GET"))
        try validateResponse(response)
        if let key = try JSONDecoder().decode(Key.self, from: data).key, !key.isEmpty {
            return key
        }
        let (newData, newResponse) = try await session.data(
            for: keyRequest("api/accounts/api-keys/generate", method: "POST"))
        try validateResponse(newResponse)
        guard let key = try JSONDecoder().decode(Key.self, from: newData).key, !key.isEmpty else {
            throw DispatcharrError.invalidResponse
        }
        return key
    }

    // MARK: - Stream switching (#369)

    /// The channel's streams in failover order, with the one playing now.
    /// Needs an admin user's key: Dispatcharr answers 403 to anyone else.
    func channelStreams(channelUUID: String) async throws -> DispatcharrChannelStreams {
        struct Channel: Decodable { let id: Int }
        struct Account: Decodable { let id: Int; let name: String }
        struct Status: Decodable { let streamId: Int? }

        var lookup = authenticatedRequest(
            for: baseURL.appendingPathComponent("api/channels/channels/by-uuids", isDirectory: true), method: "POST")
        lookup.setValue("application/json", forHTTPHeaderField: "Content-Type")
        lookup.httpBody = try JSONEncoder().encode(["uuids": [channelUUID]])
        guard let channelID = try await decode([Channel].self, lookup).first?.id else {
            throw DispatcharrError.notFound
        }

        let streams = try await decode([DispatcharrStream].self, authenticatedRequest(
            for: baseURL.appendingPathComponent("api/channels/channels/\(channelID)/streams", isDirectory: true)))
        // Names only label the rows, and a stopped channel has no status.
        let accounts = (try? await decode([Account].self, authenticatedRequest(
            for: baseURL.appendingPathComponent("api/m3u/accounts", isDirectory: true)))) ?? []
        let status = try? await decode(Status.self, authenticatedRequest(
            for: baseURL.appendingPathComponent("proxy/ts/status/\(channelUUID)")))

        return DispatcharrChannelStreams(
            streams: streams,
            accountNames: Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
            currentStreamID: status?.streamId)
    }

    /// Moves a running channel onto another of its streams, for every viewer of it.
    func switchStream(channelUUID: String, to streamID: Int) async throws {
        var request = authenticatedRequest(
            for: baseURL.appendingPathComponent("proxy/ts/change_stream/\(channelUUID)"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["stream_id": streamID])
        // The reply echoes the provider URL, which carries credentials: never log it.
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    /// The channel uuid in a `/proxy/ts/stream/<uuid>` URL. Xtream-form URLs have none.
    static func channelUUID(fromStreamURL url: URL) -> String? {
        let parts = url.pathComponents
        guard parts.count >= 2, parts[parts.count - 2] == "stream",
              parts.dropLast(2).last == "ts", UUID(uuidString: parts[parts.count - 1]) != nil
        else { return nil }
        return parts[parts.count - 1]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    // MARK: - Private Methods

    func authenticatedRequest(for url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(LiveTVClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if let token = apiToken, let header = Self.authorizationHeader(for: token) {
            request.setValue(header.value, forHTTPHeaderField: header.field)
        }
        return request
    }

    /// How Dispatcharr wants `token` presented: an API key as `X-API-Key`, or a
    /// JWT as `Authorization: Bearer`. It never accepts DRF's `Authorization: Token`.
    static func authorizationHeader(for token: String) -> (field: String, value: String)? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if segments.count == 3, trimmed.hasPrefix("eyJ") {
            return ("Authorization", "Bearer \(trimmed)")
        }
        return ("X-API-Key", trimmed)
    }

    func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DispatcharrError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return  // Success
        case 401, 403:
            throw DispatcharrError.unauthorized
        case 404:
            throw DispatcharrError.notFound
        case 500...599:
            throw DispatcharrError.serverError(httpResponse.statusCode)
        default:
            throw DispatcharrError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - Status

struct DispatcharrStatus: Sendable {
    let baseURL: URL
    let isAvailable: Bool
    let statusCode: Int
    let checkedAt: Date

    var statusDescription: String {
        if isAvailable {
            return "Connected"
        } else {
            return "Error (\(statusCode))"
        }
    }
}

// MARK: - Channel streams

struct DispatcharrStream: Decodable, Sendable {
    struct Stats: Decodable, Sendable {
        let height: Int?
        let sourceFps: Double?
    }
    let id: Int
    let name: String
    let m3uAccount: Int?
    let streamStats: Stats?
}

struct DispatcharrChannelStreams: Sendable {
    let streams: [DispatcharrStream]
    let accountNames: [Int: String]
    let currentStreamID: Int?

    /// "TREX • 1080p60": the provider, then the picture Dispatcharr last measured.
    func detail(for stream: DispatcharrStream) -> String? {
        var picture: String?
        if let height = stream.streamStats?.height {
            let fps = stream.streamStats?.sourceFps.map { Int($0.rounded()) }
            picture = "\(height)p" + (fps.map(String.init) ?? "")
        }
        let parts = [stream.m3uAccount.flatMap { accountNames[$0] }, picture].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

// MARK: - Errors

enum DispatcharrError: LocalizedError {
    case invalidResponse
    case unauthorized
    case notFound
    case serverError(Int)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Dispatcharr server"
        case .unauthorized:
            return "Unauthorized - check Dispatcharr authentication"
        case .notFound:
            return "Dispatcharr endpoint not found - verify URL"
        case .serverError(let code):
            return "Dispatcharr server error (\(code))"
        case .httpError(let code):
            return "HTTP error \(code)"
        }
    }
}

// MARK: - URL Builder Extensions

extension DispatcharrService {
    /// Build the M3U URL for this Dispatcharr instance
    var m3uURL: URL {
        Self.outputURL(base: baseURL, kind: "m3u", channelProfile: channelProfile)
    }

    /// Build the EPG URL for this Dispatcharr instance
    var epgURL: URL {
        Self.outputURL(base: baseURL, kind: "epg", channelProfile: channelProfile)
    }

    /// Builds an output endpoint URL, with the channel profile as its own path
    /// segment. `appendingPathComponent` escapes the name ("Kids TV" becomes
    /// `Kids%20TV`); with no profile this is `base/output/<kind>`.
    static func outputURL(base: URL, kind: String, channelProfile: String?) -> URL {
        let url = base.appendingPathComponent("output/\(kind)")
        guard let profile = normalizedProfile(channelProfile) else { return url }
        return url.appendingPathComponent(profile)
    }

    /// Build the Swagger API URL (for reference/debugging)
    var swaggerURL: URL {
        baseURL.appendingPathComponent("swagger")
    }
}
