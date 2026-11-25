// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The Seerr REST API (https://docs.seerr.dev/api/seerr-api/), as far as
// requesting needs it: search, a show's seasons, and creating a request. Every call carries the
// admin API key in `X-Api-Key`, so requests are made as the Seerr admin and auto-approve.

import Foundation

nonisolated enum SeerrError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case notSeerr
    case server(status: Int, message: String?)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "Seerr isn’t set up. Add it in Settings > Servers.")
        case .unauthorized:
            String(localized: "Seerr didn’t accept the API key.")
        case .notSeerr:
            String(localized: "That address didn’t answer like a Seerr server.")
        case .server(let status, let message):
            message ?? String(localized: "Seerr answered with an error (\(status)).")
        case .network(let message):
            message
        }
    }
}

/// What the connection check found.
nonisolated struct SeerrServerInfo: Equatable, Sendable {
    let version: String
    let user: String
}

nonisolated struct SeerrClient: Sendable {
    let base: URL
    let apiKey: String

    /// The client for the saved settings, or nil until Seerr is set up.
    @MainActor static var configured: SeerrClient? {
        guard let base = SeerrSettings.baseURL else { return nil }
        return SeerrClient(base: base, apiKey: SeerrSettings.apiKey)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    // MARK: - Calls

    /// Checks the address with the unauthenticated status call, then the key with `auth/me`.
    func check() async throws -> SeerrServerInfo {
        let status: StatusDTO = try await get("status", authenticated: false)
        let me: UserDTO = try await get("auth/me")
        let name = me.displayName ?? me.username ?? me.plexUsername ?? me.jellyfinUsername ?? me.email ?? "#\(me.id)"
        return SeerrServerInfo(version: status.version, user: name)
    }

    /// Movies and shows for `query`, in Seerr's order; people are left out.
    func search(_ query: String) async throws -> [SeerrTitle] {
        try Self.titles(fromSearch: try await data("search", query: [("query", query), ("page", "1")]))
    }

    /// A show's state and its seasons'.
    func show(_ tmdbID: Int) async throws -> SeerrShow {
        try Self.show(fromDetails: try await data("tv/\(tmdbID)"))
    }

    /// The title's YouTube trailer, for the detail page's Trailers row.
    func trailerKey(_ kind: SeerrTitle.Kind, _ tmdbID: Int) async throws -> String? {
        try Self.trailerKey(fromDetails: try await data("\(kind.rawValue)/\(tmdbID)"))
    }

    /// TMDB's recommendations for the title, for the detail page's More Like This row.
    func recommendations(_ kind: SeerrTitle.Kind, _ tmdbID: Int) async throws -> [SeerrTitle] {
        try Self.titles(fromSearch: try await data("\(kind.rawValue)/\(tmdbID)/recommendations",
                                                   query: [("page", "1")]), defaultKind: kind)
    }

    /// A movie's state.
    func movieAvailability(_ tmdbID: Int) async throws -> SeerrAvailability {
        try Self.movieAvailability(fromDetails: try await data("movie/\(tmdbID)"))
    }

    // MARK: - Parsing (separate from transport, for tests)

    /// `defaultKind` names results that carry no `mediaType` (recommendations lists don't always).
    static func titles(fromSearch data: Data, defaultKind: SeerrTitle.Kind? = nil) throws -> [SeerrTitle] {
        try decode(SearchPageDTO.self, data).results.compactMap { $0.seerrTitle(defaultKind: defaultKind) }
    }

    /// The first YouTube trailer, else the first YouTube teaser.
    static func trailerKey(fromDetails data: Data) throws -> String? {
        let videos = try decode(VideosDTO.self, data).relatedVideos ?? []
        let youTube = videos.filter { ($0.site ?? "").caseInsensitiveCompare("YouTube") == .orderedSame && !($0.key ?? "").isEmpty }
        return (youTube.first { $0.type == "Trailer" } ?? youTube.first { $0.type == "Teaser" })?.key
    }

    static func movieAvailability(fromDetails data: Data) throws -> SeerrAvailability {
        let movie = try decode(MovieDetailsDTO.self, data)
        return SeerrAvailability(mediaStatus: movie.mediaInfo?.status.flatMap(SeerrMediaStatus.init(rawValue:)))
    }

    static func show(fromDetails data: Data) throws -> SeerrShow {
        let show = try decode(TvDetailsDTO.self, data)
        let availability = SeerrAvailability(mediaStatus: show.mediaInfo?.status.flatMap(SeerrMediaStatus.init(rawValue:)))
        return SeerrShow(availability: availability, seasons: try seasons(from: show))
    }

    static func seasons(fromShow data: Data) throws -> [SeerrSeason] {
        try seasons(from: try decode(TvDetailsDTO.self, data))
    }

    private static func seasons(from show: TvDetailsDTO) throws -> [SeerrSeason] {
        let media = show.mediaInfo
        var status: [Int: SeerrMediaStatus] = [:]
        for season in media?.seasons ?? [] {
            if let value = season.status.flatMap(SeerrMediaStatus.init(rawValue:)) { status[season.seasonNumber] = value }
        }
        let live: Set<SeerrRequestStatus> = [.pending, .approved]
        var requested = Set<Int>()
        for request in media?.requests ?? [] {
            guard let state = request.status.flatMap(SeerrRequestStatus.init(rawValue:)), live.contains(state) else { continue }
            for season in request.seasons ?? [] {
                let seasonState = season.status.flatMap(SeerrRequestStatus.init(rawValue:)) ?? .pending
                if live.contains(seasonState) { requested.insert(season.seasonNumber) }
            }
        }
        return SeerrSeasons.merge(
            seasons: (show.seasons ?? []).map { ($0.seasonNumber, $0.name ?? "", $0.episodeCount) },
            mediaStatus: status, requested: requested)
    }

    /// `quality` nil leaves the server and profile to Seerr's defaults.
    func requestMovie(_ tmdbID: Int, quality: SeerrQualityOption? = nil) async throws {
        try await post("request", body: RequestBody(mediaType: "movie", mediaId: tmdbID, seasons: nil, quality: quality))
    }

    func requestShow(_ tmdbID: Int, seasons: [Int], quality: SeerrQualityOption? = nil) async throws {
        try await post("request", body: RequestBody(mediaType: "tv", mediaId: tmdbID, seasons: seasons, quality: quality))
    }

    /// The quality profiles a movie (Radarr) or show (Sonarr) can be requested in.
    func qualityOptions(_ kind: SeerrTitle.Kind) async throws -> [SeerrQualityOption] {
        let service = kind == .movie ? "radarr" : "sonarr"
        let servers: [ServiceServerDTO] = try await get("service/\(service)")
        var profiles: [Int: [(id: Int, name: String)]] = [:]
        for server in servers {
            // One unreachable Radarr or Sonarr only loses its own profiles.
            guard let detail: ServiceDetailDTO = try? await get("service/\(service)/\(server.id)") else { continue }
            profiles[server.id] = (detail.profiles ?? []).map { ($0.id, $0.name) }
        }
        return SeerrQualityOption.options(
            servers: servers.map { .init(id: $0.id, is4K: $0.is4k ?? false, isDefault: $0.isDefault ?? false,
                                         activeProfileID: $0.activeProfileId) },
            profiles: profiles)
    }

    // MARK: - Transport

    /// Percent-encodes everything but unreserved characters. Seerr validates the query against its
    /// OpenAPI spec and rejects characters `URLComponents` leaves bare (`'`, `!`, `(`, `)`).
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    func url(_ path: String, query: [(String, String)] = []) -> URL {
        var text = base.absoluteString + "/" + path
        if !query.isEmpty {
            text += "?" + query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        }
        return URL(string: text) ?? base
    }

    private func request(_ url: URL, method: String, authenticated: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated { request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        return request
    }

    func data(_ path: String, query: [(String, String)] = [], authenticated: Bool = true) async throws -> Data {
        try await send(request(url(path, query: query), method: "GET", authenticated: authenticated))
    }

    private func get<T: Decodable>(_ path: String, query: [(String, String)] = [],
                                   authenticated: Bool = true) async throws -> T {
        try Self.decode(T.self, try await data(path, query: query, authenticated: authenticated))
    }

    /// Anything that isn't the expected JSON (a login page, a proxy's error page) is "not Seerr".
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SeerrError.notSeerr
        }
    }

    private func post(_ path: String, body: some Encodable) async throws {
        var request = request(url(path), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw SeerrError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SeerrError.notSeerr }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw SeerrError.unauthorized
        default:
            // Never echo the body itself: only Seerr's own `message` field, which names the problem
            // ("Request already exists", a quota) and carries no credentials.
            let message = (try? JSONDecoder().decode(MessageDTO.self, from: data))?.message
            throw SeerrError.server(status: http.statusCode, message: message)
        }
    }
}

