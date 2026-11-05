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
        + "UserDataPlayCount,UserDataLastPlayedDate"
    static let listFields = URLQueryItem(name: "Fields", value: listFieldNames)
    /// `ProviderIds` is absent on lists unless asked for (cross-server identity, trending).
    static let identityFields = URLQueryItem(name: "Fields", value: listFieldNames + ",ProviderIds")
    /// Detail needs no Fields for its sources, people or chapters; these three are the extras.
    static let detailFields = URLQueryItem(name: "Fields", value: "ChildCount,RecursiveItemCount,Collections")

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
        let (sortBy, order) = Self.sortParameters(sort)
        let result = try await query([
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: Self.itemTypes(for: library.kind)),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: order),
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
            return map(result.items)
        case "Season":
            guard let seriesID = parent.seriesId else { return [] }
            return try await episodes(of: seriesID.value, seasonID: itemRef.itemID)
        default:
            return map(try await query([URLQueryItem(name: "ParentId", value: itemRef.itemID), Self.listFields]).items)
        }
    }

    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] {
        try await episodes(of: showRef.itemID, seasonID: nil)
    }

    private var userQuery: URLQueryItem { URLQueryItem(name: "UserId", value: userID) }

    /// Season 0 comes first from the server. A `Virtual` location is an unaired placeholder.
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

    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        try await recentlyAddedHub(in: library).map { [$0] } ?? []
    }

    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        let added = try await latestItems(in: library, limit: 24)
        return added.isEmpty ? nil : MediaHub(
            id: "\(library.id).recentlyAdded", providerID: id,
            title: String(localized: "Recently Added in \(library.title)"), style: .shelf, items: map(added)
        )
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
