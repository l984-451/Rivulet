// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBDiscoverService.swift
//  Rivulet
//
//  Fetches list/discover/details endpoints from the TMDB proxy with caching.
//

import Foundation

actor TMDBDiscoverService {
    static let shared = TMDBDiscoverService()

    private let session: URLSession
    private let listCacheTTL: TimeInterval = 60 * 60                // 1 hour: prefer fresh
    private let listDiskFallbackTTL: TimeInterval = 60 * 60 * 24 * 7 // 1 week: usable cold-launch fallback
    private let detailCacheTTL: TimeInterval = 60 * 60 * 24 * 30    // 30 days

    private struct ListCacheEntry {
        let fetchedAt: Date
        let items: [TMDBListItem]
    }

    private var listCache: [TMDBDiscoverSection: ListCacheEntry] = [:]
    private let listCacheDirectory: URL
    private let detailCacheDirectory: URL

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        listCacheDirectory = caches.appendingPathComponent("TMDBDiscoverListCache", isDirectory: true)
        detailCacheDirectory = caches.appendingPathComponent("TMDBDiscoverDetailCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: listCacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: detailCacheDirectory, withIntermediateDirectories: true)
    }

    func fetchSection(_ section: TMDBDiscoverSection) async -> [TMDBListItem] {
        // 1) Hot in-memory cache (1h)
        if let cached = listCache[section],
           Date().timeIntervalSince(cached.fetchedAt) < listCacheTTL {
            return cached.items
        }

        // 2) Warm disk cache (1h): same TTL but survives launches
        if let cached = loadListFromDisk(section: section, maxAge: listCacheTTL) {
            listCache[section] = ListCacheEntry(fetchedAt: cached.savedAt, items: cached.items)
            return cached.items
        }

        let endpoint = "tmdb/list/\(section.proxyPath)"
        let queryItems = [URLQueryItem(name: "type", value: section.mediaType.rawValue)]

        struct ListResponse: Decodable {
            let results: [TMDBListItem]
        }

        let data: Data
        do {
            data = try await fetchData(endpoint: endpoint, queryItems: queryItems)
        } catch {
            // 3) Cold disk fallback (up to 1 week stale): better than nothing
            if let cached = loadListFromDisk(section: section, maxAge: listDiskFallbackTTL) {
                return cached.items
            }
            return []
        }

        do {
            let response = try JSONDecoder().decode(ListResponse.self, from: data)
            // Stamp media type from caller (list endpoints don't include media_type).
            let stamped = response.results.map { item -> TMDBListItem in
                TMDBListItem(
                    id: item.id,
                    title: item.title,
                    overview: item.overview,
                    posterPath: item.posterPath,
                    backdropPath: item.backdropPath,
                    releaseDate: item.releaseDate,
                    voteAverage: item.voteAverage,
                    mediaType: section.mediaType
                )
            }
            listCache[section] = ListCacheEntry(fetchedAt: Date(), items: stamped)
            saveListToDisk(stamped, section: section)
            return stamped
        } catch {
            if let cached = loadListFromDisk(section: section, maxAge: listDiskFallbackTTL) {
                return cached.items
            }
            return []
        }
    }

    func fetchDetail(tmdbId: Int, type: TMDBMediaType) async -> TMDBItemDetail? {
        if let cached = loadDetailFromDisk(tmdbId: tmdbId, type: type) {
            return cached
        }

        let endpoint = "tmdb/details/\(tmdbId)"
        let queryItems = [URLQueryItem(name: "type", value: type.rawValue)]

        guard let data = try? await fetchData(endpoint: endpoint, queryItems: queryItems),
              let decoded = try? JSONDecoder().decode(TMDBItemDetail.self, from: data) else {
            return nil
        }
        let detail = TMDBItemDetail(
            id: decoded.id,
            title: decoded.title,
            overview: decoded.overview,
            posterPath: decoded.posterPath,
            backdropPath: decoded.backdropPath,
            releaseDate: decoded.releaseDate,
            runtime: decoded.runtime,
            genres: decoded.genres,
            voteAverage: decoded.voteAverage,
            cast: decoded.cast,
            mediaType: type
        )
        saveDetailToDisk(detail, tmdbId: tmdbId, type: type)
        return detail
    }

    // MARK: - Discover (For You)

    func discover(type: TMDBMediaType, withGenres: [Int], withKeywords: [Int]) async -> [TMDBListItem] {
        var items = [URLQueryItem(name: "type", value: type.rawValue)]
        if !withGenres.isEmpty {
            items.append(URLQueryItem(name: "with_genres", value: withGenres.map(String.init).joined(separator: "|")))
        }
        if !withKeywords.isEmpty {
            items.append(URLQueryItem(name: "with_keywords", value: withKeywords.map(String.init).joined(separator: "|")))
        }
        items.append(URLQueryItem(name: "sort_by", value: "popularity.desc"))

        struct ListResponse: Decodable { let results: [TMDBListItem] }

        guard let data = try? await fetchData(endpoint: "tmdb/discover/\(type.rawValue)", queryItems: items),
              let response = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            return []
        }
        return response.results.map { item in
            TMDBListItem(
                id: item.id,
                title: item.title,
                overview: item.overview,
                posterPath: item.posterPath,
                backdropPath: item.backdropPath,
                releaseDate: item.releaseDate,
                voteAverage: item.voteAverage,
                mediaType: type
            )
        }
    }

    // MARK: - Networking

    private func fetchData(endpoint: String, queryItems: [URLQueryItem]) async throws -> Data {
        guard let url = URL(string: endpoint, relativeTo: TMDBConfig.proxyBaseURL) else {
            throw URLError(.badURL)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.queryItems = queryItems
        guard let finalURL = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.attestedData(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Disk Cache (List)

    private struct CachedList: Codable {
        let savedAt: Date
        let items: [TMDBListItem]
    }

    private func listCacheURL(section: TMDBDiscoverSection) -> URL {
        listCacheDirectory.appendingPathComponent("\(section.rawValue).json")
    }

    private func loadListFromDisk(section: TMDBDiscoverSection, maxAge: TimeInterval) -> CachedList? {
        let url = listCacheURL(section: section)
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedList.self, from: data),
              Date().timeIntervalSince(cached.savedAt) < maxAge else { return nil }
        return cached
    }

    private func saveListToDisk(_ items: [TMDBListItem], section: TMDBDiscoverSection) {
        let cached = CachedList(savedAt: Date(), items: items)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: listCacheURL(section: section), options: [.atomic])
    }

    // MARK: - Disk Cache (Detail)

    private func detailCacheURL(tmdbId: Int, type: TMDBMediaType) -> URL {
        detailCacheDirectory.appendingPathComponent("\(type.rawValue)_\(tmdbId).json")
    }

    private struct CachedDetail: Codable {
        let savedAt: Date
        let detail: TMDBItemDetail
    }

    private func loadDetailFromDisk(tmdbId: Int, type: TMDBMediaType) -> TMDBItemDetail? {
        let url = detailCacheURL(tmdbId: tmdbId, type: type)
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedDetail.self, from: data),
              Date().timeIntervalSince(cached.savedAt) < detailCacheTTL else { return nil }
        return cached.detail
    }

    private func saveDetailToDisk(_ detail: TMDBItemDetail, tmdbId: Int, type: TMDBMediaType) {
        let cached = CachedDetail(savedAt: Date(), detail: detail)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: detailCacheURL(tmdbId: tmdbId, type: type), options: [.atomic])
    }
}
