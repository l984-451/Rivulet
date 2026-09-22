// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexWatchlistAPI.swift
//  Rivulet
//
//  HTTP layer for the Plex Discover Watchlist.
//
//  Two host families are involved:
//
//  - `discover.provider.plex.tv` serves the watchlist itself
//    (`/library/sections/watchlist/all`) AND the actions
//    (`/actions/addToWatchlist`, `/actions/removeFromWatchlist`).
//    Container pagination headers are NOT accepted on the watchlist endpoint.
//
//  - `metadata.provider.plex.tv` serves the discover-side metadata, including
//    the matches lookup needed to resolve an external GUID (tmdb://, imdb://,
//    tvdb://) to a Plex Discover ratingKey. The action endpoints want THAT
//    ratingKey, not the external GUID.
//

import Foundation
import os.log

private let watchlistAPILog = Logger(subsystem: "com.rivulet.app", category: "PlexWatchlistAPI")

/// Custom error so the caller can tell why a watchlist request failed.
struct PlexWatchlistHTTPError: Error, LocalizedError {
    let statusCode: Int
    let bodySnippet: String?
    var errorDescription: String? {
        if let bodySnippet, !bodySnippet.isEmpty {
            return "HTTP \(statusCode): \(bodySnippet)"
        }
        return "HTTP \(statusCode)"
    }
}

protocol PlexWatchlistAPIProtocol: Sendable {
    func fetchAll(token: String) async throws -> [PlexWatchlistItem]
    /// `type` disambiguates the Discover match. Pass it whenever it's known:
    /// tmdb movie ids and tmdb TV ids are separate namespaces that collide on
    /// the same number, so probing movie-first can match a completely
    /// different title (see `resolveDiscoverRatingKey`).
    func add(guids: [String], type: PlexWatchlistItem.WatchlistType?, token: String) async throws
    func remove(guid: String, type: PlexWatchlistItem.WatchlistType?, token: String) async throws
}

protocol WatchlistCacheProtocol: Sendable {
    func load() -> [PlexWatchlistItem]?
    func save(_ items: [PlexWatchlistItem])
    func clear()
}

final class PlexWatchlistAPI: PlexWatchlistAPIProtocol, Sendable {
    /// Items per watchlist request. Plex accepts up to its own ceiling; 100
    /// keeps a typical watchlist to a single round trip.
    private static let pageSize = 100

    private let session: URLSession
    private let discoverHost = URL(string: "https://discover.provider.plex.tv")!
    private let metadataHost = URL(string: "https://metadata.provider.plex.tv")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchAll(token: String) async throws -> [PlexWatchlistItem] {
        // Page until the container's own totalSize is covered. Plex's default
        // page is larger than most watchlists, so the common case is one
        // request, but a long watchlist would otherwise be silently truncated
        // at whatever the default happens to be — and the grid surface shows
        // every entry, so a short read is visible.
        var items: [PlexWatchlistItem] = []
        var start = 0
        while true {
            let page = try await fetchPage(token: token, start: start)
            items += page.items
            // Advance and terminate on the RAW entry count, never on the
            // decoded one: a page holding only unsupported types decodes to
            // zero items while Plex still has more to give, and treating that
            // as the end would truncate the watchlist at that page.
            start += max(page.pageSize, page.rawCount)
            guard page.rawCount > 0, start < page.totalSize else { break }
        }
        return items
    }

    private struct WatchlistPage {
        let items: [PlexWatchlistItem]
        /// Entries Plex returned, before movie/show filtering.
        let rawCount: Int
        let totalSize: Int
        let pageSize: Int
    }

