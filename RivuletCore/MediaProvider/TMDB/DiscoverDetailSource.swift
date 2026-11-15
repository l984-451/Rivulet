// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Fills the detail page of a title the library doesn't have (a Discover pick, a Seerr request
// result) the way a library title's page is filled: from Plex metadata, through the same
// `getFullMetadata` + `PlexMediaMapper.detail` a server's title goes through. Plex Discover
// (metadata.provider.plex.tv) answers `/library/metadata/<key>` for every title, owned or not.
//
// It wraps the TMDB catalog source under the same id, so the item stays metadata-only (no Play,
// no Watched). Without a Plex account it asks Seerr when that is set up, and anything neither can
// answer falls back to TMDB as before.

import Foundation
import os

private let log = Logger(subsystem: "com.rivulet.app", category: "DiscoverDetail")

final class DiscoverDetailSource: MetadataSource, @unchecked Sendable {
    static let discoverHost = "https://metadata.provider.plex.tv"

    private let fallback: any MetadataSource
    /// The last few titles' details: expanding a card asks again for the one its top already showed.
    private let cache = DetailCache(limit: 20)

    init(fallback: any MetadataSource) {
        self.fallback = fallback
    }

    func curatedSection(_ section: CuratedSection) async throws -> [MediaItem] {
        try await fallback.curatedSection(section)
    }

    func search(_ query: String) async throws -> [MediaItem] {
        try await fallback.search(query)
    }

    func recommendations(for ref: MediaItemRef) async throws -> [MediaItem] {
        try await fallback.recommendations(for: ref)
    }

