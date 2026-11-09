// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyProvider+Browse.swift
//  Rivulet
//
//  Libraries, listings, search, detail and the home rails. Every call is
//  user-scoped (`Users/{id}/...` or `UserId=`): the bare routes drop `UserData`,
//  and `Similar` is a 500 without it.
//

import Foundation

extension EmbyProvider {
    /// What a list asks for beyond the defaults. `UserDataPlayCount` and `UserDataLastPlayedDate`
    /// make `UserData.PlayCount` and `LastPlayedDate` real; the rest is not on lists by default.
    nonisolated static let listFieldNames = "PrimaryImageAspectRatio,ProductionYear,PremiereDate,SortName,DateCreated,"
        + "ParentId,ChildCount,RecursiveItemCount,CommunityRating,OfficialRating,Overview,"
        + "UserDataPlayCount,UserDataLastPlayedDate,Genres,ProviderIds"
    static let listFields = URLQueryItem(name: "Fields", value: listFieldNames)
    /// `ProviderIds` is absent on lists unless asked for (cross-server identity, trending); `listFields` asks for it too.
    static let identityFields = listFields
    /// Detail needs no Fields for its sources, people or chapters; these three are the extras.
    static let detailFields = URLQueryItem(name: "Fields", value: "ChildCount,RecursiveItemCount,Collections,RemoteTrailers")

    /// Ids per `Ids=` request: the request line tops out near 8 KB.
    nonisolated static let idBatch = 400

    var itemsPath: String { "Users/\(userID)/Items" }

    private func query(_ items: [URLQueryItem]) async throws -> EmbyQueryResult {
        try await client.get(itemsPath, items)
    }

    // MARK: - Libraries

    func libraries() async throws -> [MediaLibrary] {
        let result: EmbyQueryResult = try await client.get("Users/\(userID)/Views")
        var libraries: [MediaLibrary] = []
        for view in result.items ?? [] {
            var content = HomeVideosContent.videos
            if view.collectionType == "homevideos" { content = try await homeVideosContent(libraryID: view.id.value) }
            if let library = EmbyMediaMapper.library(view, providerID: id, homeVideos: content) {
                libraries.append(library)
            }
        }
        return libraries
    }

    /// One count with no items decides photo browser or video page: a "homevideos" view holding
    /// any photo is a photo library (its clips show there too). Throws on a failed probe, so the
    /// store keeps the libraries it had.
    func homeVideosContent(libraryID: String) async throws -> HomeVideosContent {
        let result = try await query([
            URLQueryItem(name: "ParentId", value: libraryID),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Photo"),
            URLQueryItem(name: "Limit", value: "0")
        ])
        return (result.totalRecordCount ?? 0) > 0 ? .photosOnly : .videos
    }

    // MARK: - Listings