// MARK: - Wire types

nonisolated private struct StatusDTO: Decodable { let version: String }

nonisolated private struct UserDTO: Decodable {
    let id: Int
    let displayName: String?
    let username: String?
    let plexUsername: String?
    let jellyfinUsername: String?
    let email: String?
}

nonisolated private struct MessageDTO: Decodable { let message: String? }

nonisolated private struct RequestBody: Encodable {
    let mediaType: String
    let mediaId: Int
    let seasons: [Int]?
    let serverId: Int?
    let profileId: Int?
    let is4k: Bool?

    init(mediaType: String, mediaId: Int, seasons: [Int]?, quality: SeerrQualityOption?) {
        self.mediaType = mediaType
        self.mediaId = mediaId
        self.seasons = seasons
        serverId = quality?.serverID
        profileId = quality?.profileID
        is4k = quality.map(\.is4K)
    }
}

nonisolated private struct ServiceServerDTO: Decodable {
    let id: Int
    let is4k: Bool?
    let isDefault: Bool?
    let activeProfileId: Int?
}

nonisolated private struct ServiceDetailDTO: Decodable {
    struct Profile: Decodable { let id: Int; let name: String }
    let profiles: [Profile]?
}

nonisolated private struct MediaInfoDTO: Decodable {
    struct SeasonDTO: Decodable {
        let seasonNumber: Int
        let status: Int?
    }
    struct RequestDTO: Decodable {
        let status: Int?
        let seasons: [SeasonDTO]?
    }
    let status: Int?
    let seasons: [SeasonDTO]?
    let requests: [RequestDTO]?
}

