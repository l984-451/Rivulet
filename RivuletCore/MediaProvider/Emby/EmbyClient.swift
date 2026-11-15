// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyClient.swift
//  Rivulet
//
//  Transport for one Emby server: base URL, the MediaBrowser auth header, JSON
//  in both directions, and HTTP failures mapped onto MediaProviderError.
//  Endpoint knowledge lives in EmbyProvider.
//

import Foundation

/// Connection and sign-in failures `MediaProviderError` has no name for. The
/// client throws `untrustedCertificate` on any request; the rest come from sign-in.
enum EmbySignInError: Error, Equatable {
    case notEmby
    case serverTooOld(version: String)
    case untrustedCertificate
    case invalidCredentials
    /// The three 403 causes carry the server's own English text, the only place the cause is stated.
    case lockedOut(message: String)
    case accountDisabled(message: String)
    case notAllowed(message: String)
}

nonisolated final class EmbyClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    let token: String?
    let authorization: String
    private let transport: Transport

    /// One shared session with the 30 s request timeout the Plex client uses.
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// MainActor because the device identity (`PlexAPI`) is MainActor state.
    /// The header is built once here; every request after that is nonisolated.
    @MainActor
    init(
        baseURL: URL,
        token: String?,
        transport: @escaping Transport = { try await EmbyClient.defaultSession.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.token = token
        self.authorization = Self.authorizationHeader(token: token)
        self.transport = transport
    }

    /// The one auth header. Never also send `X-Emby-Token`: it outranks this header and `api_key`.
    /// The device name is percent-encoded because a raw comma truncates the quoted value.
    @MainActor
    static func authorizationHeader(token: String?) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var parts = [
            #"Client="\#(PlexAPI.productName)""#,
            #"Device="\#(encodedDeviceName(PlexAPI.deviceName))""#,
            #"DeviceId="\#(PlexAPI.clientIdentifier)""#,
            #"Version="\#(version)""#
        ]
        if let token { parts.append(#"Token="\#(token)""#) }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    nonisolated static func encodedDeviceName(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }

    /// The per-install device id the Authorization header carries.
    @MainActor var deviceID: String { PlexAPI.clientIdentifier }

    /// The typed base plus a bare path, joined as strings: never add or strip `/emby`
    /// (the server accepts both) and keep a reverse-proxy subpath as typed.
    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        Self.makeURL(base: baseURL, path, query)
    }

    nonisolated static func makeURL(base: URL, _ path: String, _ query: [URLQueryItem] = []) -> URL {
        let bare = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let full = URL(string: trimmed(base.absoluteString) + "/" + bare) ?? base
        guard !query.isEmpty, var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
            return full
        }
        components.queryItems = query
        // URLComponents leaves "+" literal; ASP.NET reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? full
    }

    /// A stream or download URL: the token rides as `api_key` because the player sends no
    /// headers. Not for images, which are anonymous: a stale `api_key` turns their 200 into a 401.
    func authenticatedURL(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        url(path, query + (token.map { [URLQueryItem(name: "api_key", value: $0)] } ?? []))
    }

    /// A server-relative URL Emby returned (`/videos/1/master.m3u8?...`, never with `/emby`).
    /// Joined to the base as a string: URL-reference resolution would drop a proxy subpath.
    func resolve(_ serverRelative: String) -> URL? {
        URL(string: Self.trimmed(baseURL.absoluteString) + (serverRelative.hasPrefix("/") ? "" : "/") + serverRelative)
    }

    private nonisolated static func trimmed(_ string: String) -> String {
        var result = string
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    func get<T: Decodable & Sendable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        try await send("GET", path, query: query, body: nil)
    }

    func post<T: Decodable & Sendable>(
        _ path: String, query: [URLQueryItem] = [], body: (any Encodable & Sendable)? = nil
    ) async throws -> T {
        try await send("POST", path, query: query, body: body)
    }

    /// For endpoints whose response body the caller does not need (204s).
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
    private func exchange(
        _ method: String, _ path: String, query: [URLQueryItem], body: (any Encodable & Sendable)?
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try EmbyJSON.encoder().encode(body)
        }
        do {
            let (data, response) = try await transport(request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let error as URLError where Self.certificateFailures.contains(error.code) {
            // Reachable, but the HTTPS certificate is self-signed or expired:
            // "check the address" would send the user the wrong way.
            throw EmbySignInError.untrustedCertificate
        } catch let error as URLError where error.code != .cancelled {
            throw MediaProviderError.unreachable
        }
    }

    private func send<T: Decodable & Sendable>(
        _ method: String, _ path: String, query: [URLQueryItem], body: (any Encodable & Sendable)?
    ) async throws -> T {
        let (status, data) = try await exchange(method, path, query: query, body: body)
        try Self.check(status, path: path, data: data)
        return try decode(T.self, data, path: path)
    }

    /// A non-JSON body (a subtitle file), read as text.
    func getText(_ path: String, _ query: [URLQueryItem] = []) async throws -> String {
        let (status, data) = try await exchange("GET", path, query: query, body: nil)
        try Self.check(status, path: path, data: data)
        return String(decoding: data, as: UTF8.self)
    }

    private static func check(_ status: Int, path: String, data: Data) throws {
        switch status {
        case 200...299:
            break
        case 401, 403:
            throw MediaProviderError.unauthorized
        case 404:
            throw MediaProviderError.notFound
        default:
            throw MediaProviderError.backendSpecific(underlying: failure(status, path: path, data: data))
        }
    }

    private func decode<T: Decodable & Sendable>(_ type: T.Type, _ data: Data, path: String) throws -> T {
        if T.self == Empty.self { return Empty() as! T }
        do {
            return try EmbyJSON.decoder().decode(T.self, from: data)
        } catch {
            throw MediaProviderError.backendSpecific(underlying: "Emby decode \(path): \(error)")
        }
    }

    /// Retries a 500 once (sporadic SQLite error). Never retry a 401 or 403: ten failures
    /// lock the user out for a minute.
    func authenticate(username: String, password: String) async throws -> EmbyAuthenticationResult {
        let body = EmbyAuthenticateByName(username: username, pw: password)
        let path = "Users/AuthenticateByName"
        var (status, data) = try await exchange("POST", path, query: [], body: body)
        if status == 500 { (status, data) = try await exchange("POST", path, query: [], body: body) }
        switch status {
        case 200...299:
            return try decode(EmbyAuthenticationResult.self, data, path: path)
        case 401:
            throw EmbySignInError.invalidCredentials
        case 403:
            let message = Self.plainText(data)
            let lower = message.lowercased()
            if lower.contains("locked out") { throw EmbySignInError.lockedOut(message: message) }
            if lower.contains("disabled") { throw EmbySignInError.accountDisabled(message: message) }
            throw EmbySignInError.notAllowed(message: message)
        case 404:
            throw EmbySignInError.notEmby
        default:
            throw MediaProviderError.backendSpecific(underlying: Self.failure(status, path: path, data: data))
        }
    }

    private static func failure(_ status: Int, path: String, data: Data) -> String {
        let text = plainText(data)
        return "Emby HTTP \(status) on \(path)" + (text.isEmpty ? "" : ": \(text.prefix(200))")
    }

    /// An error body: plain text on 4.9 and later, HTML-escaped (`&#39;`) on 4.8.
    nonisolated static func plainText(_ data: Data) -> String {
        decodeEntities(String(decoding: data, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `&amp;` goes last so `&amp;#39;` decodes once, to `&#39;`.
    private nonisolated static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        if let numeric = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") {
            for match in numeric.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let digits = Range(match.range(at: 1), in: result) else { continue }
                let code = result[digits]
                let scalar = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let scalar, let character = Unicode.Scalar(scalar) {
                    result.replaceSubrange(whole, with: String(Character(character)))
                }
            }
        }
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}
