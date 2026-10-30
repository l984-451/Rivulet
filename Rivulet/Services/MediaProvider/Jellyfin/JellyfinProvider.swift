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

    init(serverID: String, displayName: String, userID: String, client: JellyfinClient) {
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
        name: "fields", value: "Overview,RecursiveItemCount,SortName,ParentId,MediaSourceCount"
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
        let (sortBy, order) = Self.sortParameters(sort)
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: Self.itemTypes(for: library.kind)),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortOrder", value: order),
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
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series,Episode"),
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
        return map(result.items)
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
        name: "fields", value: "Overview,RecursiveItemCount,SortName,ParentId,MediaSourceCount,ProviderIds"
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

    func itemIdentityKeys(for itemIDs: [String]) async -> [String: [String]] {
        guard !itemIDs.isEmpty else { return [:] }
        let result: JFQueryResult? = try? await client.get("Items", [
            URLQueryItem(name: "ids", value: itemIDs.joined(separator: ",")),
            URLQueryItem(name: "fields", value: "ProviderIds"),
            URLQueryItem(name: "enableImages", value: "false")
        ])
        return Dictionary((result?.items ?? []).compactMap { item in
            item.id.map { ($0, ContinueWatchingMerge.providerIDKeys(item.providerIds ?? [:], scope: item.type == "Movie" ? "m" : "s")) }
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
            URLQueryItem(name: "fields", value: "Overview,RecursiveItemCount,SortName,ParentId,DateCreated,DateLastContentAdded,MediaSourceCount")
        ]
        // A "Home Videos and Photos" library also answers with photos, which
        // nothing here can open. Leaf types: the server groups episodes itself.
        if library.kind == .mixed {
            query.append(URLQueryItem(name: "includeItemTypes", value: "Movie,Episode,Video"))
        }
        return try await client.get("Items/Latest", query)
    }

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
                                 title: "Continue Watching", style: .shelf, items: map(continuing)))
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
                                       title: "Recently Added in \(library.title)", style: .shelf, items: map(added))
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

    /// Direct play when the server allows it, else the server's HLS transcode.
    /// A source with neither throws `.transcodeRequired`.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        try await playbackInfo(itemRef, sourceID: sourceID, allowDirectPlay: true, startTime: 0, maxBitrate: maxBitrate)
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
        throw MediaProviderError.backendSpecific(underlying: "Jellyfin has no watchlist")
    }
    func removeFromWatchlist(_ ref: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "Jellyfin has no watchlist")
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
        default: "Movie,Series,Video"
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

    func playlistEntries(_ playlist: MediaItemRef) async throws -> [PlaylistEntry] {
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
            if rows.isEmpty || entries.count >= (page.totalRecordCount ?? entries.count) { return entries }
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
