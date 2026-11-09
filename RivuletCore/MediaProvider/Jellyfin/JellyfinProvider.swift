// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinProvider.swift
//  Rivulet
//
//  Jellyfin implementation of MediaProvider: one instance per signed-in
//  server. Targets the Jellyfin 12 API; every route used here is unchanged
//  back to 10.10 (JellyfinSession.minimumVersion).
//

import Foundation
import os

final class JellyfinProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .jellyfin
    nonisolated let displayName: String
    let connectionState: ConnectionState = .connected
    let supportsWatchlist = false

    let userID: String
    let client: JellyfinClient

    /// `now` is the clock the owned-id index ages by.
    private let now: @Sendable () -> Date

    init(serverID: String, displayName: String, userID: String, client: JellyfinClient,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.id = "jellyfin:\(serverID)"
        self.displayName = displayName
        self.userID = userID
        self.client = client
    }

    /// PlaySessionIds handed out as HLS transcodes, so the reporter (built
    /// from the protocol, which cannot see the stream kind) can say Transcode
    /// and stop the encoding.
    private let transcodeSessions = OSAllocatedUnfairLock(initialState: Set<String>())

    private var baseURL: URL { client.baseURL }
    private var token: String { client.token ?? "" }

    /// What every list call asks for beyond the defaults: the counts behind
    /// "12/24 watched", and the parent image ids that list responses omit
    /// otherwise. Detail calls (GET /Items/{id}) return every field.
    private static let listFields = URLQueryItem(
        name: "fields", value: "Overview,RecursiveItemCount,SortName,ParentId,MediaSourceCount,Genres,ProviderIds"
    )

    private func map(_ dtos: [JFItem]?) -> [MediaItem] {
        (dtos ?? []).map { JellyfinMediaMapper.item($0, providerID: id, baseURL: baseURL) }
    }

    // MARK: - Browse

    func libraries() async throws -> [MediaLibrary] {
        let result: JFQueryResult = try await client.get("UserViews")
        var libraries: [MediaLibrary] = []
        for view in result.items ?? [] {
            // One count per "homevideos" view decides photo browser or video page.
            var content = HomeVideosContent.videos
            if view.collectionType == "homevideos", let viewID = view.id {
                content = try await self.homeVideosContent(libraryID: viewID)
            }
            if let library = JellyfinMediaMapper.library(view, providerID: id, homeVideos: content) {
                libraries.append(library)
            }
        }
        return libraries
    }

    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        try await items(in: library, sort: sort, filter: .none, page: page)
    }

    func items(in library: MediaLibrary, sort: SortOption, filter: LibraryFilter, page: Page) async throws -> PagedResult<MediaItem> {
        try await listing(libraryQuery(library, sort: sort, filter: filter), page: page)
    }

    /// Genres by item id (`GenreIds`) and the years present (`Items/Filters`), grouped into decades.
    func filterOptions(in library: MediaLibrary) async throws -> LibraryFilterOptions {
        let scope = [URLQueryItem(name: "parentId", value: library.id),
                     URLQueryItem(name: "includeItemTypes", value: Self.itemTypes(for: library.kind))]
        async let genres: JFQueryResult = client.get("Genres", scope)
        async let filters: JFFilters = client.get("Items/Filters", scope)
        return try await LibraryFilterOptions(
            genres: (genres.items ?? []).compactMap { item in
                guard let id = item.id, let name = item.name else { return nil }
                return LibraryGenre(id: id, name: name)
            },
            decades: LibraryFilterOptions.decades(fromYears: filters.years ?? [])
        )
    }

    /// The `Items` parameters for a filter: `filters=IsUnplayed`, `genreIds`, and a `years` list for the decade.
    nonisolated static func filterQuery(_ filter: LibraryFilter) -> [URLQueryItem] {
        var query: [URLQueryItem] = []
        if filter.unwatchedOnly { query.append(URLQueryItem(name: "filters", value: "IsUnplayed")) }
        if let genre = filter.genre { query.append(URLQueryItem(name: "genreIds", value: genre.id)) }
        if filter.decade != nil {
            query.append(URLQueryItem(name: "years", value: filter.decadeYears.map(String.init).joined(separator: ",")))
        }
        return query
    }

    /// The query that defines a library listing, without its page.
    private func libraryQuery(_ library: MediaLibrary, sort: SortOption, itemTypes: String? = nil,
                              filter: LibraryFilter = .none) -> [URLQueryItem] {
        let (sortBy, order) = Self.sortParameters(sort)
        let query = [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: itemTypes ?? Self.itemTypes(for: library.kind)),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortOrder", value: order)
        ]
        return query + Self.filterQuery(filter)
    }

    func shuffledItems(in library: MediaLibrary, unwatchedOnly: Bool, limit: Int) async throws -> [MediaItem] {
        var query = [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: Self.shuffleItemTypes(for: library.kind)),
            URLQueryItem(name: "sortBy", value: "Random"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            // No unaired placeholder episodes.
            URLQueryItem(name: "isMissing", value: "false"),
            Self.listFields
        ]
        if unwatchedOnly { query.append(URLQueryItem(name: "filters", value: "IsUnplayed")) }
        let result: JFQueryResult = try await client.get("Items", query)
        return map(result.items)
    }

    /// What a shuffle plays: a TV library's episodes rather than its series.
    static func shuffleItemTypes(for kind: MediaLibrary.LibraryKind) -> String {
        switch kind {
        case .movies: "Movie"
        case .shows: "Episode"
        default: "Movie,Video,MusicVideo,Episode"
        }
    }

    private func listing(_ query: [URLQueryItem], page: Page, path: String = "Items") async throws -> PagedResult<MediaItem> {
        let result: JFQueryResult = try await client.get(path, query + [
            URLQueryItem(name: "startIndex", value: "\(page.offset)"),
            URLQueryItem(name: "limit", value: "\(page.limit)"),
            URLQueryItem(name: "enableTotalRecordCount", value: "true"),
            Self.listFields
        ])
        let items = map(result.items)
        let total = result.totalRecordCount ?? items.count
        let next: Page? = (page.offset + page.limit < total)
            ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
        return PagedResult(items: items, total: total, nextPage: next)
    }

    /// A row's See All. Only Recently Added pages: its key is the library listing newest first, which
    /// `Items/Latest` cannot page. The first rows can differ from `Latest`'s grouping.
    func hubPage(_ hub: MediaHub, page: Page) async throws -> PagedResult<MediaItem> {
        guard let key = hub.pagingKey, let components = URLComponents(string: key) else {
            return PagedResult(items: page.offset == 0 ? hub.items : [], total: hub.items.count, nextPage: nil)
        }
        return try await listing(components.queryItems ?? [], page: page, path: components.path)
    }

    /// Show -> seasons, season -> episodes, anything else -> direct children.
    /// The ref carries no type, so the item is fetched first. Episodes go
    /// through /Shows/{id}/Episodes because episodes outside a season folder
    /// belong to a virtual season that a ParentId query misses.
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] {
        let parent: JFItem = try await client.get("Items/\(itemRef.itemID)")
        let result: JFQueryResult
        switch parent.type {
        case "Series":
            result = try await client.get("Shows/\(itemRef.itemID)/Seasons", [Self.listFields])
            // Specials after the last season (#534).
            return SeasonOrder.specialsLast(map(result.items), seasonNumber: \.seasonNumber)
        case "Season":
            guard let seriesID = parent.seriesId else { return [] }
            result = try await client.get("Shows/\(seriesID)/Episodes", [
                URLQueryItem(name: "seasonId", value: itemRef.itemID), Self.listFields
            ])
        default:
            result = try await client.get("Items", [
                URLQueryItem(name: "parentId", value: itemRef.itemID), Self.listFields
            ])
        }
        return map(result.items)
    }

    func search(_ query: String) async throws -> [MediaItem] {
        try await search(query, parentID: nil)
    }

    /// Search limited to the given libraries (Settings > Sidebar Libraries
    /// hides the rest). One request per library, run together, results
    /// concatenated in `parentIDs` order.
    func search(_ query: String, inLibraries parentIDs: [String]) async throws -> [MediaItem] {
        try await withThrowingTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, parentID) in parentIDs.enumerated() {
                group.addTask { (index, try await self.search(query, parentID: parentID)) }
            }
            var byIndex: [Int: [MediaItem]] = [:]
            for try await (index, items) in group { byIndex[index] = items }
            return parentIDs.indices.flatMap { byIndex[$0] ?? [] }
        }
    }

    private func search(_ query: String, parentID: String?) async throws -> [MediaItem] {
        var params = [
            URLQueryItem(name: "searchTerm", value: query),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series,Episode,MusicVideo"),
            URLQueryItem(name: "limit", value: "50"),
            Self.listFields
        ]
        if let parentID { params.append(URLQueryItem(name: "parentId", value: parentID)) }
        let result: JFQueryResult = try await client.get("Items", params)
        return map(result.items)
    }

    /// Similar items. Jellyfin collections (BoxSets) are not looked up yet,
    /// so there is never a collection row.
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        let result: JFQueryResult = try await client.get("Items/\(ref.itemID)/Similar", [
            URLQueryItem(name: "limit", value: "20"), Self.listFields
        ])
        return RelatedContent(items: map(result.items), collection: nil)
    }

    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] {
        let result: JFQueryResult = try await client.get("Shows/\(showRef.itemID)/Episodes", [Self.listFields])
        // The flat rail follows the pills: the Specials episodes come last (#534).
        return SeasonOrder.specialsLast(map(result.items), seasonNumber: \.seasonNumber)
    }

    // MARK: - Detail

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        let dto: JFItem = try await client.get("Items/\(itemRef.itemID)")
        async let trailers = extras(itemRef.itemID, "LocalTrailers", count: dto.localTrailerCount)
        async let features = extras(itemRef.itemID, "SpecialFeatures", count: dto.specialFeatureCount)
        var next: JFItem?
        if dto.type == "Series" {
            let up: JFQueryResult? = try? await client.get("Shows/NextUp", [
                URLQueryItem(name: "seriesId", value: itemRef.itemID),
                URLQueryItem(name: "limit", value: "1"),
                Self.listFields
            ])
            next = up?.items?.first
        }
        return JellyfinMediaMapper.detail(dto, nextEpisode: next, trailers: await trailers,
                                          specialFeatures: await features,
                                          providerID: id, baseURL: baseURL, token: token)
    }

    /// Local trailers or special features; asked only when the item counts some.
    private func extras(_ itemID: String, _ endpoint: String, count: Int?) async -> [JFItem] {
        guard (count ?? 0) > 0 else { return [] }
        return (try? await client.get("Items/\(itemID)/\(endpoint)")) ?? []
    }

    // MARK: - Home rails

    /// Plex's Continue Watching is one row: in-progress items plus the next
    /// episode of shows being watched. Jellyfin splits that into Resume and
    /// Next Up, so this asks both, Resume first.
    /// Resume then Next Up, with what the cross-server merge needs: a movie's ids,
    /// and for a never-played next episode its show's last watch as its date.
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        async let resumed = resumeItems(parentID: nil, limit: limit, fields: Self.continueWatchingFields)
        async let upNext = nextUpEpisodes(parentID: nil, limit: limit, fields: Self.continueWatchingFields)
        async let lastWatched = lastWatchedBySeries()
        let dtos = Array((try await resumed + (await upNext)).prefix(limit))
        let showDates = await lastWatched
        return zip(dtos, map(dtos)).map { dto, mapped in
            var item = mapped
            if item.kind == .movie {
                item.identity = ContinueWatchingMerge.providerIDKeys(dto.providerIds ?? [:], scope: "m")
            }
            if item.userState.lastViewedAt == nil, let series = dto.seriesId {
                item.userState.lastViewedAt = showDates[series]
            }
            return item
        }
    }

    private static let continueWatchingFields = URLQueryItem(
        name: "fields", value: "Overview,RecursiveItemCount,SortName,ParentId,MediaSourceCount,ProviderIds,Genres"
    )

    /// Each show's latest played episode date. A series' own UserData carries
    /// none (measured on 12.1), so this reads the recently played episodes.
    private func lastWatchedBySeries() async -> [String: Date] {
        let result: JFQueryResult? = try? await client.get("Items", [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Episode"),
            URLQueryItem(name: "filters", value: "IsPlayed"),
            URLQueryItem(name: "sortBy", value: "DatePlayed"),
            URLQueryItem(name: "sortOrder", value: "Descending"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "fields", value: "SeriesId"),
            URLQueryItem(name: "enableImages", value: "false")
        ])
        var dates: [String: Date] = [:]
        for episode in result?.items ?? [] {
            guard let series = episode.seriesId, dates[series] == nil,
                  let played = episode.userData?.lastPlayedDate.flatMap(JellyfinMediaMapper.parseDate) else { continue }
            dates[series] = played
        }
        return dates
    }

    func showIdentityKeys(for showIDs: [String]) async -> [String: [String]] {
        guard !showIDs.isEmpty else { return [:] }
        let result: JFQueryResult? = try? await client.get("Items", [
            URLQueryItem(name: "ids", value: showIDs.joined(separator: ",")),
            URLQueryItem(name: "fields", value: "ProviderIds"),
            URLQueryItem(name: "enableImages", value: "false")
        ])
        return Dictionary((result?.items ?? []).compactMap { show in
            show.id.map { ($0, ContinueWatchingMerge.providerIDKeys(show.providerIds ?? [:], scope: "s")) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private func resumeItems(parentID: String?, limit: Int, fields: URLQueryItem = listFields) async throws -> [JFItem] {
        var query = [URLQueryItem(name: "limit", value: "\(limit)"),
                     URLQueryItem(name: "mediaTypes", value: "Video"),
                     fields]
        if let parentID { query.append(URLQueryItem(name: "parentId", value: parentID)) }
        let result: JFQueryResult = try await client.get("UserItems/Resume", query)
        return result.items ?? []
    }

    /// `enableResumable=false` keeps a half-watched episode, already in
    /// Resume, out of Next Up (measured on 12.1). A failure costs only these.
    private func nextUpEpisodes(parentID: String?, limit: Int, fields: URLQueryItem = listFields) async -> [JFItem] {
        var query = [URLQueryItem(name: "limit", value: "\(limit)"),
                     URLQueryItem(name: "enableResumable", value: "false"),
                     fields]
        if let parentID { query.append(URLQueryItem(name: "parentId", value: parentID)) }
        let result: JFQueryResult? = try? await client.get("Shows/NextUp", query)
        return result?.items ?? []
    }

    private func latestItems(in library: MediaLibrary, limit: Int) async throws -> [JFItem] {
        var query = [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "fields", value: "Overview,RecursiveItemCount,SortName,ParentId,DateCreated,DateLastContentAdded,MediaSourceCount,Genres,ProviderIds")
        ]
        // A "Home Videos and Photos" library also answers with photos, which
        // nothing here can open. Leaf types: the server groups episodes itself.
        if library.kind == .mixed {
            query.append(URLQueryItem(name: "includeItemTypes", value: Self.mixedLatestTypes))
        }
        return try await client.get("Items/Latest", query)
    }

    private static let mixedLatestTypes = "Movie,Episode,Video,MusicVideo"

    /// Asked per library: across every library at once, a 12.1 server returns
    /// only the newest grouped series and drops the movies. Jellyfin's own
    /// clients ask per library too. Merged newest first; a series sorts by its
    /// newest episode, not by when the series itself was added.
    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        let videoLibraries = try await libraries().filter { [.movies, .shows, .mixed].contains($0.kind) }
        var latest: [JFItem] = []
        for library in videoLibraries {
            latest += try await latestItems(in: library, limit: limit)
        }
        let newestFirst = latest.sorted { Self.addedDate($0) > Self.addedDate($1) }
        return map(Array(newestFirst.prefix(limit)))
    }

    private static func addedDate(_ item: JFItem) -> Date {
        (item.dateLastContentAdded ?? item.dateCreated).flatMap { JellyfinMediaMapper.parseDate($0) } ?? .distantPast
    }

    /// Jellyfin has no curated hubs. HomeComposer synthesizes rails from
    /// continueWatching + recentlyAdded.
    func hubs() async throws -> [MediaHub] { [] }
    /// The library page's rows, as Plex's library hubs give them: Continue
    /// Watching (Resume, then Next Up for shows) and Recently Added, each
    /// scoped to the library and present only when it has something.
    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        async let resumed = resumeItems(parentID: library.id, limit: 24)
        async let upNext = nextUpEpisodes(parentID: library.id, limit: 24)
        async let latest = latestItems(in: library, limit: 24)
        let continuing = Array((try await resumed + (await upNext)).prefix(24))
        let added = try await latest
        var hubs: [MediaHub] = []
        if !continuing.isEmpty {
            hubs.append(MediaHub(id: "\(library.id).continueWatching", providerID: id,
                                 title: String(localized: "Continue Watching"), style: .shelf, items: map(continuing)))
        }
        if let recent = recentlyAddedHub(library, added) { hubs.append(recent) }
        return hubs
    }

    var accountID: String? { userID }

    /// One request, where `hubs(in:)` makes three.
    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        recentlyAddedHub(library, try await latestItems(in: library, limit: 24))
    }

    private func recentlyAddedHub(_ library: MediaLibrary, _ added: [JFItem]) -> MediaHub? {
        added.isEmpty ? nil : MediaHub(id: "\(library.id).recentlyAdded", providerID: id,
                                       title: String(localized: "Recently Added in \(library.title)"), style: .shelf, items: map(added),
                                       pagingKey: recentlyAddedKey(library))
    }

    /// The library listing newest first as a relative request, the items `Latest` returns: a TV
    /// library's are episodes (measured on 12.1), a mixed one's are the leaf types.
    private func recentlyAddedKey(_ library: MediaLibrary) -> String? {
        var components = URLComponents()
        components.path = "Items"
        components.queryItems = libraryQuery(
            library, sort: .addedAtDesc,
            itemTypes: library.kind == .mixed ? Self.mixedLatestTypes : library.kind == .shows ? "Episode" : nil)
        return components.string
    }

    var supportsFavorites: Bool { true }

    /// The library's favorites by name, the order of Jellyfin's own Favorites tab.
    func favorites(in library: MediaLibrary, limit: Int) async throws -> [MediaItem] {
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: Self.itemTypes(for: library.kind)),
            URLQueryItem(name: "filters", value: "IsFavorite"),
            URLQueryItem(name: "sortBy", value: "SortName"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            Self.listFields
        ])
        return map(result.items)
    }

    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        if favorite {
            try await client.post("UserFavoriteItems/\(ref.itemID)")
        } else {
            try await client.delete("UserFavoriteItems/\(ref.itemID)")
        }
    }

    /// Two requests: the library's TMDB ids, then the matches. 12.1 ignores
    /// `anyProviderIdEquals` (measured: every title comes back), so the ids are listed.
    func trending(in library: MediaLibrary, from trending: [TMDBListItem], limit: Int) async throws -> [MediaItem] {
        let index: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "fields", value: "ProviderIds"),
            URLQueryItem(name: "enableImages", value: "false"),
            URLQueryItem(name: "enableUserData", value: "false")
        ])
        var owned: [String: String] = [:]
        for dto in index.items ?? [] {
            guard let itemID = dto.id, let tmdb = dto.providerIds?["Tmdb"] else { continue }
            owned[TrendingMatch.key(tmdbID: tmdb, type: dto.type == "Series" ? .tv : .movie)] = itemID
        }
        let ids = TrendingMatch.ownedIDs(trending, owned: owned, limit: limit)
        guard !ids.isEmpty else { return [] }
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")), Self.listFields
        ])
        let byID = Dictionary(map(result.items).map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// The matches are one `Items?ids=` request. Finding them needs every movie and show on the server with its
    /// provider ids (12.1 ignores `anyProviderIdEquals`, as `trending` found), so that listing is kept for
    /// ten minutes and shared by concurrent calls.
    func ownedItems(matching titles: [TitleMatch], limit: Int) async throws -> [MediaItem] {
        let owned = try await ownedIndex()
        let ids = TitleMatch.orderedIDs(titles, among: owned.map { (id: $0.id, kind: $0.kind, ids: $0.ids) }, limit: limit)
        guard !ids.isEmpty else { return [] }
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")), Self.listFields
        ])
        let byID = Dictionary(map(result.items).map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    private struct OwnedEntry: Sendable {
        let id: String
        let kind: MediaKind
        let ids: [String: String]
    }

    private struct OwnedIndex {
        var entries: [OwnedEntry] = []
        var listedAt: Date?
        var running: Task<[OwnedEntry], Error>?
    }

    private static let ownedIndexLifetime: TimeInterval = 600
    private let ownedIndexState = OSAllocatedUnfairLock(initialState: OwnedIndex())

    // ponytail: the whole catalog's ids in memory; page the listing if a server's catalog makes this heavy.
    private func ownedIndex() async throws -> [OwnedEntry] {
        enum Step { case ready([OwnedEntry]), wait(Task<[OwnedEntry], Error>) }
        let step = ownedIndexState.withLock { state -> Step in
            if let listedAt = state.listedAt, now().timeIntervalSince(listedAt) < Self.ownedIndexLifetime {
                return .ready(state.entries)
            }
            if let running = state.running { return .wait(running) }
            let task = Task { [self] in
                do {
                    let entries = try await listOwned()
                    ownedIndexState.withLock { state in
                        state.entries = entries
                        state.listedAt = now()
                        state.running = nil
                    }
                    return entries
                } catch {
                    ownedIndexState.withLock { $0.running = nil }
                    throw error
                }
            }
            state.running = task
            return .wait(task)
        }
        switch step {
        case .ready(let entries): return entries
        case .wait(let task): return try await task.value
        }
    }

    private func listOwned() async throws -> [OwnedEntry] {
        let index: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "fields", value: "ProviderIds"),
            URLQueryItem(name: "enableImages", value: "false"),
            URLQueryItem(name: "enableUserData", value: "false")
        ])
        return (index.items ?? []).compactMap { dto in
            dto.id.map { OwnedEntry(id: $0, kind: JellyfinMediaMapper.kind(dto.type), ids: JellyfinMediaMapper.externalIDs(dto.providerIds)) }
        }
    }

    /// This server's image resized to fill the box (measured on 12.1: a cover that never upscales).
    func imageURL(_ url: URL, width: Int, height: Int) -> URL {
        guard url.host == baseURL.host, url.port == baseURL.port, url.path.contains("/Images/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let sizing: Set<String> = ["fillWidth", "fillHeight", "maxWidth", "maxHeight", "width", "height"]
        components.queryItems = (components.queryItems ?? []).filter { !sizing.contains($0.name) } + [
            URLQueryItem(name: "fillWidth", value: "\(width)"), URLQueryItem(name: "fillHeight", value: "\(height)")
        ]
        return components.url ?? url
    }

    /// Box sets with a member in this library (measured: `parentId` on a
    /// movie library returns them).
    func collections(in library: MediaLibrary) async throws -> [MediaItem] {
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "BoxSet"),
            URLQueryItem(name: "sortBy", value: "SortName"),
            Self.listFields
        ])
        return map(result.items)
    }

    /// Counts per first letter of SortName, the order the title sorts use
    /// (measured: `nameStartsWith` and `nameLessThan` compare SortName,
    /// case-insensitively, so "The Island" counts under I). "#" is everything
    /// sorting before "A". 27 count-only requests, issued together.
    // ponytail: a title whose sort name starts past Z (an accented letter)
    // is in the grid but no letter jumps to it; Plex's own index does the same.
    func letterCounts(in library: MediaLibrary) async throws -> [PlexFirstCharacter] {
        let base = [URLQueryItem(name: "parentId", value: library.id),
                    URLQueryItem(name: "recursive", value: "true"),
                    URLQueryItem(name: "includeItemTypes", value: Self.itemTypes(for: library.kind)),
                    URLQueryItem(name: "limit", value: "0"),
                    URLQueryItem(name: "enableTotalRecordCount", value: "true")]
        let buckets = [("#", URLQueryItem(name: "nameLessThan", value: "A"))]
            + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { (String($0), URLQueryItem(name: "nameStartsWith", value: String($0))) }
        let client = self.client
        return try await withThrowingTaskGroup(of: (Int, PlexFirstCharacter).self) { group in
            for (index, bucket) in buckets.enumerated() {
                group.addTask {
                    let result: JFQueryResult = try await client.get("Items", base + [bucket.1])
                    return (index, PlexFirstCharacter(title: bucket.0, size: result.totalRecordCount ?? 0))
                }
            }
            var counts: [(Int, PlexFirstCharacter)] = []
            for try await count in group { counts.append(count) }
            return counts.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Needs an administrator account (the route requires elevation); a
    /// non-admin gets 403, surfaced as `.unauthorized`.
    func refreshMetadata(_ itemRef: MediaItemRef) async throws {
        try await client.post("Items/\(itemRef.itemID)/Refresh", query: [
            URLQueryItem(name: "metadataRefreshMode", value: "FullRefresh"),
            URLQueryItem(name: "imageRefreshMode", value: "FullRefresh"),
            URLQueryItem(name: "replaceAllMetadata", value: "false"),
            URLQueryItem(name: "replaceAllImages", value: "false")
        ])
    }

    // MARK: - Playback

    /// An old or plugin-less server has no segments route: that is just empty.
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras {
        let result: JFMediaSegments? = try? await client.get("MediaSegments/\(itemRef.itemID)")
        let kinds: [String: PlaybackMarker.Kind] = ["Intro": .intro, "Outro": .credits, "Recap": .recap,
                                                    "Commercial": .commercial, "Preview": .preview]
        let markers = (result?.items ?? []).compactMap { seg -> PlaybackMarker? in
            guard let kind = seg.type.flatMap({ kinds[$0] }),
                  let start = JellyfinTicks.seconds(seg.startTicks),
                  let end = JellyfinTicks.seconds(seg.endTicks) else { return nil }
            return PlaybackMarker(kind: kind, start: start, end: end)
        }
        return PlaybackExtras(markers: markers)
    }

    /// Trickplay sheets at the width nearest the 320 pt scrub still; nil when the version has none.
    func scrubPreviews(for itemRef: MediaItemRef, sourceID: String?) async -> (any ScrubPreviewSource)? {
        let item: JFTrickplayItem? = try? await client.get("Items/\(itemRef.itemID)",
                                                           [URLQueryItem(name: "fields", value: "Trickplay")])
        guard let widths = item?.widths(forSource: sourceID),
              let info = JFTrickplayInfo.choose(from: widths, near: 320) else { return nil }
        let client = client
        let itemID = itemRef.itemID
        let query = sourceID.map { [URLQueryItem(name: "mediaSourceId", value: $0)] } ?? []
        return JellyfinTrickplayPreviews(info: info) { index in
            await client.bytes("Videos/\(itemID)/Trickplay/\(info.width)/\(index).jpg", query)
        }
    }

    /// Direct play when the server allows it, else the server's HLS transcode.
    /// A source with neither throws `.transcodeRequired`.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        try await resolveStream(for: itemRef, sourceID: sourceID, maxBitrate: maxBitrate, startTime: 0)
    }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?,
                       startTime: TimeInterval) async throws -> StreamInfo {
        try await playbackInfo(itemRef, sourceID: sourceID, allowDirectPlay: true, startTime: startTime, maxBitrate: maxBitrate)
    }

    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval,
                         maxBitrate: Int?, audioStreamIndex: Int?, subtitleStreamIndex: Int?) async throws -> StreamInfo {
        try await playbackInfo(itemRef, sourceID: sourceID, allowDirectPlay: false, startTime: startTime,
                               maxBitrate: maxBitrate, audioStreamIndex: audioStreamIndex,
                               subtitleStreamIndex: subtitleStreamIndex)
    }

    private func playbackInfo(
        _ itemRef: MediaItemRef, sourceID: String?, allowDirectPlay: Bool, startTime: TimeInterval, maxBitrate: Int?,
        audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil
    ) async throws -> StreamInfo {
        let response: JFPlaybackInfoResponse = try await client.post(
            "Items/\(itemRef.itemID)/PlaybackInfo",
            body: JFPlaybackInfoRequest.playback(
                userId: userID, mediaSourceId: sourceID, allowDirectPlay: allowDirectPlay,
                startTimeTicks: startTime > 0 ? JellyfinTicks.ticks(startTime) : nil,
                maxStreamingBitrate: maxBitrate,
                audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex
            )
        )
        let sources = response.mediaSources ?? []
        let ranked = sources.map {
            JellyfinMediaMapper.mediaSource($0, itemID: itemRef.itemID, playSessionID: response.playSessionId,
                                            baseURL: baseURL, token: token)
        }
        // The cap picks a version that fits before the server decides how to play it.
        let pickedID = VersionRanking.choose(sourceID.map(VersionChoice.source) ?? .best, from: ranked,
                                             capKbps: maxBitrate.map { $0 / 1000 })?.id
        guard let chosen = sources.first(where: { ($0.id ?? itemRef.itemID) == pickedID }) else {
            throw MediaProviderError.notFound
        }
        var transcodeURL: URL?
        if !(allowDirectPlay && chosen.supportsDirectPlay == true) {
            // The path is relative and already carries ApiKey and PlaySessionId.
            guard let path = chosen.transcodingUrl,
                  let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
            else { throw MediaProviderError.transcodeRequired }
            transcodeURL = url
            if let id = response.playSessionId { transcodeSessions.withLock { _ = $0.insert(id) } }
        }
        let source = JellyfinMediaMapper.mediaSource(
            chosen, itemID: itemRef.itemID, playSessionID: response.playSessionId, baseURL: baseURL, token: token,
            transcodeURL: transcodeURL
        )
        return StreamInfo(source: source, playSessionID: response.playSessionId, trackInfoAvailable: true)
    }

    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter {
        JellyfinProgressReporter(
            client: client, itemID: itemRef.itemID, mediaSourceID: sourceID, playSessionID: playSessionID,
            isTranscode: playSessionID.map { id in transcodeSessions.withLock { $0.contains(id) } } ?? false
        )
    }

    // MARK: - Per-item track selection

    /// Jellyfin keeps no per-item track choice. It remembers the user's last
    /// pick from the stream indexes sent in playback reports.
    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {}
    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {}

    // MARK: - Watch state

    func markPlayed(_ itemRef: MediaItemRef) async throws {
        try await client.post("UserPlayedItems/\(itemRef.itemID)")
    }

    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        try await client.delete("UserPlayedItems/\(itemRef.itemID)")
    }

    /// Answered once per provider from the user's policy.
    private let deletionAllowed = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private let downloadAllowed = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Administrators and users with downloading on. The server answers 403 to a download otherwise.
    /// A failed read throws (the server is unreachable, not "no") and is not remembered.
    func canDownloadMedia() async throws -> Bool {
        if let known = downloadAllowed.withLock({ $0 }) { return known }
        let me: JFUserWithPolicy = try await client.get("Users/Me")
        let answer = me.policy?.isAdministrator == true || me.policy?.enableContentDownloading != false
        downloadAllowed.withLock { $0 = answer }
        return answer
    }

    /// The file itself: `Items/<id>/Download` takes only the Authorization header (a key in the query
    /// answers 401), has no HEAD, and honors Range. A version of its own item is downloaded by its id.
    func downloadSource(for itemRef: MediaItemRef, sourceID: String?) async throws -> DownloadSource {
        DownloadSource(url: client.url("Items/\(sourceID ?? itemRef.itemID)/Download"),
                       headers: ["Authorization": client.authorization])
    }

    func canDeleteMedia() async -> Bool {
        if let known = deletionAllowed.withLock({ $0 }) { return known }
        guard let me: JFUserWithPolicy = try? await client.get("Users/Me") else { return false }
        let answer = me.policy?.isAdministrator == true || me.policy?.enableContentDeletion == true
        deletionAllowed.withLock { $0 = answer }
        return answer
    }

    func deleteMedia(_ itemRef: MediaItemRef) async throws {
        try await client.delete("Items/\(itemRef.itemID)")
    }

    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        try await client.post(
            "UserItems/\(itemRef.itemID)/UserData",
            body: JFUserDataUpdate(playbackPositionTicks: JellyfinTicks.ticks(position))
        )
    }

    // MARK: - Watchlist (plex.tv only)

    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool { false }
    func addToWatchlist(_ ref: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: String(localized: "Jellyfin has no watchlist"))
    }
    func removeFromWatchlist(_ ref: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: String(localized: "Jellyfin has no watchlist"))
    }

    // MARK: - Helpers

    static func sortParameters(_ sort: SortOption) -> (String, String) {
        switch sort {
        case .titleAsc: ("SortName", "Ascending")
        case .titleDesc: ("SortName", "Descending")
        case .releaseDateDesc: ("PremiereDate,SortName", "Descending")
        case .addedAtDesc: ("DateCreated,SortName", "Descending")
        case .addedAtAsc: ("DateCreated,SortName", "Ascending")
        case .releaseDateAsc: ("PremiereDate,SortName", "Ascending")
        case .lastContentAddedDesc: ("DateLastContentAdded,SortName", "Descending")
        case .ratingDesc: ("CommunityRating,SortName", "Descending")
        }
    }

    static func itemTypes(for kind: MediaLibrary.LibraryKind) -> String {
        switch kind {
        case .movies: "Movie"
        case .shows: "Series"
        case .music: "MusicAlbum"
        default: "Movie,Series,Video,MusicVideo"
        }
    }
}

