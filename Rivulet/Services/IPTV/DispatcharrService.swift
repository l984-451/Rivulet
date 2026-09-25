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

    /// Dispatcharr channel profile to scope the playlist and guide to, or nil for
    /// every channel. In Dispatcharr this is a PATH segment, not a query item and
    /// not something the API token implies: `apps/output/urls.py` routes
    /// `^m3u(?:/(?P<profile_name>[^/]+))?/?$`, and `generate_m3u` only filters on
    /// `channelprofilemembership__channel_profile` when that segment is present.
    /// The API key does not scope the playlist (the output endpoints do not
    /// even authenticate), so without this segment the server correctly returns
    /// every channel regardless of which profiles exist. See GitHub issue #246.
    let channelProfile: String?

    let session: URLSession

    // MARK: - Initialization

    init(baseURL: URL, apiToken: String? = nil, channelProfile: String? = nil) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.channelProfile = Self.normalizedProfile(channelProfile)

        // Configure session with reasonable timeouts for potentially large M3U/EPG files
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120  // EPG files can be large
        self.session = URLSession(configuration: config)
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

    /// Separates a pasted address into the server base URL and, when the user
    /// pasted a full endpoint, the channel profile that followed it.
    ///
    /// We still have to cut `/output/m3u` and `/output/epg` off the base so the
    /// later `appendingPathComponent` calls do not double them up, but the
    /// trailing segment after the endpoint is a Dispatcharr channel profile name
    /// and is now kept rather than thrown away. Do not "simplify" this back to a
    /// plain prefix truncation: discarding that segment is the bug behind
    /// issue #246.
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

        let (data, response) = try await session.data(for: request)

        try validateResponse(response)

        return data
    }

    /// Fetch the XMLTV EPG from Dispatcharr
    /// - Returns: Raw XMLTV data
    func fetchEPG() async throws -> Data {
        let url = epgURL
        let request = authenticatedRequest(for: url)

        let (data, response) = try await session.data(for: request)

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
    func fetchParsedEPG() async throws -> XMLTVParser.ParseResult {
        let data = try await fetchEPG()
        let parser = XMLTVParser()
        return try await parser.parse(data: data)
    }

    // MARK: - Private Methods

    func authenticatedRequest(for url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = apiToken, let header = Self.authorizationHeader(for: token) {
            request.setValue(header.value, forHTTPHeaderField: header.field)
        }
        return request
    }

    /// How Dispatcharr wants `token` presented. Its API authenticates an API
    /// key (what its UI generates, sent as `X-API-Key`) or a JWT access token
    /// (`Authorization: Bearer`). It has never accepted DRF's
    /// `Authorization: Token`, which is what this used to send; nobody noticed
    /// because the playlist and guide are not authenticated at all (they are
    /// allowed by network), and nothing else here called the API.
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

    /// Builds an output endpoint URL, appending the channel profile as its own
    /// path segment when one is set. Dispatcharr scopes a playlist by profile
    /// only through this segment, so a profile that is set but not appended has
    /// no effect at all.
    ///
    /// `appendingPathComponent` performs the encoding: it escapes a space as
    /// `%20` and leaves already-legal path characters alone, so a profile named
    /// "Kids TV" yields `/output/m3u/Kids%20TV`. Interpolating the name into a
    /// string instead would emit a raw space and produce a URL that fails to
    /// construct.
    ///
    /// With no profile set this returns exactly `base/output/<kind>`, byte for
    /// byte what every existing source already requests.
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
