// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A native v2 client for exactly one web root and immutable profile scope.
/// A session-owned token source refreshes that same login, never the current
/// global account. Writes are sent once, including PIN checks and playback.
nonisolated final class SiloClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias TokenSource = @Sendable (_ forceRefresh: Bool) async throws -> String

    let baseURL: URL
    let token: String?
    let profileID: String?
    let profileToken: String?
    private let transport: Transport
    private let tokenSource: TokenSource?
    private let deviceHeaders: [String: String]

    init(
        baseURL: URL, token: String? = nil, profileID: String? = nil, profileToken: String? = nil,
        transport: @escaping Transport = { try await SiloHTTP.data(for: $0) },
        tokenSource: TokenSource? = nil, deviceHeaders: [String: String] = [:]
    ) {
        self.baseURL = Self.normalizedServerURL(baseURL)
        self.token = token
        self.profileID = profileID
        self.profileToken = profileToken
        self.transport = transport
        self.tokenSource = tokenSource
        self.deviceHeaders = deviceHeaders
    }

    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        // Callers percent-escape opaque path segments. Appending(path:) would
        // escape their percent signs a second time and change the identifier.
        let endpoint = URLComponents(string: "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))?
            .percentEncodedPath ?? "/"
        let root = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = (root.isEmpty ? "" : "/" + root) + "/api/v2" + endpoint
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url ?? baseURL
    }

    static func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// A guarded resource read retains its exact validator, not a synthesized revision.
    nonisolated struct Resource<Value: Decodable & Sendable>: Sendable {
        let value: Value
        let entityTag: String?
    }

    func getResource<T: Decodable & Sendable>(_ path: String) async throws -> Resource<T> {
        try await sendResource("GET", path, query: [], body: nil)
    }

    func putResource<T: Decodable & Sendable>(_ path: String, body: any Encodable & Sendable,
                                             ifMatch: String) async throws -> Resource<T> {
        try await sendResource("PUT", path, query: [], body: body, ifMatch: ifMatch)
    }

    func get<T: Decodable & Sendable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        try await send("GET", path, query: query, body: nil)
    }

    func post<T: Decodable & Sendable>(_ path: String, body: (any Encodable & Sendable)? = nil) async throws -> T {
        try await send("POST", path, query: [], body: body)
    }

    func put<T: Decodable & Sendable>(_ path: String, body: (any Encodable & Sendable)? = nil) async throws -> T {
        try await send("PUT", path, query: [], body: body)
    }

    func patch<T: Decodable & Sendable>(_ path: String, body: (any Encodable & Sendable)? = nil) async throws -> T {
        try await send("PATCH", path, query: [], body: body)
    }

    func post(_ path: String, body: (any Encodable & Sendable)? = nil) async throws {
        let _: Empty = try await send("POST", path, query: [], body: body)
    }

    func put(_ path: String, body: (any Encodable & Sendable)? = nil, expectedStatus: Int? = nil) async throws {
        let _: Empty = try await send("PUT", path, query: [], body: body, expectedStatus: expectedStatus)
    }

    func patch(_ path: String, body: (any Encodable & Sendable)? = nil) async throws {
        let _: Empty = try await send("PATCH", path, query: [], body: body)
    }

    func delete(_ path: String, query: [URLQueryItem] = []) async throws {
        let _: Empty = try await send("DELETE", path, query: query, body: nil)
    }

    func delete(_ path: String, body: any Encodable & Sendable) async throws {
        let _: Empty = try await send("DELETE", path, query: [], body: body)
    }

    func delete<T: Decodable & Sendable>(_ path: String, body: any Encodable & Sendable) async throws -> T {
        try await send("DELETE", path, query: [], body: body)
    }

    /// Native media references are web-root paths, not api/v2 endpoint arguments.
    /// An API-root path from a server behind a prefix must keep that prefix.
    func mediaURL(_ value: String) -> URL? {
        Self.mediaURL(value, relativeTo: baseURL)
    }

    /// `baseURL` is the normalized native web root supplied by the session.
    static func mediaURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let reference = URLComponents(string: value) else { return nil }
        if reference.scheme != nil {
            guard let result = reference.url, ["http", "https"].contains(result.scheme?.lowercased() ?? ""),
                  result.user == nil, result.password == nil else { return nil }
            return result
        }
        guard reference.host == nil else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let prefix = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let path = reference.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let alreadyPrefixed = !prefix.isEmpty && (path == prefix || path.hasPrefix(prefix + "/"))
        components?.percentEncodedPath = "/" + ([alreadyPrefixed ? "" : prefix, path].filter { !$0.isEmpty }.joined(separator: "/"))
        components?.percentEncodedQuery = reference.percentEncodedQuery
        components?.fragment = nil
        return components?.url
    }

    func mediaHeaders(for url: URL, supplied: [String: String] = [:], forceRefresh: Bool = false) async throws -> [String: String] {
        guard owns(url) else { return supplied }
        // Native account/profile authority is immutable. A transport grant
        // cannot replace it; explicit foreign-origin grants remain untouched.
        var headers = supplied.filter { key, _ in
            !["Authorization", "X-Profile-Id", "X-Profile-Token"].contains {
                key.caseInsensitiveCompare($0) == .orderedSame
            }
        }
        let bearer = try await accessToken(forceRefresh)
        func add(_ key: String, _ value: String?) {
            guard let value, !headers.keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) else { return }
            headers[key] = value
        }
        add("Authorization", bearer.map { "Bearer \($0)" })
        add("X-Profile-Id", profileID)
        add("X-Profile-Token", profileToken)
        for (key, value) in deviceHeaders { add(key, value) }
        return headers
    }

    func owns(_ url: URL) -> Bool {
        guard Self.origin(url) == Self.origin(baseURL), url.user == nil, url.password == nil else { return false }
        let root = baseURL.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = url.standardized.path
        return root.isEmpty || path == "/" + root || path.hasPrefix("/" + root + "/")
    }

    var canRefreshMediaCredentials: Bool { tokenSource != nil }

    private func accessToken(_ forceRefresh: Bool = false) async throws -> String? {
        if let tokenSource { return try await tokenSource(forceRefresh) }
        return token
    }

    private struct Empty: Decodable, Sendable {}

    @concurrent
    private func send<T: Decodable & Sendable>(
        _ method: String, _ path: String, query: [URLQueryItem], body: (any Encodable & Sendable)?, expectedStatus: Int? = nil
    ) async throws -> T {
        let response: Resource<T> = try await sendResource(method, path, query: query, body: body, expectedStatus: expectedStatus)
        return response.value
    }

    @concurrent
    private func sendResource<T: Decodable & Sendable>(
        _ method: String, _ path: String, query: [URLQueryItem], body: (any Encodable & Sendable)?,
        expectedStatus: Int? = nil, ifMatch: String? = nil
    ) async throws -> Resource<T> {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        for (key, value) in deviceHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let bearer = try await accessToken() { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let profileID { request.setValue(profileID, forHTTPHeaderField: "X-Profile-Id") }
        if let profileToken { request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try SiloJSON.encoder().encode(body)
        }
        try Task.checkCancellation()
        var (data, response) = try await perform(request)
        // A rejected read is safe to repeat with a refreshed token. Never replay
        // a mutation: its outcome may be uncertain, even on an auth failure.
        if method == "GET", (response as? HTTPURLResponse)?.statusCode == 401, tokenSource != nil {
            if let bearer = try await accessToken(true) {
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            }
            try Task.checkCancellation()
            (data, response) = try await perform(request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            if let problem = try? SiloJSON.decoder().decode(SiloAPIError.self, from: data) { throw problem }
            throw MediaProviderError.backendSpecific(underlying: "Silo HTTP \(status)")
        }
        if let expectedStatus, status != expectedStatus { throw SiloSignInError.invalidResponse }
        let entityTag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        if T.self == Empty.self { return Resource(value: Empty() as! T, entityTag: entityTag) }
        do { return Resource(value: try SiloJSON.decoder().decode(T.self, from: data), entityTag: entityTag) }
        catch { throw SiloSignInError.invalidResponse }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let result = try await transport(request)
            guard let responseURL = result.1.url, owns(responseURL) else { throw SiloSignInError.originMismatch }
            return result
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                throw SiloSignInError.untrustedCertificate
            case .cancelled: throw CancellationError()
            default: throw MediaProviderError.unreachable
            }
        }
    }

    static func normalizedServerURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil
        components.percentEncodedPath = "/" + components.percentEncodedPath.split(separator: "/").joined(separator: "/")
        return components.url ?? url
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)\(port)"
    }
}

nonisolated enum SiloJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

/// Reject redirects rather than forwarding passwords/profile proofs to a login
/// page or another origin. Native discovery reports the reached origin too.
nonisolated enum SiloHTTP {
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