nonisolated private struct SearchPageDTO: Decodable {
    let results: [ResultDTO]
}

/// One search hit. Movies carry `title`/`releaseDate`, shows `name`/`firstAirDate`; people are skipped.
nonisolated private struct ResultDTO: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let mediaInfo: MediaInfoDTO?

    var seerrTitle: SeerrTitle? { seerrTitle(defaultKind: nil) }

    func seerrTitle(defaultKind: SeerrTitle.Kind?) -> SeerrTitle? {
        guard let kind = mediaType.flatMap(SeerrTitle.Kind.init(rawValue:)) ?? (mediaType == nil ? defaultKind : nil),
              let name = title ?? self.name, !name.isEmpty else { return nil }
        let status = mediaInfo?.status.flatMap(SeerrMediaStatus.init(rawValue:))
        return SeerrTitle(tmdbID: id, kind: kind, title: name, overview: overview,
                          posterPath: posterPath, backdropPath: backdropPath,
                          releaseDate: kind == .movie ? releaseDate : firstAirDate,
                          availability: SeerrAvailability(mediaStatus: status))
    }
}

nonisolated private struct VideosDTO: Decodable {
    struct Video: Decodable { let key: String?; let site: String?; let type: String? }
    let relatedVideos: [Video]?
}

nonisolated private struct MovieDetailsDTO: Decodable {
    let mediaInfo: MediaInfoDTO?
}

nonisolated private struct TvDetailsDTO: Decodable {
    struct SeasonDTO: Decodable {
        let seasonNumber: Int
        let name: String?
        let episodeCount: Int?
    }
    let seasons: [SeasonDTO]?
    let mediaInfo: MediaInfoDTO?
}