/// /Sessions/Playing* for one playback. The server derives resume position
/// and the played flag from these reports (past 90% it marks the item played
/// and clears the position), so they are the whole watch-state story.
struct JellyfinProgressReporter: ProgressReporter {
    let client: JellyfinClient
    let itemID: String
    let mediaSourceID: String?
    let playSessionID: String?
    let isTranscode: Bool

    private func report(_ position: TimeInterval, paused: Bool) -> JFPlaybackReport {
        JFPlaybackReport(
            itemId: itemID, mediaSourceId: mediaSourceID, playSessionId: playSessionID,
            positionTicks: JellyfinTicks.ticks(position), isPaused: paused,
            canSeek: true, playMethod: isTranscode ? "Transcode" : "DirectPlay"
        )
    }

    func start(position: TimeInterval) async {
        try? await client.post("Sessions/Playing", body: report(position, paused: false))
    }

    func progress(position: TimeInterval) async {
        try? await client.post("Sessions/Playing/Progress", body: report(position, paused: false))
    }

    func paused(at position: TimeInterval) async {
        try? await client.post("Sessions/Playing/Progress", body: report(position, paused: true))
    }

    func stopped(at position: TimeInterval) async {
        try? await client.post("Sessions/Playing/Stopped", body: report(position, paused: false))
        // Best effort: the server also reaps an idle encode on its own.
        guard isTranscode, let playSessionID else { return }
        try? await client.delete("Videos/ActiveEncodings", query: [
            URLQueryItem(name: "deviceId", value: client.deviceID),
            URLQueryItem(name: "playSessionId", value: playSessionID)
        ])
    }
}