    /// A movie library's `ParentId` read returns `Folder` wrappers, so every listing is
    /// recursive with explicit types. `GroupItemsIntoCollections` is never sent: it injects box sets.
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        try await items(in: library, sort: sort, filter: .none, page: page)
    }

    func items(in library: MediaLibrary, sort: SortOption, filter: LibraryFilter, page: Page) async throws -> PagedResult<MediaItem> {
        try await listing(libraryQuery(library, sort: sort, filter: filter), page: page)
    }

    /// Genres by item id (`GenreIds`) and the years present (`Years`, rows with a name only), grouped
    /// into decades. Emby has no `Items/Filters` (404 on 4.10).
    func filterOptions(in library: MediaLibrary) async throws -> LibraryFilterOptions {
        let scope = [userQuery,
                     URLQueryItem(name: "ParentId", value: library.id),
                     URLQueryItem(name: "IncludeItemTypes", value: Self.itemTypes(for: library.kind)),
                     URLQueryItem(name: "Recursive", value: "true")]
        async let genres: EmbyNamedResult = client.get("Genres", scope)
        async let years: EmbyNamedResult = client.get("Years", scope)
        return try await LibraryFilterOptions(
            genres: (genres.items ?? []).compactMap { row in
                guard let id = row.id?.value, let name = row.name, !name.isEmpty else { return nil }
                return LibraryGenre(id: id, name: name)
            },
            decades: LibraryFilterOptions.decades(fromYears: (years.items ?? []).compactMap { $0.name.flatMap(Int.init) })
        )
    }

    /// The `Items` parameters for a filter: `Filters=IsUnplayed`, `GenreIds`, and a `Years` list for the decade.
    nonisolated static func filterQuery(_ filter: LibraryFilter) -> [URLQueryItem] {
        var query: [URLQueryItem] = []
        if filter.unwatchedOnly { query.append(URLQueryItem(name: "Filters", value: "IsUnplayed")) }
        if let genre = filter.genre { query.append(URLQueryItem(name: "GenreIds", value: genre.id)) }
        if filter.decade != nil {
            query.append(URLQueryItem(name: "Years", value: filter.decadeYears.map(String.init).joined(separator: ",")))
        }
        return query
    }

    /// The query that defines a library listing, without its page.
    private func libraryQuery(_ library: MediaLibrary, sort: SortOption, filter: LibraryFilter = .none) -> [URLQueryItem] {
        let (sortBy, order) = Self.sortParameters(sort)
        let query = [
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: Self.itemTypes(for: library.kind)),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: order)
        ]
        return query + Self.filterQuery(filter)
    }

    func shuffledItems(in library: MediaLibrary, unwatchedOnly: Bool, limit: Int) async throws -> [MediaItem] {
        var query = [
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: Self.shuffleItemTypes(for: library.kind)),
            URLQueryItem(name: "SortBy", value: "Random"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            // A Virtual location is an unaired placeholder; dropped here too, as `episodes(of:)` does.
            URLQueryItem(name: "ExcludeLocationTypes", value: "Virtual"),
            Self.listFields
        ]
        if unwatchedOnly { query.append(URLQueryItem(name: "Filters", value: "IsUnplayed")) }
        return map((try await self.query(query).items ?? []).filter { $0.locationType != "Virtual" })
    }

    /// What a shuffle plays: a TV library's episodes rather than its series. A mixed library holds episodes too.
    nonisolated static func shuffleItemTypes(for kind: MediaLibrary.LibraryKind) -> String {
        switch kind {
        case .movies: "Movie"
        case .shows: "Episode"
        default: "Movie,Video,MusicVideo,Episode"
        }
    }

    private func listing(_ query: [URLQueryItem], page: Page) async throws -> PagedResult<MediaItem> {
        let result = try await self.query(query + [
            URLQueryItem(name: "StartIndex", value: "\(page.offset)"),
            URLQueryItem(name: "Limit", value: "\(page.limit)"),
            Self.listFields
        ])
        let items = map(result.items)
        let total = result.totalRecordCount ?? items.count
        let next: Page? = (page.offset + page.limit < total)
            ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
        return PagedResult(items: items, total: total, nextPage: next)
    }

    /// A row's See All. Only Recently Added pages: its key is the library listing newest first, the order
    /// `Latest` uses (a series by its own date). A key that is not a request of this provider's is one page.
    func hubPage(_ hub: MediaHub, page: Page) async throws -> PagedResult<MediaItem> {
        guard let key = hub.pagingKey, let components = URLComponents(string: key) else {
            return PagedResult(items: page.offset == 0 ? hub.items : [], total: hub.items.count, nextPage: nil)
        }
        return try await listing(components.queryItems ?? [], page: page)
    }

    /// An unknown `SortBy` key is a 500, and one bad key in the list fails the call, so the
    /// keys come only from here. `SortName` always follows: equal keys are not tie-broken.
    /// Each key has its own order; the tiebreak is always ascending.
    nonisolated static func sortParameters(_ sort: SortOption) -> (sortBy: String, sortOrder: String) {
        switch sort {
        case .titleAsc: ("SortName", "Ascending")
        case .titleDesc: ("SortName", "Descending")
        case .releaseDateDesc: ("PremiereDate,SortName", "Descending,Ascending")
        case .releaseDateAsc: ("PremiereDate,SortName", "Ascending,Ascending")
        case .addedAtDesc: ("DateCreated,SortName", "Descending,Ascending")
        case .addedAtAsc: ("DateCreated,SortName", "Ascending,Ascending")
        case .lastContentAddedDesc: ("DateLastContentAdded,SortName", "Descending,Ascending")
        case .ratingDesc: ("CommunityRating,SortName", "Descending,Ascending")
        }
    }

    nonisolated static func itemTypes(for kind: MediaLibrary.LibraryKind) -> String {
        switch kind {
        case .movies: "Movie"
        case .shows: "Series"
        case .music: "MusicAlbum"
        default: "Movie,Series,Video"
        }
    }

    /// Show -> seasons, season -> episodes, anything else -> its direct children. The ref
    /// carries no type, so the item is read first.
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] {
        let parent: EmbyItem = try await client.get("\(itemsPath)/\(itemRef.itemID)")
        switch parent.type {
        case "Series":
            let result: EmbyQueryResult = try await client.get("Shows/\(itemRef.itemID)/Seasons", [userQuery, Self.listFields])
            return SeasonOrder.specialsLast(map(result.items), seasonNumber: \.seasonNumber)
        case "Season":
            guard let seriesID = parent.seriesId else { return [] }
            return try await episodes(of: seriesID.value, seasonID: itemRef.itemID)
        default:
            return map(try await query([URLQueryItem(name: "ParentId", value: itemRef.itemID), Self.listFields]).items)
        }
    }

    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] {
        SeasonOrder.specialsLast(try await episodes(of: showRef.itemID, seasonID: nil), seasonNumber: \.seasonNumber)
    }

    private var userQuery: URLQueryItem { URLQueryItem(name: "UserId", value: userID) }

    /// A `Virtual` location is an unaired placeholder.
    private func episodes(of seriesID: String, seasonID: String?) async throws -> [MediaItem] {
        var params = [userQuery, Self.listFields]
        if let seasonID { params.append(URLQueryItem(name: "SeasonId", value: seasonID)) }
        let result: EmbyQueryResult = try await client.get("Shows/\(seriesID)/Episodes", params)
        return map((result.items ?? []).filter { $0.locationType != "Virtual" })
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [MediaItem] {
        try await search(query, parentID: nil)
    }

    /// One request per library, run together, concatenated in `libraryIDs` order.
    func search(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaItem] {
        try await withThrowingTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, libraryID) in libraryIDs.enumerated() {
                group.addTask { (index, try await self.search(query, parentID: libraryID)) }
            }
            var byIndex: [Int: [MediaItem]] = [:]
            for try await (index, items) in group { byIndex[index] = items }
            return libraryIDs.indices.flatMap { byIndex[$0] ?? [] }
        }
    }

    /// `IncludeItemTypes` is always set: without it Genre, Tag, Person, Studio, BoxSet and
    /// artists come back too. The server matches the start of a word in the name.
    private func search(_ term: String, parentID: String?) async throws -> [MediaItem] {
        var params = [
            URLQueryItem(name: "SearchTerm", value: term),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode"),
            URLQueryItem(name: "Limit", value: "50"),
            Self.listFields
        ]
        if let parentID { params.append(URLQueryItem(name: "ParentId", value: parentID)) }
        return map(try await query(params).items)
    }

    // MARK: - Related

    /// Similar titles, and for a movie or show the other members of its first collection.
    /// The members come out of Related so no title shows twice.
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        async let similar: EmbyQueryResult = client.get("Items/\(ref.itemID)/Similar", [
            userQuery, URLQueryItem(name: "Limit", value: "20"), Self.listFields
        ])
        let box = (kind == .movie || kind == .show) ? await firstCollection(of: ref.itemID) : nil
        var related = map(try await similar.items)
        var row: CollectionRow?
        if let box {
            let members = map(box.members).filter { $0.ref.itemID != ref.itemID }
            let memberIDs = Set(members.map(\.ref.itemID))
            related.removeAll { memberIDs.contains($0.ref.itemID) }
            if !members.isEmpty { row = CollectionRow(title: box.title, members: members, collection: nil) }
        }
        return RelatedContent(items: related, collection: row)
    }

    /// `Collections` is on the detail route only when asked for. A failed lookup drops the row.
    private func firstCollection(of itemID: String) async -> (title: String, members: [EmbyItem])? {
        guard let dto: EmbyItem = try? await client.get("\(itemsPath)/\(itemID)", [URLQueryItem(name: "Fields", value: "Collections")]),
              let box = dto.collections?.first, let boxID = box.id?.value, let title = box.name,
              let members = try? await query([URLQueryItem(name: "ParentId", value: boxID), Self.listFields])
        else { return nil }
        return (title, members.items ?? [])
    }

    // MARK: - Detail

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        let dto: EmbyItem = try await client.get("\(itemsPath)/\(itemRef.itemID)", [Self.detailFields])
        async let trailers = extras(itemRef.itemID, "LocalTrailers", count: dto.localTrailerCount)
        async let features = extras(itemRef.itemID, "SpecialFeatures", count: dto.specialFeatureCount)
        var next: EmbyItem?
        var progress: ChildProgress?
        if dto.type == "Series" {
            async let seasons: EmbyQueryResult? = try? client.get("Shows/\(itemRef.itemID)/Seasons", [userQuery, Self.listFields])
            async let nextUp: EmbyQueryResult? = try? client.get("Shows/NextUp", [
                userQuery, URLQueryItem(name: "SeriesId", value: itemRef.itemID),
                URLQueryItem(name: "Limit", value: "1"), Self.listFields
            ])
            progress = EmbyMediaMapper.showProgress(seasons: await seasons?.items ?? [])
            next = await nextUp?.items?.first
        }
        return EmbyMediaMapper.detail(dto, nextEpisode: next, trailers: await trailers, specialFeatures: await features,
                                      showProgress: progress, providerID: id, baseURL: baseURL)
    }

    /// Local trailers or special features; asked only when the item counts some.
    private func extras(_ itemID: String, _ route: String, count: Int?) async -> [EmbyItem] {
        guard (count ?? 0) > 0 else { return [] }
        return (try? await client.get("\(itemsPath)/\(itemID)/\(route)")) ?? []
    }

    // MARK: - Home rails

    /// `Resume` is Emby's whole Continue Watching: one entry per show (the episode after the last
    /// one played, with its own position when it has one) plus half-watched movies. `MediaTypes=Video`
    /// is required (without it the call is empty). Next Up is not merged: the same episode comes twice.
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        async let resumed = resumeItems(parentID: nil, limit: limit)
        async let lastWatched = lastWatchedBySeries()
        let dtos = try await resumed
        let showDates = await lastWatched
        return zip(dtos, map(dtos)).map { dto, mapped in
            var item = mapped
            if item.kind == .movie {
                item.identity = ContinueWatchingMerge.providerIDKeys(dto.providerIds ?? [:], scope: "m")
            }
            if item.userState.lastViewedAt == nil, let series = dto.seriesId?.value {
                item.userState.lastViewedAt = showDates[series]
            }
            return item
        }
    }

    private func resumeItems(parentID: String?, limit: Int) async throws -> [EmbyItem] {
        var params = [URLQueryItem(name: "MediaTypes", value: "Video"),
                      URLQueryItem(name: "Limit", value: "\(limit)"),
                      Self.identityFields]
        if let parentID { params.append(URLQueryItem(name: "ParentId", value: parentID)) }
        let result: EmbyQueryResult = try await client.get("\(itemsPath)/Resume", params)
        return result.items ?? []
    }

    /// A next-up entry has no play date of its own, so it takes its show's latest watched
    /// episode, for the cross-server merge's ordering. A failure costs only that.
    private func lastWatchedBySeries() async -> [String: Date] {
        let result: EmbyQueryResult? = try? await client.get(itemsPath, [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Episode"),
            URLQueryItem(name: "Filters", value: "IsPlayed"),
            URLQueryItem(name: "SortBy", value: "DatePlayed"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: "50"),
            URLQueryItem(name: "Fields", value: "UserDataLastPlayedDate"),
            URLQueryItem(name: "EnableImages", value: "false")
        ])
        var dates: [String: Date] = [:]
        for episode in result?.items ?? [] {
            guard let series = episode.seriesId?.value, dates[series] == nil,
                  let played = EmbyJSON.date(episode.userData?.lastPlayedDate) else { continue }
            dates[series] = played
        }
        return dates
    }

    /// `Latest` is user-scoped only, answers a bare array, and mixes in music and photos
    /// without a `ParentId`, so it is asked per library.
    private func latestItems(in library: MediaLibrary, limit: Int) async throws -> [EmbyItem] {
        try await client.get("\(itemsPath)/Latest", [
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "IncludeItemTypes", value: Self.itemTypes(for: library.kind)),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            Self.listFields
        ])
    }

    /// Each video library's latest, merged newest first by `DateCreated`. A grouped series
    /// carries its own date: its newest episode's plays no part.
    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        let videoLibraries = try await libraries().filter { [.movies, .shows, .mixed].contains($0.kind) }
        var latest: [EmbyItem] = []
        for library in videoLibraries {
            latest += try await latestItems(in: library, limit: limit)
        }
        let newestFirst = latest.sorted { Self.created($0) > Self.created($1) }
        return map(Array(newestFirst.prefix(limit)))
    }

    private static func created(_ item: EmbyItem) -> Date {
        EmbyJSON.date(item.dateCreated) ?? .distantPast
    }

    /// Emby has no curated hubs. HomeComposer synthesizes rails from continueWatching + recentlyAdded.
    func hubs() async throws -> [MediaHub] { [] }

    /// The library page's rows: its Resume entries (a failure costs only that row), then Recently Added.
    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        async let resumed = try? await resumeItems(parentID: library.id, limit: 24)
        let added = try await recentlyAddedHub(in: library)
        var hubs: [MediaHub] = []
        if let resumed = await resumed, !resumed.isEmpty {
            hubs.append(MediaHub(id: "\(library.id).continueWatching", providerID: id,
                                 title: String(localized: "Continue Watching"), style: .shelf, items: map(resumed)))
        }
        if let added { hubs.append(added) }
        return hubs
    }

    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        let added = try await latestItems(in: library, limit: 24)
        return added.isEmpty ? nil : MediaHub(
            id: "\(library.id).recentlyAdded", providerID: id,
            title: String(localized: "Recently Added in \(library.title)"), style: .shelf, items: map(added),
            pagingKey: recentlyAddedKey(library)
        )
    }

    /// The library listing newest first as a relative request, items only (the path is always this user's).
    private func recentlyAddedKey(_ library: MediaLibrary) -> String? {
        var components = URLComponents()
        components.queryItems = libraryQuery(library, sort: .addedAtDesc)
        return components.string
    }

    /// The library's titles on `trending`, in its order. `AnyProviderIdEquals` takes `tmdb.<id>`
    /// pairs (key case-insensitive, a comma list is OR) and works only with `ParentId` plus
    /// `Recursive`. A movie and a show can share a number, so each hit is matched on its type
    /// again, and the server's own order is replaced by the trending one.
    func trending(in library: MediaLibrary, from trending: [TMDBListItem], limit: Int) async throws -> [MediaItem] {
        var found: [EmbyItem] = []
        let wanted = trending.map { "tmdb.\($0.id)" }
        for start in stride(from: 0, to: wanted.count, by: 200) {
            let batch = wanted[start..<min(start + 200, wanted.count)]
            found += try await query([
                URLQueryItem(name: "ParentId", value: library.id),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "AnyProviderIdEquals", value: batch.joined(separator: ",")),
                Self.identityFields
            ]).items ?? []
        }
        var owned: [String: String] = [:]
        for dto in found {
            guard let tmdb = dto.providerID("Tmdb") else { continue }
            owned[TrendingMatch.key(tmdbID: tmdb, type: dto.type == "Series" ? .tv : .movie)] = dto.id.value
        }
        let ids = TrendingMatch.ownedIDs(trending, owned: owned, limit: limit)
        let byID = Dictionary(map(found).map { ($0.ref.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Each video library asked for the titles' ids: `AnyProviderIdEquals` (`tmdb.<id>`, `imdb.<id>`, `tvdb.<id>`, a comma
    /// list is OR) works only with `ParentId` plus `Recursive`. Hits are matched on kind and id again, in title order.
    func ownedItems(matching titles: [TitleMatch], limit: Int) async throws -> [MediaItem] {
        var seen = Set<String>()
        let pairs = titles.flatMap { title in title.externalIDs.sorted { $0.key < $1.key }.map { "\($0.key).\($0.value)" } }
            .filter { seen.insert($0).inserted }
        guard !pairs.isEmpty else { return [] }
        var found: [EmbyItem] = []
        var foundIDs = Set<String>()
        for library in try await libraries() where [.movies, .shows, .mixed].contains(library.kind) {
            for start in stride(from: 0, to: pairs.count, by: 200) {
                let batch = pairs[start..<min(start + 200, pairs.count)]
                let hits = try await query([
                    URLQueryItem(name: "ParentId", value: library.id),
                    URLQueryItem(name: "Recursive", value: "true"),
                    URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                    URLQueryItem(name: "AnyProviderIdEquals", value: batch.joined(separator: ",")),
                    Self.identityFields
                ]).items ?? []
                found += hits.filter { foundIDs.insert($0.id.value).inserted }
            }
        }
        let owned = found.map { (id: $0.id.value, kind: EmbyMediaMapper.kind($0.type), ids: EmbyMediaMapper.externalIDs($0)) }
        let byID = Dictionary(map(found).map { ($0.ref.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        return TitleMatch.orderedIDs(titles, among: owned, limit: limit).compactMap { byID[$0] }
    }

    /// This server's image fitted to the box. `FillWidth` and `FillHeight` are ignored here (measured: the
    /// original comes back), so the box is `MaxWidth` by `MaxHeight`.
    func imageURL(_ url: URL, width: Int, height: Int) -> URL {
        guard url.host == baseURL.host, url.port == baseURL.port, url.path.contains("/Images/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let sizing: Set<String> = ["fillwidth", "fillheight", "maxwidth", "maxheight", "width", "height"]
        components.queryItems = (components.queryItems ?? []).filter { !sizing.contains($0.name.lowercased()) } + [
            URLQueryItem(name: "MaxWidth", value: "\(width)"), URLQueryItem(name: "MaxHeight", value: "\(height)")
        ]
        return components.url ?? url
    }

    /// Box sets with a member in this library: `ParentId` plus `Recursive` on a library lists them.
    func collections(in library: MediaLibrary) async throws -> [MediaItem] {
        map(try await query([
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "BoxSet"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            Self.listFields
        ]).items)
    }

    var supportsFavorites: Bool { true }

    /// The library's favorites by name, the order of Emby's own Favorites tab.
    func favorites(in library: MediaLibrary, limit: Int) async throws -> [MediaItem] {
        map(try await query([
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: Self.itemTypes(for: library.kind)),
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            Self.listFields
        ]).items)
    }

    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        let path = "Users/\(userID)/FavoriteItems/\(ref.itemID)"
        if favorite { try await client.post(path) } else { try await client.delete(path) }
    }

    // MARK: - A to Z

    /// `Items/Prefixes` (bare route only; the user route is a 500) lists the letters in use with
    /// no counts, so each gets one count-only request. "#" is everything before "A". Matching is
    /// on SortName with the leading article stripped, the same predicate the jump uses.
    // ponytail: a prefix past Z (an accented letter) is listed and counted but sorts after Z in the bar.
    func letterCounts(in library: MediaLibrary) async throws -> [PlexFirstCharacter] {
        let types = Self.itemTypes(for: library.kind)
        let prefixes: [EmbyPrefix] = try await client.get("Items/Prefixes", [
            userQuery,
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "IncludeItemTypes", value: types),
            URLQueryItem(name: "Recursive", value: "true")
        ])
        let names = Set(prefixes.compactMap(\.name).filter { !$0.isEmpty })
        let ordered = (names.contains("#") ? ["#"] : []) + names.subtracting(["#"]).sorted()
        let base = [URLQueryItem(name: "ParentId", value: library.id),
                    URLQueryItem(name: "Recursive", value: "true"),
                    URLQueryItem(name: "IncludeItemTypes", value: types),
                    URLQueryItem(name: "Limit", value: "0")]
        let path = itemsPath
        let client = self.client
        return try await withThrowingTaskGroup(of: (Int, PlexFirstCharacter).self) { group in
            for (index, name) in ordered.enumerated() {
                let filter = name == "#" ? URLQueryItem(name: "NameLessThan", value: "A")
                    : URLQueryItem(name: "NameStartsWith", value: name)
                group.addTask {
                    let result: EmbyQueryResult = try await client.get(path, base + [filter])
                    return (index, PlexFirstCharacter(title: name, size: result.totalRecordCount ?? 0))
                }
            }
            var counts: [(Int, PlexFirstCharacter)] = []
            for try await count in group { counts.append(count) }
            return counts.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - Cross-server identity

    /// Show ids to identity keys (`ContinueWatchingMerge`), at most 400 ids a request.
    /// `ProviderIds` keys vary in case on one server (`Imdb`, `IMDB`); the merge reads them lowercased.
    func showIdentityKeys(for showIDs: [String]) async -> [String: [String]] {
        var keys: [String: [String]] = [:]
        for start in stride(from: 0, to: showIDs.count, by: Self.idBatch) {
            let batch = showIDs[start..<min(start + Self.idBatch, showIDs.count)]
            let result: EmbyQueryResult? = try? await client.get(itemsPath, [
                URLQueryItem(name: "Ids", value: batch.joined(separator: ",")),
                URLQueryItem(name: "IncludeItemTypes", value: "Series"),
                URLQueryItem(name: "Fields", value: "ProviderIds"),
                URLQueryItem(name: "EnableImages", value: "false")
            ])
            for show in result?.items ?? [] {
                keys[show.id.value] = ContinueWatchingMerge.providerIDKeys(show.providerIds ?? [:], scope: "s")
            }
        }
        return keys
    }
}