    func itemDetail(_ ref: MediaItemRef) async throws -> MediaItemDetail {
        if let cached = cache[ref.itemID] { return cached }
        async let tmdb = try? fallback.itemDetail(ref)
        async let trailer = seerrTrailer(ref)
        // Plex Discover first (what a library title's page reads), then Seerr (a Jellyfin or
        // Emby install has no Plex account), then TMDB's catalog as before.
        var rich: MediaItemDetail?
        do {
            rich = try await plexDetail(ref)
        } catch is NothingToAsk {
        } catch {
            log.error("Discover detail failed for \(ref.itemID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        if rich == nil {
            do {
                rich = try await seerrDetail(ref)
            } catch is NothingToAsk {
            } catch {
                log.error("Seerr detail failed for \(ref.itemID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        guard let rich else {
            if let tmdb = await tmdb { return tmdb }
            throw MediaProviderError.notFound
        }
        let merged = Self.merge(rich, tmdb: await tmdb, trailer: await trailer, ref: ref)
        cache[ref.itemID] = merged
        return merged
    }

    // MARK: - Sources

    /// No Plex account, or no Seerr: an expected fallback, not a failure to log.
    private struct NothingToAsk: Error {}

    private func plexDetail(_ ref: MediaItemRef) async throws -> MediaItemDetail {
        guard let (tmdbID, type) = TMDBMediaMapper.decodeItemID(ref.itemID),
              let token = await MainActor.run(body: { PlexAuthManager.shared.authToken }) else {
            throw NothingToAsk()
        }
        let key = try await discoverKey(tmdbID: tmdbID, isMovie: type == .movie, token: token)
        let meta = try await PlexNetworkManager.shared.getFullMetadata(
            serverURL: Self.discoverHost, authToken: token, ratingKey: key)
        return PlexMediaMapper.detail(meta, providerID: TMDBMediaMapper.providerID,
                                      serverURL: Self.discoverHost, authToken: token)
    }

    private func seerrDetail(_ ref: MediaItemRef) async throws -> MediaItemDetail {
        guard let (tmdbID, type) = TMDBMediaMapper.decodeItemID(ref.itemID),
              let client = await MainActor.run(body: { SeerrClient.configured }) else { throw NothingToAsk() }
        return try await client.titleDetail(type == .movie ? .movie : .tv, tmdbID)
    }

    /// The title's YouTube trailer from Seerr, which each app's Extras row already plays
    /// (`MediaItemDetail.youTubeTrailerID`). Discover's own extras are server files.
    private func seerrTrailer(_ ref: MediaItemRef) async -> URL? {
        guard let (tmdbID, type) = TMDBMediaMapper.decodeItemID(ref.itemID),
              let client = await MainActor.run(body: { SeerrClient.configured }),
              let key = try? await client.trailerKey(type == .movie ? .movie : .tv, tmdbID) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
    }

    /// The Discover ratingKey for a TMDB id. The type is always given: TMDB numbers movies and
    /// shows separately, so an untyped probe can land on an unrelated title (#269).
    private func discoverKey(tmdbID: Int, isMovie: Bool, token: String) async throws -> String {
        var components = URLComponents(string: "\(Self.discoverHost)/library/metadata/matches")!
        components.queryItems = [
            URLQueryItem(name: "type", value: isMovie ? "1" : "2"),
            URLQueryItem(name: "guid", value: "tmdb://\(tmdbID)"),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let key = try Self.ratingKey(fromMatches: data) else {
            throw MediaProviderError.notFound
        }
        return key
    }

    static func ratingKey(fromMatches data: Data) throws -> String? {
        struct Container: Decodable {
            struct Inner: Decodable { let Metadata: [Raw]? }
            struct Raw: Decodable { let ratingKey: String? }
            let MediaContainer: Inner
        }
        return try JSONDecoder().decode(Container.self, from: data).MediaContainer.Metadata?.first?.ratingKey
    }

    // MARK: - Merge

    /// The richer detail, carried on the TMDB item so the page still treats the title as not in
    /// the library. Files, chapters and Plex extras are dropped: they would offer versions and
    /// extras only a server can play; `trailer` (YouTube) stands in. The item gains the age rating
    /// and runtime when TMDB has none.
    static func merge(_ rich: MediaItemDetail, tmdb: MediaItemDetail?, trailer: URL? = nil,
                      ref: MediaItemRef) -> MediaItemDetail {
        let base = tmdb?.item ?? rich.item
        let other = rich.item
        let item = MediaItem(
            ref: ref,
            kind: base.kind,
            title: base.title,
            sortTitle: base.sortTitle,
            overview: base.overview ?? other.overview,
            year: base.year ?? other.year,
            releaseDate: base.releaseDate ?? other.releaseDate,
            contentRating: base.contentRating ?? other.contentRating ?? rich.contentRating,
            runtime: base.runtime ?? other.runtime,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: base.userState,
            artwork: base.artwork,
            parentArtwork: nil,
            grandparentArtwork: nil
        )
        var detail = MediaItemDetail(
            item: item,
            tagline: rich.tagline,
            genres: rich.genres.isEmpty ? (tmdb?.genres ?? []) : rich.genres,
            studios: rich.studios,
            cast: rich.cast.isEmpty ? (tmdb?.cast ?? []) : rich.cast,
            directors: rich.directors,
            writers: rich.writers,
            chapters: [],
            mediaSources: [],
            trailerURL: trailer,
            contentRating: rich.contentRating,
            ratings: rich.ratings.isEmpty ? (tmdb?.ratings ?? []) : rich.ratings,
            nextEpisode: nil,
            collections: []
        )
        detail.regionOfOrigin = rich.regionOfOrigin
        detail.reviews = rich.reviews
        detail.contentAdvisory = rich.contentAdvisory
        detail.externalIDs = rich.externalIDs
        return detail
    }
}

/// A small bounded map, safe across tasks.
private final class DetailCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: MediaItemDetail] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    subscript(key: String) -> MediaItemDetail? {
        get { lock.withLock { entries[key] } }
        set {
            lock.withLock {
                if entries[key] == nil { order.append(key) }
                entries[key] = newValue
                while order.count > limit { entries.removeValue(forKey: order.removeFirst()) }
            }
        }
    }
}