// MARK: - Playlists (video)

extension JellyfinProvider {
    var supportsPlaylists: Bool { true }

    private static func asPlaylist(_ dto: JFItem, providerID: String, baseURL: URL) -> MediaPlaylist {
        MediaPlaylist(item: JellyfinMediaMapper.item(dto, providerID: providerID, baseURL: baseURL), isSmart: false)
    }

    func videoPlaylists() async throws -> [MediaPlaylist] {
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "userId", value: userID),
            URLQueryItem(name: "includeItemTypes", value: "Playlist"),
            URLQueryItem(name: "recursive", value: "true")
        ])
        return (result.items ?? []).filter { $0.mediaType == "Video" }
            .map { Self.asPlaylist($0, providerID: id, baseURL: client.baseURL) }
            .sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
    }

    /// Jellyfin playlists have no rules, so none is smart.
    func playlistEntries(_ playlist: MediaItemRef) async throws -> PlaylistContents {
        let size = 200
        var entries: [PlaylistEntry] = []
        while true {
            let page: JFQueryResult = try await client.get("Playlists/\(playlist.itemID)/Items", [
                URLQueryItem(name: "userId", value: userID),
                URLQueryItem(name: "startIndex", value: String(entries.count)),
                URLQueryItem(name: "limit", value: String(size)),
                Self.listFields
            ])
            let rows = page.items ?? []
            entries += rows.compactMap { dto in
                (dto.playlistItemId ?? dto.id).map {
                    PlaylistEntry(entryID: $0, item: JellyfinMediaMapper.item(dto, providerID: id, baseURL: client.baseURL))
                }
            }
            if rows.isEmpty || entries.count >= (page.totalRecordCount ?? entries.count) {
                return PlaylistContents(entries: entries, isSmart: false)
            }
        }
    }

    /// Seeds with `items` (an empty list is allowed), then reads the playlist back for its mapped row.
    func createPlaylist(title: String, seededWith items: [MediaItemRef]) async throws -> MediaPlaylist {
        let created: JFCreated = try await client.post("Playlists", body: JFCreatePlaylist(
            name: title, ids: items.map(\.itemID), userId: userID, mediaType: "Video"
        ))
        let dto: JFItem = try await client.get("Items/\(created.id)", [URLQueryItem(name: "userId", value: userID)])
        return Self.asPlaylist(dto, providerID: id, baseURL: client.baseURL)
    }

    func addToPlaylist(_ playlist: MediaItemRef, items: [MediaItemRef]) async throws {
        guard !items.isEmpty else { return }
        try await client.post("Playlists/\(playlist.itemID)/Items", query: [
            URLQueryItem(name: "ids", value: items.map(\.itemID).joined(separator: ",")),
            URLQueryItem(name: "userId", value: userID)
        ])
    }

    func removeFromPlaylist(_ playlist: MediaItemRef, entryID: String) async throws {
        try await client.delete("Playlists/\(playlist.itemID)/Items", query: [URLQueryItem(name: "entryIds", value: entryID)])
    }

    /// Jellyfin's newIndex is the final 0-based position, so `toIndex` goes through unchanged.
    func movePlaylistEntry(_ playlist: MediaItemRef, entryID: String, toIndex: Int, in entries: [PlaylistEntry]) async throws {
        try await client.post(Self.movePath(playlist: playlist.itemID, entryID: entryID, toIndex: toIndex))
    }

    nonisolated static func movePath(playlist: String, entryID: String, toIndex: Int) -> String {
        "Playlists/\(playlist)/Items/\(entryID)/Move/\(toIndex)"
    }

    func renamePlaylist(_ playlist: MediaItemRef, title: String) async throws {
        try await client.post("Playlists/\(playlist.itemID)", body: JFUpdatePlaylist(name: title))
    }

    func deletePlaylist(_ playlist: MediaItemRef) async throws {
        try await client.delete("Items/\(playlist.itemID)")
    }
}