    private func fetchPage(token: String, start: Int) async throws -> WatchlistPage {
        let url = discoverHost.appendingPathComponent("library/sections/watchlist/all")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        // Container-Start is what makes Container-Size stick on Plex (the same
        // pairing rule the PMS endpoints follow); size alone is honoured here
        // too, but both are sent so the offset is never ambiguous.
        //
        // includeGuids=1 is required — without it, the `Guid` array is
        // omitted from the response and we can't resolve items to tmdb:// for
        // library matching or context-menu navigation.
        components.queryItems = [
            URLQueryItem(name: "includeGuids", value: "1"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(Self.pageSize)"),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]

        var request = URLRequest(url: components.url!)
        addPlexHeaders(to: &request)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        // `privacy: .public` persists in the device log archive, and the token is
        // a query param — log the URL shape, never its values.
        watchlistAPILog.info("fetchAll URL=\(SensitiveDataRedactor.safeURLStringOptional(request.url), privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(256), encoding: .utf8)
            watchlistAPILog.error("fetchAll HTTP \(http.statusCode) body=\(SensitiveDataRedactor.redactOptional(snippet) ?? "(non-utf8)", privacy: .public)")
            throw PlexWatchlistHTTPError(statusCode: http.statusCode, bodySnippet: snippet)
        }

        struct Container: Decodable {
            struct MediaContainer: Decodable {
                let totalSize: Int?
                let Metadata: [Raw]?
            }
            let MediaContainer: MediaContainer
        }
        struct Raw: Decodable {
            let ratingKey: String?
            let title: String?
            let year: Int?
            let type: String?
            let thumb: String?
            let guid: String?       // primary plex:// guid
            let Guid: [GuidRef]?
        }
        struct GuidRef: Decodable { let id: String }

        let decoded = try JSONDecoder().decode(Container.self, from: data)
        let raws = decoded.MediaContainer.Metadata ?? []

        let items = raws.compactMap { raw -> PlexWatchlistItem? in
            guard let title = raw.title, let id = raw.ratingKey else { return nil }
            let watchType: PlexWatchlistItem.WatchlistType
            switch raw.type {
            case "movie": watchType = .movie
            case "show": watchType = .show
            default: return nil
            }
            let guids = (raw.Guid ?? []).map(\.id)
            // Discover serves thumbs as fully-qualified URLs to public CDNs
            // (metadata-static.plex.tv, image.tmdb.org). Use them as-is; only
            // build a host-relative URL with the token when the thumb is a
            // relative path.
            let posterURL: URL? = raw.thumb.flatMap { thumb in
                if thumb.hasPrefix("http://") || thumb.hasPrefix("https://") {
                    return URL(string: thumb)
                }
                return URL(string: "\(self.discoverHost.absoluteString)\(thumb)?X-Plex-Token=\(token)")
            }
            return PlexWatchlistItem(
                id: id,
                title: title,
                year: raw.year,
                type: watchType,
                posterURL: posterURL,
                guids: guids,
                plexGUID: raw.guid
            )
        }
        return WatchlistPage(items: items,
                             rawCount: raws.count,
                             totalSize: decoded.MediaContainer.totalSize ?? raws.count,
                             pageSize: Self.pageSize)
    }

    func add(guids: [String], type: PlexWatchlistItem.WatchlistType?, token: String) async throws {
        for guid in guids {
            try await mutate(externalGuid: guid, action: "addToWatchlist", type: type, token: token)
        }
    }

    func remove(guid: String, type: PlexWatchlistItem.WatchlistType?, token: String) async throws {
        try await mutate(externalGuid: guid, action: "removeFromWatchlist", type: type, token: token)
    }

    /// Resolve an external GUID (tmdb://, imdb://, tvdb://) to the Plex Discover
    /// ratingKey, then issue the action.
    private func mutate(
        externalGuid: String, action: String,
        type: PlexWatchlistItem.WatchlistType?, token: String
    ) async throws {
        let plexRatingKey = try await resolveDiscoverRatingKey(
            forGuid: externalGuid, type: type, token: token
        )

        let url = discoverHost.appendingPathComponent("actions/\(action)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "ratingKey", value: plexRatingKey),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        addPlexHeaders(to: &request)
        watchlistAPILog.info("mutate \(action, privacy: .public) URL=\(SensitiveDataRedactor.safeURLStringOptional(request.url), privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(256), encoding: .utf8)
            watchlistAPILog.error("mutate \(action, privacy: .public) HTTP \(http.statusCode) body=\(SensitiveDataRedactor.redactOptional(snippet) ?? "(non-utf8)", privacy: .public)")
            throw PlexWatchlistHTTPError(statusCode: http.statusCode, bodySnippet: snippet)
        }
    }

    /// Hits Plex's metadata matches endpoint and returns the discover ratingKey
    /// (e.g. "5d7768daad5437001f75108e") for an external GUID.
    private func resolveDiscoverRatingKey(
        forGuid externalGuid: String,
        type: PlexWatchlistItem.WatchlistType?,
        token: String
    ) async throws -> String {
        // The matches endpoint expects a Plex media `type` integer: 1 = movie,
        // 2 = show. Probing movie-first and taking the first hit is wrong for a
        // tmdb guid — tmdb numbers movies and TV separately, so a show's id is
        // very often also a valid movie id, and the probe silently watchlists
        // an unrelated film (issue #269). Ask for the type we know.
        let ordered: [Int] = switch type {
        case .movie: [1]
        case .show: [2]
        case nil: [1, 2]      // imdb/tvdb only — those namespaces don't collide
        }
        for probe in ordered {
            if let ratingKey = try await matches(type: probe, externalGuid: externalGuid, token: token) {
                return ratingKey
            }
        }
        watchlistAPILog.error("resolveDiscoverRatingKey: no match for \(externalGuid, privacy: .public)")
        throw PlexWatchlistHTTPError(
            statusCode: 404,
            bodySnippet: "No Plex Discover match for \(externalGuid)"
        )
    }

    private func matches(type: Int, externalGuid: String, token: String) async throws -> String? {
        let url = metadataHost.appendingPathComponent("library/metadata/matches")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "\(type)"),
            URLQueryItem(name: "guid", value: externalGuid),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]

        var request = URLRequest(url: components.url!)
        addPlexHeaders(to: &request)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        watchlistAPILog.info("matches type=\(type) URL=\(SensitiveDataRedactor.safeURLStringOptional(request.url), privacy: .public)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(256), encoding: .utf8)
            throw PlexWatchlistHTTPError(statusCode: http.statusCode, bodySnippet: snippet)
        }

        struct Container: Decodable {
            struct MediaContainer: Decodable {
                let Metadata: [Raw]?
            }
            let MediaContainer: MediaContainer
        }
        struct Raw: Decodable { let ratingKey: String? }

        let decoded = try JSONDecoder().decode(Container.self, from: data)
        return decoded.MediaContainer.Metadata?.first?.ratingKey
    }

    private func addPlexHeaders(to request: inout URLRequest) {
        request.addValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.addValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.addValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")
    }
}

final class FileWatchlistCache: WatchlistCacheProtocol, @unchecked Sendable {
    private let url: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Bump filename when the on-disk schema changes (e.g. 2026-04-15 poster
        // URL fix, 2026-04-16 guids-missing fix) so stale cached items don't
        // persist after an update.
        url = caches.appendingPathComponent("PlexWatchlist.v3.json")
        // Best-effort cleanup of older versions.
        for stale in ["PlexWatchlist.json", "PlexWatchlist.v2.json"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(stale))
        }
    }

    func load() -> [PlexWatchlistItem]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([PlexWatchlistItem].self, from: data)
    }

    func save(_ items: [PlexWatchlistItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
