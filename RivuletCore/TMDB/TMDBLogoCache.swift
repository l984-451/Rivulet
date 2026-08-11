// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBLogoCache.swift
//  Rivulet
//
//  Resolves and caches TMDB clear-logo artwork URLs. Backed by memory + disk
//  caches and inflight-request dedup so the Discover hero slide and the
//  preview-overlay prefetch ring can both ask for the same logo without
//  duplicating work.
//
//  Entries store the TMDB relative path (e.g. `/abc.png`), not a full URL,
//  so changing the CDN size or base doesn't invalidate the cache. A
//  resolved `nil` (confirmed "no logo") is itself a cache hit — repeat
//  calls for the same id don't refetch.
//

import Foundation

actor TMDBLogoCache {
    static let shared = TMDBLogoCache()

    private let session: URLSession
    private let directory: URL
    private let ttl: TimeInterval = 60 * 60 * 24 * 30   // 30 days
    private static let cdnBase = "https://image.tmdb.org/t/p/w500"

    private struct Key: Hashable {
        let tmdbId: Int
        let type: TMDBMediaType
    }

    private struct CachedEntry: Codable {
        let resolvedAt: Date
        let logoPath: String?
    }

    private var memory: [Key: String?] = [:]
    private var inflight: [Key: Task<String?, Never>] = [:]

    init(session: URLSession? = nil, directory: URL? = nil) {
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
        self.directory = directory ?? caches.appendingPathComponent("TMDBLogoCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Resolves the logo URL for a TMDB id. Returns `nil` when no logo is available.
    /// Nil results are cached just like found URLs — we don't thrash the network
    /// asking "is there a logo?" for every page view of an item that has none.
    func logoURL(tmdbId: Int, type: TMDBMediaType) async -> URL? {
        let path = await logoPath(tmdbId: tmdbId, type: type)
        return path.flatMap { URL(string: "\(Self.cdnBase)\($0)") }
    }

    // MARK: - Resolution

    private func logoPath(tmdbId: Int, type: TMDBMediaType) async -> String? {
        let key = Key(tmdbId: tmdbId, type: type)

        if let cached = memory[key] { return cached }

        if let disk = loadFromDisk(key: key), Date().timeIntervalSince(disk.resolvedAt) < ttl {
            memory[key] = disk.logoPath
            return disk.logoPath
        }

        if let existing = inflight[key] {
            return await existing.value
        }

        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.fetchAndStore(key: key)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    private func fetchAndStore(key: Key) async -> String? {
        guard let data = try? await fetchData(tmdbId: key.tmdbId, type: key.type),
              let response = try? JSONDecoder().decode(TMDBImagesResponse.self, from: data) else {
            // Transient failure: don't poison the cache. Next call retries.
            return nil
        }

        let path = response.bestLogoPath
        memory[key] = path
        saveToDisk(key: key, entry: CachedEntry(resolvedAt: Date(), logoPath: path))
        return path
    }

    // MARK: - Networking

    private func fetchData(tmdbId: Int, type: TMDBMediaType) async throws -> Data {
        guard let base = URL(string: "tmdb/images/\(tmdbId)", relativeTo: TMDBConfig.proxyBaseURL) else {
            throw URLError(.badURL)
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "type", value: type.rawValue)]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.attestedData(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Disk

    private func diskURL(for key: Key) -> URL {
        directory.appendingPathComponent("\(key.type.rawValue)_\(key.tmdbId).json")
    }

    private func loadFromDisk(key: Key) -> CachedEntry? {
        guard let data = try? Data(contentsOf: diskURL(for: key)) else { return nil }
        return try? JSONDecoder().decode(CachedEntry.self, from: data)
    }

    private func saveToDisk(key: Key, entry: CachedEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: diskURL(for: key), options: [.atomic])
    }
}
