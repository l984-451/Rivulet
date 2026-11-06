// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import os

nonisolated final class SiloProvider: MediaProvider, Sendable {
    let id: String
    let kind: MediaProviderKind = .silo
    let displayName: String
    let connectionState: ConnectionState = .connected
    let profileID: String
    let client: SiloClient
    let authorityRevision: UInt64
    var accountID: String? { profileID }
    let supportsWatchlist = true
    let supportsFavorites = true
    let supportsPlaylists = false
    let showsHubBrowseAll = false
    let reservesPlaybackOnResolve = true
    let playbackSessions = OSAllocatedUnfairLock(initialState: [String: SiloPlaybackSession]())

    init(serverID: String, displayName: String, profileID: String, client: SiloClient, authorityRevision: UInt64 = 0) {
        self.id = "silo:\(serverID):\(profileID)"
        self.displayName = displayName
        self.profileID = profileID
        self.client = client
        self.authorityRevision = authorityRevision
    }

    static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // A card's backdrop also becomes the Home hero and expanded carousel.
    // Request that slot at full decode width, not Silo's 300px card default.
    // Episode stills likewise fill the detail page; logos stay in the small tier.
    // The server selects and signs each variant. Never resize an opaque URL.
    static let artworkQuery = [
        URLQueryItem(name: "image_size", value: "large"),
        URLQueryItem(name: "poster_width", value: String(Int(ImageQuality.thumb.maxPixelSize))),
        URLQueryItem(name: "backdrop_width", value: String(Int(ImageQuality.full.maxPixelSize))),
        URLQueryItem(name: "still_width", value: String(Int(ImageQuality.full.maxPixelSize))),
        URLQueryItem(name: "logo_width", value: String(Int(ImageQuality.thumb.maxPixelSize)))
    ]

    func getArtwork<T: Decodable & Sendable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var params = query
        params.reserveCapacity(query.count + Self.artworkQuery.count)
        for value in Self.artworkQuery where !query.contains(where: { $0.name == value.name }) {
            params.append(value)
        }
        return try await client.get(path, params)
    }

    func map(_ items: [SiloItem], libraryID: String? = nil) -> [MediaItem] {
        items.map { SiloMediaMapper.item($0, providerID: id, baseURL: client.baseURL, libraryID: libraryID) }
    }

    func libraries() async throws -> [MediaLibrary] {
        // Unlike administrative /libraries, this route is the acting profile's
        // accessible library presentation and does not expose filesystem paths.
        let result: SiloList<SiloLibrary> = try await client.get("user/libraries")
        return result.items.sorted { $0.sortOrder < $1.sortOrder }.compactMap { library in
            let kind: MediaLibrary.LibraryKind
            switch library.type {
            case "movies": kind = .movies
            case "series": kind = .shows
            case "mixed": kind = .mixed
            default: return nil
            }
            return MediaLibrary(id: library.id, providerID: id, title: library.name, kind: kind)
        }
    }

    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        try await catalog([
            URLQueryItem(name: "library_id", value: library.id),
            URLQueryItem(name: "type", value: library.kind == .movies ? "movie" : library.kind == .shows ? "series" : "video"),
            URLQueryItem(name: "sort", value: Self.sort(sort))
        ], page: page)
    }

    static func sort(_ value: SortOption) -> String {
        switch value {
        case .titleAsc: "title"
        case .titleDesc: "-title"
        case .releaseDateDesc: "-release_date"
        case .releaseDateAsc: "release_date"
        case .addedAtDesc: "-added_at"
        case .addedAtAsc: "added_at"
        case .ratingDesc: "-rating"
        case .lastContentAddedDesc: "-latest_episode_added"
        }
    }

    func catalog(_ query: [URLQueryItem], page: Page) async throws -> PagedResult<MediaItem> {
        var params = query + [URLQueryItem(name: "limit", value: String(min(max(page.limit, 1), 200)))]
        if let cursor = page.cursor {
            params.append(URLQueryItem(name: "cursor", value: cursor))
        } else if page.offset > 0 {
            params.append(URLQueryItem(name: "seek", value: String(page.offset)))
        }
        let result: SiloCatalogPage = try await getArtwork("catalog", params)
        let items = map(result.items, libraryID: query.first(where: { $0.name == "library_id" })?.value)
        let next = try nextPage(result.page, offset: page.offset + items.count, limit: page.limit)
        return PagedResult(items: items, total: result.total, nextPage: next)
    }

    func nextPage(_ info: SiloPageInfo?, offset: Int, limit: Int) throws -> Page? {
        guard info?.hasMore == true else { return nil }
        guard let cursor = info?.nextCursor, !cursor.isEmpty else {
            throw MediaProviderError.backendSpecific(underlying: "Silo returned a next page without its cursor.")
        }
        return Page(offset: offset, limit: limit, cursor: cursor)
    }

    func allCatalog(_ query: [URLQueryItem]) async throws -> [MediaItem] {
        var page: Page? = Page(offset: 0, limit: 200)
        var items: [MediaItem] = []
        var seen = Set<String>()
        while let current = page {
            let result = try await catalog(query, page: current)
            items += result.items
            page = result.nextPage
            if let cursor = page?.cursor, !seen.insert(cursor).inserted {
                throw MediaProviderError.backendSpecific(underlying: "Silo repeated a catalog cursor.")
            }
        }
        return items
    }

    func allItems<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> [T] {
        var items: [T] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var params = query + [URLQueryItem(name: "limit", value: "200")]
            if let cursor { params.append(URLQueryItem(name: "cursor", value: cursor)) }
            let result: SiloList<T> = try await client.get(path, params)
            items += result.items
            cursor = try nextPage(result.page, offset: items.count, limit: 200)?.cursor
            if let cursor, !seen.insert(cursor).inserted {
                throw MediaProviderError.backendSpecific(underlying: "Silo repeated a list cursor.")
            }
        } while cursor != nil
        return items
    }

    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] {
        if itemRef.itemID.hasPrefix("siloCollection|") {
            let ref = try SiloCollectionRef.decode(itemRef.itemID)
            var query = [URLQueryItem(name: "source", value: ref.libraryId == nil ? "user_collection" : "library_collection"),
                         URLQueryItem(name: "collection_id", value: ref.collectionId)]
            if let libraryID = ref.libraryId { query.append(URLQueryItem(name: "library_id", value: libraryID)) }
            return try await allCatalog(query)
        }
        let item: SiloItem = try await getArtwork("catalog/items/\(Self.pathComponent(itemRef.itemID))")
        if item.type == "series" {
            let result: SiloList<SiloItem> = try await getArtwork("catalog/series/\(Self.pathComponent(itemRef.itemID))/seasons")
            return result.items.map { dto in
                var season = dto
                season.type = "season"
                season.seriesId = item.contentId
                season.seriesTitle = item.title
                return SiloMediaMapper.item(season, providerID: id, baseURL: client.baseURL)
            }
        }
        if item.type == "season", let series = item.seriesId, let number = item.seasonNumber {
            let result: SiloList<SiloItem> = try await getArtwork("catalog/series/\(Self.pathComponent(series))/seasons/\(number)/episodes")
            return result.items.map { dto in
                var episode = dto
                episode.type = "episode"
                episode.seriesId = series
                episode.seriesTitle = item.seriesTitle
                return SiloMediaMapper.item(episode, providerID: id, baseURL: client.baseURL, parentID: item.contentId)
            }
        }
        return []
    }

    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] {
        let show: SiloItem = try await getArtwork("catalog/items/\(Self.pathComponent(showRef.itemID))")
        let seasons: SiloList<SiloItem> = try await getArtwork("catalog/series/\(Self.pathComponent(showRef.itemID))/seasons")
        var episodes: [MediaItem] = []
        for season in seasons.items {
            // This endpoint accepts a season content_id, not the series id.
            let result: SiloList<SiloItem> = try await getArtwork("catalog/items/\(Self.pathComponent(season.contentId))/episodes")
            episodes += result.items.map { dto in
                var episode = dto
                episode.type = "episode"
                episode.seriesId = show.contentId
                episode.seriesTitle = show.title
                return SiloMediaMapper.item(episode, providerID: id, baseURL: client.baseURL, parentID: season.contentId)
            }
        }
        return episodes
    }

    func search(_ query: String) async throws -> [MediaItem] {
        try await search(query, inLibraries: [])
    }

    func search(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaItem] {
        let capabilities: SiloSearchCapabilities = try await client.get("catalog/search/capabilities")
        let scopes = capabilities.videoWithEpisodesScope == true ? ["video_with_episodes"] : ["video", "episode"]
        let libraries: [String?] = libraryIDs.isEmpty ? [nil] : libraryIDs.map(Optional.some)
        var results: [MediaItem] = []
        var seen = Set<MediaItemRef>()
        for library in libraries {
            for scope in scopes {
                var params = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: scope)]
                if let library { params.append(URLQueryItem(name: "library_id", value: library)) }
                let found = try await allCatalog(params)
                results += found.filter { seen.insert($0.ref).inserted }
            }
        }
        return results
    }

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        if itemRef.itemID.hasPrefix("external:") {
            let titles: [SiloWatchlistTitle] = try await allItems("watchlist/titles")
            guard let title = titles.first(where: { "external:\($0.mediaType):\($0.tmdbId)" == itemRef.itemID }) else {
                throw MediaProviderError.notFound
            }
            var detail = SiloMediaMapper.unavailableDetail(externalItem(title))
            detail.externalIDs = ["tmdb": String(title.tmdbId)]
            detail.ratings = [MediaRating(title.voteAverage, source: .tmdb)].compactMap { $0 }
            return detail
        }
        if itemRef.itemID.hasPrefix("siloCollection|") {
            let ref = try SiloCollectionRef.decode(itemRef.itemID)
            let collection: SiloCollection
            if let libraryID = ref.libraryId {
                let result: SiloCuratedCollections = try await getArtwork("library/\(Self.pathComponent(libraryID))/collections")
                guard let found = result.collections.first(where: { $0.id == ref.collectionId }) else { throw MediaProviderError.notFound }
                collection = found
            } else {
                collection = try await getArtwork("collections/\(Self.pathComponent(ref.collectionId))")
            }
            return SiloMediaMapper.unavailableDetail(collectionItem(collection, libraryID: ref.libraryId))
        }
        // Episode detail puts its full-screen still in poster_url, not still_url.
        // A detail poster can also be the carousel's fallback full-screen art.
        let detailArtwork = [URLQueryItem(name: "poster_width", value: String(Int(ImageQuality.full.maxPixelSize)))]
        let dto: SiloItem = try await getArtwork("catalog/items/\(Self.pathComponent(itemRef.itemID))", detailArtwork)
        var next: SiloItem?
        if ["series", "season"].contains(dto.type ?? ""), let playID = dto.playContentId, playID != dto.contentId {
            next = try await getArtwork("catalog/items/\(Self.pathComponent(playID))", detailArtwork)
        }
        var parentID: String?
        if dto.type == "episode", let series = dto.seriesId, let number = dto.seasonNumber {
            let season: SiloItem = try await getArtwork("catalog/series/\(Self.pathComponent(series))/seasons/\(number)")
            parentID = season.contentId
        }
        // Supplemental curator-visible columns must still respect the server's
        // enabled source policy. If unavailable, keep the canonical ratings only.
        let ratingCapability: SiloRatingsCapability? = dto.hasSupplementalRTRatings
            ? try? await client.get("capabilities/ratings") : nil
        return SiloMediaMapper.detail(dto, providerID: id, baseURL: client.baseURL, authorityRevision: authorityRevision, parentID: parentID,
                                     nextEpisode: next, ratingSources: ratingCapability?.sources ?? [])
    }

    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        guard !ref.itemID.hasPrefix("external:"), !ref.itemID.hasPrefix("siloCollection|") else {
            return RelatedContent(items: [], collection: nil)
        }
        let result: SiloList<SiloItem> = try await getArtwork("recommendations/similar/\(Self.pathComponent(ref.itemID))", [URLQueryItem(name: "limit", value: "20")])
        return RelatedContent(items: map(result.items), collection: nil)
    }

    func markPlayed(_ itemRef: MediaItemRef) async throws {
        try await client.post("watched/\(Self.pathComponent(itemRef.itemID))")
    }

    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        try await client.delete("watched/\(Self.pathComponent(itemRef.itemID))")
    }

    func itemIdentityKeys(for itemIDs: [String]) async -> [String: [String]] {
        var results: [String: [String]] = [:]
        for itemID in itemIDs {
            guard let item: SiloItem = try? await client.get("catalog/items/\(Self.pathComponent(itemID))") else { continue }
            var ids: [String: String] = [:]
            ids["tmdb"] = item.tmdbId
            ids["imdb"] = item.imdbId
            ids["tvdb"] = item.tvdbId
            results[itemID] = ContinueWatchingMerge.providerIDKeys(ids, scope: item.type == "movie" ? "m" : "s")
        }
        return results
    }

    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras {
        let query = sourceID.map { [URLQueryItem(name: "file_id", value: $0)] } ?? []
        guard let watch: SiloItem = try? await client.get("watch/\(Self.pathComponent(itemRef.itemID))", query) else { return PlaybackExtras() }
        let source: SiloVersion?
        if let sourceID {
            source = watch.versions?.first(where: { $0.fileId == sourceID })
            guard source != nil else { return PlaybackExtras() }
        } else { source = watch.versions?.first }
        if let occurrences = source?.markerSegments {
            return PlaybackExtras(markers: occurrences.compactMap { marker in
                guard let kind = PlaybackMarker.Kind(rawValue: marker.kind) else { return nil }
                return PlaybackMarker(kind: kind, start: marker.startSeconds, end: marker.endSeconds)
            }.sorted { $0.start < $1.start })
        }
        let markers: [(PlaybackMarker.Kind, SiloMarker?)] = [
            (.intro, source?.intro ?? watch.intro), (.credits, source?.credits ?? watch.credits),
            (.recap, source?.recap ?? watch.recap), (.preview, source?.preview ?? watch.preview)
        ]
        return PlaybackExtras(markers: markers.compactMap { kind, marker in
            marker.map { PlaybackMarker(kind: kind, start: $0.start, end: $0.end) }
        }.sorted { $0.start < $1.start })
    }
}
