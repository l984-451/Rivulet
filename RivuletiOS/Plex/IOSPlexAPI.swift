// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated final class IOSPlexAPI: @unchecked Sendable {
    static let shared = IOSPlexAPI()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(
            configuration: configuration,
            delegate: IOSPlexTrustDelegate.shared,
            delegateQueue: nil
        )
    }()

    private init() { }

    func requestPIN() async throws -> (id: Int, code: String) {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins")!)
        request.httpMethod = "POST"
        addIdentityHeaders(to: &request, token: nil)
        let data = try await data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? Int, let code = json?["code"] as? String else {
            throw IOSPlexError.invalidResponse
        }
        return (id, code)
    }

    func checkPIN(id: Int) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins/\(id)")!)
        addIdentityHeaders(to: &request, token: nil)
        let data = try await data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["authToken"] as? String
    }

    func userProfile(token: String) async throws -> IOSPlexUserProfile {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/user")!)
        addIdentityHeaders(to: &request, token: token)
        return try JSONDecoder().decode(
            IOSPlexUserProfile.self,
            from: await data(for: request)
        )
    }

    func authenticationURL(code: String) -> URL? {
        var components = URLComponents(string: "https://app.plex.tv/auth")
        components?.fragment = "?clientID=\(IOSPlexAPIIdentity.clientIdentifier)&code=\(code)&context[device][product]=Rivulet"
        return components?.url
    }

    func servers(token: String) async throws -> [IOSPlexServer] {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!)
        addIdentityHeaders(to: &request, token: token)
        return try JSONDecoder().decode([IOSPlexServer].self, from: await data(for: request))
            .filter { $0.provides.split(separator: ",").contains("server") }
    }

    func workingConnection(for server: IOSPlexServer, token: String) async -> URL? {
        let candidates = (server.connections ?? []).sorted {
            score($0) > score($1)
        }
        for connection in candidates {
            guard let base = URL(string: connection.uri) else { continue }
            var request = URLRequest(url: base.appending(path: "identity"))
            request.timeoutInterval = 4
            addIdentityHeaders(to: &request, token: server.accessToken ?? token)
            if (try? await data(for: request)) != nil { return base }
        }
        return nil
    }

    func libraries(server: URL, token: String) async throws -> [IOSPlexLibrary] {
        let response: IOSPlexLibraryResponse = try await get(server: server, path: "/library/sections", token: token)
        return response.MediaContainer.Directory ?? []
    }

    func hubs(server: URL, token: String) async throws -> [IOSPlexShelf] {
        let response: IOSPlexHubResponse = try await get(
            server: server,
            path: "/hubs?count=24&includeGuids=1&includeMarkers=1",
            token: token
        )
        return shelves(from: response)
    }

    /// Plex-native rows for one movie/show library. The server response order
    /// is the order configured and displayed by Plex for that section.
    func hubs(
        server: URL,
        token: String,
        library: IOSPlexLibrary
    ) async throws -> [IOSPlexShelf] {
        let response: IOSPlexHubResponse = try await get(
            server: server,
            path: "/hubs/sections/\(library.key)?count=24&includeGuids=1&includeMarkers=1",
            token: token
        )
        return shelves(from: response)
    }

    private func shelves(from response: IOSPlexHubResponse) -> [IOSPlexShelf] {
        (response.MediaContainer.Hub ?? []).compactMap { hub -> IOSPlexShelf? in
            let items = Array((hub.Metadata ?? []).prefix(14))
            guard !items.isEmpty else { return nil }
            return IOSPlexShelf(
                id: hub.hubIdentifier ?? hub.title ?? UUID().uuidString,
                title: hub.title ?? "Plex",
                items: items
            )
        }
        .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func libraryItems(server: URL, token: String, library: IOSPlexLibrary) async throws -> [IOSPlexItem] {
        let response: IOSPlexMetadataResponse = try await get(
            server: server,
            path: "/library/sections/\(library.key)/all?X-Plex-Container-Size=200&sort=titleSort&includeGuids=1",
            token: token
        )
        return response.MediaContainer.Metadata ?? []
    }

    func metadata(server: URL, token: String, ratingKey: String) async throws -> IOSPlexItem {
        let response: IOSPlexMetadataResponse = try await get(
            server: server,
            path: "/library/metadata/\(ratingKey)?includeGuids=1&includeMarkers=1&includeOnDeck=1",
            token: token
        )
        guard let item = response.MediaContainer.Metadata?.first else { throw IOSPlexError.invalidResponse }
        return item
    }

    func children(server: URL, token: String, ratingKey: String) async throws -> [IOSPlexItem] {
        let response: IOSPlexMetadataResponse = try await get(
            server: server,
            path: "/library/metadata/\(ratingKey)/children?includeGuids=1&includeMarkers=1",
            token: token
        )
        return response.MediaContainer.Metadata ?? []
    }

    func search(server: URL, token: String, query: String) async throws -> [IOSPlexItem] {
        var hubComponents = URLComponents(url: server.appending(path: "hubs/search"), resolvingAgainstBaseURL: false)
        hubComponents?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "80"),
            URLQueryItem(name: "includeGuids", value: "1"),
            URLQueryItem(name: "includeCollections", value: "1"),
            URLQueryItem(name: "includeExternalMedia", value: "0")
        ]
        if let url = hubComponents?.url {
            var request = URLRequest(url: url)
            addIdentityHeaders(to: &request, token: token)
            if let payload = try? await data(for: request),
               let response = try? JSONDecoder().decode(IOSPlexHubResponse.self, from: payload) {
                let results = uniqueSearchItems((response.MediaContainer.Hub ?? []).flatMap { $0.Metadata ?? [] })
                if !results.isEmpty { return results }
            }
        }

        // Older Plex servers expose the original flat /search response.
        var legacyComponents = URLComponents(url: server.appending(path: "search"), resolvingAgainstBaseURL: false)
        legacyComponents?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "X-Plex-Container-Size", value: "80"),
            URLQueryItem(name: "includeGuids", value: "1")
        ]
        guard let legacyURL = legacyComponents?.url else { throw IOSPlexError.invalidURL }
        var legacyRequest = URLRequest(url: legacyURL)
        addIdentityHeaders(to: &legacyRequest, token: token)
        let response = try JSONDecoder().decode(IOSPlexMetadataResponse.self, from: await data(for: legacyRequest))
        return uniqueSearchItems(response.MediaContainer.Metadata ?? [])
    }

    private func uniqueSearchItems(_ items: [IOSPlexItem]) -> [IOSPlexItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard ["movie", "show", "season", "episode"].contains(item.type ?? "") else { return false }
            return seen.insert(item.id).inserted
        }
    }

    func playbackURL(server: URL, token: String, item: IOSPlexItem) -> URL? {
        guard let part = item.partKey else { return nil }
        var components = URLComponents(url: server.appending(path: part), resolvingAgainstBaseURL: false)
        var query = components?.queryItems ?? []
        query.append(URLQueryItem(name: "X-Plex-Token", value: token))
        query.append(URLQueryItem(name: "X-Plex-Client-Identifier", value: IOSPlexAPIIdentity.clientIdentifier))
        query.append(URLQueryItem(name: "X-Plex-Platform", value: IOSPlexAPIIdentity.platform))
        query.append(URLQueryItem(name: "X-Plex-Product", value: IOSPlexAPIIdentity.product))
        components?.queryItems = query
        return components?.url
    }

    func reportProgress(server: URL, token: String, item: IOSPlexItem, time: TimeInterval, state: String) async {
        guard let key = item.ratingKey else { return }
        var components = URLComponents(url: server.appending(path: ":/timeline"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "ratingKey", value: key),
            URLQueryItem(name: "key", value: "/library/metadata/\(key)"),
            URLQueryItem(name: "time", value: String(Int(time * 1000))),
            URLQueryItem(name: "duration", value: String(item.duration ?? 0)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        addIdentityHeaders(to: &request, token: token)
        _ = try? await data(for: request)
    }

    func communityMarkers(imdbID: String, season: Int, episode: Int) async -> [IOSPlexMarker] {
        guard var components = URLComponents(string: "https://api.introdb.app/segments") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbID),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let data = try? await data(for: request) else { return [] }

        struct Segment: Decodable { let start_sec: Double?; let end_sec: Double?; let confidence: Double? }
        struct Wire: Decodable { let intro: Segment?; let recap: Segment?; let outro: Segment? }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return [] }
        func marker(_ segment: Segment?, type: String, id: Int) -> IOSPlexMarker? {
            guard let start = segment?.start_sec, let end = segment?.end_sec,
                  end > start, (segment?.confidence ?? 1) >= 0.5 else { return nil }
            return IOSPlexMarker(
                id: id,
                type: type,
                startTimeOffset: Int(start * 1000),
                endTimeOffset: Int(end * 1000)
            )
        }
        return [
            marker(wire.intro, type: "intro", id: -9001),
            marker(wire.recap, type: "recap", id: -9002),
            marker(wire.outro, type: "credits", id: -9003)
        ].compactMap { $0 }
    }

    func artworkURL(server: URL, token: String, path: String?, width: Int = 600, height: Int = 900) -> URL? {
        guard let path else { return nil }
        var components = URLComponents(url: server.appending(path: "photo/:/transcode"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        return components?.url
    }

    /// Builds a direct, authenticated URL for transparent assets such as
    /// Plex clear logos. Sending these through the photo transcoder can
    /// flatten their alpha channel, so this mirrors the tvOS asset path.
    func resourceURL(server: URL, token: String, path: String?) -> URL? {
        guard let path, !path.isEmpty,
              let baseURL = URL(string: path, relativeTo: server)?.absoluteURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "X-Plex-Token" }) {
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components.queryItems = queryItems
        return components.url
    }

    func playbackHeaders(token: String) -> [String: String] {
        [
            "X-Plex-Token": token,
            "X-Plex-Client-Identifier": IOSPlexAPIIdentity.clientIdentifier,
            "X-Plex-Platform": IOSPlexAPIIdentity.platform,
            "X-Plex-Product": IOSPlexAPIIdentity.product,
            "User-Agent": "Rivulet/iOS",
            "X-Playback-Session-Id": UUID().uuidString
        ]
    }

    private func get<T: Decodable>(server: URL, path: String, token: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: server)?.absoluteURL else { throw IOSPlexError.invalidURL }
        var request = URLRequest(url: url)
        addIdentityHeaders(to: &request, token: token)
        return try JSONDecoder().decode(T.self, from: await data(for: request))
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw IOSPlexError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw IOSPlexError.http(response.statusCode) }
        return data
    }

    private func addIdentityHeaders(to request: inout URLRequest, token: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(IOSPlexAPIIdentity.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(IOSPlexAPIIdentity.product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(IOSPlexAPIIdentity.platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(IOSPlexAPIIdentity.device, forHTTPHeaderField: "X-Plex-Device")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
    }

    private func score(_ connection: IOSPlexConnection) -> Int {
        if connection.relay == true { return 0 }
        if connection.local == true { return connection.uri.hasPrefix("https") ? 4 : 3 }
        return connection.uri.hasPrefix("https") ? 2 : 1
    }

}

nonisolated private final class IOSPlexTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = IOSPlexTrustDelegate()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port
        let isIPAddress = host.range(
            of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#,
            options: .regularExpression
        ) != nil
        if isIPAddress || host.hasSuffix(".plex.direct") || port == 32400 {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

nonisolated enum IOSPlexError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int)
    case noReachableServer

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Plex returned an invalid URL."
        case .invalidResponse: "Plex returned an unexpected response."
        case .http(let status): "Plex request failed (HTTP \(status))."
        case .noReachableServer: "No connection to this Plex server was reachable."
        }
    }
}
