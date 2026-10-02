// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinClient.swift
//  Rivulet
//
//  Transport for one Jellyfin server: base URL, the MediaBrowser auth
//  header, JSON in both directions, and HTTP failures mapped onto
//  MediaProviderError. Endpoint knowledge lives in JellyfinProvider.
//
//  Hand-rolled rather than jellyfin-sdk-swift: ~15 endpoints don't justify a
//  second HTTP client (Get) and swift-nio as transitive dependencies.
//

import Foundation

nonisolated final class JellyfinClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    let token: String?
    let authorization: String
    private let transport: Transport

    /// MainActor because the device identity (`PlexAPI`) is MainActor state.
    /// The header is built once here; every request after that is nonisolated.
    @MainActor
    init(
        baseURL: URL,
        token: String?,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.token = token
        self.authorization = Self.authorizationHeader(token: token)
        self.transport = transport
    }

    /// `Authorization: MediaBrowser ...`. Jellyfin 12 accepts only this scheme
    /// (and `ApiKey=` in the query) by default; `X-Emby-Token` and `api_key`
    /// are legacy and off. Client/Device/DeviceId/Version are mandatory even
    /// before sign-in. DeviceId reuses the per-install id Plex already gets.
    @MainActor
    static func authorizationHeader(token: String?) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var parts = [
            #"Client="\#(PlexAPI.productName)""#,
            #"Device="\#(PlexAPI.deviceName)""#,
            #"DeviceId="\#(PlexAPI.clientIdentifier)""#,
            #"Version="\#(version)""#
        ]
        if let token { parts.append(#"Token="\#(token)""#) }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    /// The per-install device id the Authorization header carries; the server
    /// keys a client's transcode jobs on it.
    @MainActor var deviceID: String { PlexAPI.clientIdentifier }

    /// Absolute URL for `path` under the base URL (which may itself carry a
    /// reverse-proxy subpath such as `/jellyfin`).
    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        let full = baseURL.appending(path: path)
        guard !query.isEmpty, var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
            return full
        }
        components.queryItems = query
        // URLComponents leaves "+" literal; ASP.NET reads it as a space, so a
        // search for "C++" would arrive as "C  ".
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? full
    }

    func get<T: Decodable & Sendable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        try await send("GET", path, query: query, body: nil)
    }

    func post<T: Decodable & Sendable>(_ path: String, body: (any Encodable & Sendable)? = nil) async throws -> T {
        try await send("POST", path, query: [], body: body)
    }

    /// For endpoints whose response body the caller does not need (204s,
    /// and the 200s that echo UserData back).
    func post(_ path: String, query: [URLQueryItem] = [], body: (any Encodable & Sendable)? = nil) async throws {
        let _: Empty = try await send("POST", path, query: query, body: body)
    }

    func delete(_ path: String, query: [URLQueryItem] = []) async throws {
        let _: Empty = try await send("DELETE", path, query: query, body: nil)
    }

    private nonisolated struct Empty: Decodable, Sendable {}

    private static let certificateFailures: Set<URLError.Code> = [
        .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
        .serverCertificateHasBadDate, .serverCertificateNotYetValid
    ]

    @concurrent
    private func send<T: Decodable & Sendable>(
        _ method: String, _ path: String, query: [URLQueryItem], body: (any Encodable & Sendable)?
    ) async throws -> T {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JellyfinJSON.encoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where Self.certificateFailures.contains(error.code) {
            // Reachable, but the HTTPS certificate is self-signed or expired:
            // "check the address" would send the user the wrong way.
            throw JellyfinSignInError.untrustedCertificate
        } catch let error as URLError where error.code != .cancelled {
            throw MediaProviderError.unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299:
            break
        case 401, 403:
            throw MediaProviderError.unauthorized
        case 404:
            throw MediaProviderError.notFound
        default:
            throw MediaProviderError.backendSpecific(underlying: "Jellyfin HTTP \(status) on \(path)")
        }

        if T.self == Empty.self { return Empty() as! T }
        do {
            return try JellyfinJSON.decoder().decode(T.self, from: data)
        } catch {
            throw MediaProviderError.backendSpecific(underlying: "Jellyfin decode \(path): \(error)")
        }
    }
}

/// Jellyfin's JSON is PascalCase. Map it to Swift casing at the edge so the
/// DTOs read like the rest of the codebase. Dictionary keys (ImageTags,
/// ProviderIds) are left untouched by key strategies.
nonisolated enum JellyfinJSON {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return Key(stringValue: key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return Key(stringValue: key.prefix(1).uppercased() + key.dropFirst())
        }
        return encoder
    }
}

/// Jellyfin times are 100ns ticks (RunTimeTicks, PositionTicks, chapter starts).
nonisolated enum JellyfinTicks {
    static let perSecond: Double = 10_000_000
    static func seconds(_ ticks: Int64?) -> TimeInterval? { ticks.map { Double($0) / perSecond } }
    static func ticks(_ seconds: TimeInterval) -> Int64 { Int64((seconds * perSecond).rounded()) }
}
