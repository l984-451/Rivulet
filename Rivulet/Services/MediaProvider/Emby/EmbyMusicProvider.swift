// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyMusicProvider.swift
//  Rivulet
//
//  Emby music libraries behind MusicProvider. Every call is user-scoped: without a user the
//  artist route is unfiltered and nothing carries UserData. Measured on Emby 4.10.2.
//

import Foundation
import os

final class EmbyMusicProvider: MusicProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .emby
    nonisolated let displayName: String
    let connectionState: ConnectionState = .connected
    let provider: EmbyProvider

    /// Shares the video provider's id and client, so refs resolve in both registries.
    init(_ provider: EmbyProvider) {
        id = provider.id
        displayName = provider.displayName
        self.provider = provider
    }

    var client: EmbyClient { provider.client }
    private var userID: String { provider.userID }
    private var baseURL: URL { provider.baseURL }
    private var itemsPath: String { provider.itemsPath }
    private var userQuery: URLQueryItem { URLQueryItem(name: "UserId", value: userID) }

    /// `MediaStreams` is left off lists: 50 tracks are 28 KB without and 190 KB with. The two
    /// `UserData` fields make the play count and last-played date real (a list reports 0 otherwise).
    private static let trackFields = URLQueryItem(name: "Fields", value: "SortName,UserDataPlayCount,UserDataLastPlayedDate")
    /// `ProductionYear` and `ChildCount` are not on an album by default.
    private static let containerFields = URLQueryItem(name: "Fields", value: "SortName,Genres,ChildCount,ProductionYear")

    private func query(_ items: [URLQueryItem]) async throws -> EmbyQueryResult {
        try await client.get(itemsPath, items)
    }

    // MARK: - Browse

    func musicLibraries() async throws -> [MediaLibrary] {
        let views: EmbyQueryResult = try await client.get("Users/\(userID)/Views")
        return (views.items ?? []).compactMap { EmbyMediaMapper.library($0, providerID: id) }.filter { $0.kind == .music }
    }

    /// Album artists, as Plex lists them: the `Items` route with `MusicArtist` also returns every
    /// composer and credit string (94 against 11 on the test server). `UserId` is what filters.
    func artists(in library: MediaLibrary, sort: MusicSort, filter: MusicFilter,
                 page: Page) async throws -> PagedResult<MusicArtist> {
        let result: EmbyQueryResult = try await client.get("Artists/AlbumArtists", [
            userQuery,
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "Fields", value: "SortName,Genres")
        ] + Self.sortItems(sort, type: .artist) + Self.filterItems(filter) + Self.pageItems(page))
        return paged(result, page) { EmbyMusicMapper.artist($0, providerID: id, baseURL: baseURL) }
    }

    func albums(in library: MediaLibrary, sort: MusicSort, filter: MusicFilter,
                page: Page) async throws -> PagedResult<MusicAlbum> {
        let result = try await libraryItems(library, type: .album, sort: sort, filter: filter, page: page)
        return paged(result, page) { EmbyMusicMapper.album($0, providerID: id, baseURL: baseURL) }
    }

    func tracks(in library: MediaLibrary, sort: MusicSort, filter: MusicFilter,
                page: Page) async throws -> PagedResult<MusicTrack> {
        let result = try await libraryItems(library, type: .track, sort: sort, filter: filter, page: page)
        return paged(result, page) { EmbyMusicMapper.track($0, providerID: id, baseURL: baseURL) }
    }

    /// `MusicGenres` is global: it ignores `IncludeItemTypes` (the album-only list Jellyfin needs).
    func genres(in library: MediaLibrary) async throws -> [MusicGenre] {
        let result: EmbyQueryResult = try await client.get("MusicGenres", [
            userQuery,
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "SortBy", value: "SortName")
        ])
        return (result.items ?? []).map(EmbyMusicMapper.genre)
    }

    /// Name only: an album is not found by its artist's name.
    func search(_ text: String) async throws -> [MusicItem] {
        let result = try await query([
            URLQueryItem(name: "SearchTerm", value: text),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicArtist,MusicAlbum,Audio"),
            URLQueryItem(name: "Limit", value: "50"),
            Self.trackFields
        ])
        return (result.items ?? []).compactMap { dto in
            switch dto.type {
            case "MusicArtist": .artist(EmbyMusicMapper.artist(dto, providerID: id, baseURL: baseURL))
            case "MusicAlbum": .album(EmbyMusicMapper.album(dto, providerID: id, baseURL: baseURL))
            case "Audio": .track(EmbyMusicMapper.track(dto, providerID: id, baseURL: baseURL))
            default: nil
            }
        }
    }

    // MARK: - Hierarchy

    /// Newest first. `AlbumArtistIds` is the album artist only; `ArtistIds` would add every album
    /// the artist is credited on. Artist ids are server-wide, so no library is needed.
    func albums(for artistRef: MediaItemRef) async throws -> [MusicAlbum] {
        let result = try await query([
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "AlbumArtistIds", value: artistRef.itemID),
            URLQueryItem(name: "SortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending,Ascending"),
            Self.containerFields
        ])
        return (result.items ?? []).map { EmbyMusicMapper.album($0, providerID: id, baseURL: baseURL) }
    }

    func tracks(for albumRef: MediaItemRef) async throws -> [MusicTrack] {
        try await trackList([URLQueryItem(name: "ParentId", value: albumRef.itemID)],
                            sortBy: "ParentIndexNumber,IndexNumber,SortName")
    }

    func allTracks(for artistRef: MediaItemRef) async throws -> [MusicTrack] {
        try await trackList([URLQueryItem(name: "AlbumArtistIds", value: artistRef.itemID)],
                            sortBy: "Album,ParentIndexNumber,IndexNumber,SortName")
    }

    private func trackList(_ scope: [URLQueryItem], sortBy: String) async throws -> [MusicTrack] {
        let result = try await query(scope + [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SortBy", value: sortBy),
            Self.trackFields
        ])
        return (result.items ?? []).map { EmbyMusicMapper.track($0, providerID: id, baseURL: baseURL) }
    }

    // MARK: - Playlists

    /// `ParentId` on a music library lists only audio playlists, as Plex's section does.
    func playlists(in library: MediaLibrary, sort: MusicSort) async throws -> [MusicPlaylist] {
        let order = sort == .recentlyAdded ? ("DateCreated,SortName", "Descending,Ascending") : ("SortName", "Ascending")
        let result = try await query([
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            URLQueryItem(name: "SortBy", value: order.0),
            URLQueryItem(name: "SortOrder", value: order.1),
            URLQueryItem(name: "Fields", value: "ChildCount")
        ])
        return (result.items ?? []).map { EmbyMusicMapper.playlist($0, providerID: id, baseURL: baseURL) }
    }

    func tracks(inPlaylist playlistRef: MediaItemRef, page: Page) async throws -> PagedResult<MusicTrack> {
        let result: EmbyQueryResult = try await client.get("Playlists/\(playlistRef.itemID)/Items",
                                                          [userQuery] + Self.pageItems(page) + [Self.trackFields])
        return paged(result, page) { EmbyMusicMapper.track($0, providerID: id, baseURL: baseURL) }
    }

    /// The server keeps duplicates, as Plex does. `Ids` is a comma string in the query.
    func addToPlaylist(_ playlistRef: MediaItemRef, tracks: [MediaItemRef]) async throws {
        guard !tracks.isEmpty else { return }
        try await client.post("Playlists/\(playlistRef.itemID)/Items", query: [Self.idsQuery(tracks), userQuery])
    }

    /// The reply names only the new id, so the playlist is read back.
    func createPlaylist(title: String, seededWith tracks: [MediaItemRef]) async throws -> MusicPlaylist {
        var params = [URLQueryItem(name: "Name", value: title), URLQueryItem(name: "MediaType", value: "Audio"), userQuery]
        if !tracks.isEmpty { params.append(Self.idsQuery(tracks)) }
        let created: EmbyCreatedPlaylist = try await client.post("Playlists", query: params)
        let dto: EmbyItem = try await client.get("\(itemsPath)/\(created.id.value)",
                                                [URLQueryItem(name: "Fields", value: "ChildCount")])
        return EmbyMusicMapper.playlist(dto, providerID: id, baseURL: baseURL)
    }

    private static func idsQuery(_ refs: [MediaItemRef]) -> URLQueryItem {
        URLQueryItem(name: "Ids", value: refs.map(\.itemID).joined(separator: ","))
    }

    // MARK: - Detail

    /// The single-item route answers for virtual artists and albums too (`Ids=` does not).
    func artistDetail(for ref: MediaItemRef) async throws -> MusicArtistDetail {
        async let dto: EmbyItem = client.get("\(itemsPath)/\(ref.itemID)", [Self.containerFields])
        async let albums = albums(for: ref)
        let artist = try await dto
        return MusicArtistDetail(
            artist: EmbyMusicMapper.artist(artist, providerID: id, baseURL: baseURL),
            bio: artist.overview, genres: artist.genres ?? [], albums: try await albums, similarArtists: []
        )
    }

    func albumDetail(for ref: MediaItemRef) async throws -> MusicAlbumDetail {
        async let dto: EmbyItem = client.get("\(itemsPath)/\(ref.itemID)", [Self.containerFields])
        async let tracks = tracks(for: ref)
        let album = try await dto
        return MusicAlbumDetail(
            album: EmbyMusicMapper.album(album, providerID: id, baseURL: baseURL),
            tracks: try await tracks, genres: album.genres ?? [], contributors: []
        )
    }

    /// Emby has no lyrics route (`Audio/{id}/Lyrics` is a 500 that leaks the file path). Lyrics are
    /// a subtitle stream on the track, read as SRT; only a sidecar `.lrc` carries timing.
    func lyrics(for trackRef: MediaItemRef) async throws -> [MusicLyricLine]? {
        let track: EmbyItem = try await client.get("\(itemsPath)/\(trackRef.itemID)")
        guard let source = track.mediaSources?.first, let sourceID = source.id else { return nil }
        let owner = source.itemId?.value ?? trackRef.itemID
        for stream in EmbyMusicMapper.lyricStreams(source) {
            // A tag that holds nothing still lists a stream (114 of 141): its body is empty.
            do {
                let text = try await client.getText("Videos/\(owner)/\(sourceID)/Subtitles/\(stream.index ?? 0)/Stream.srt")
                if let lines = EmbyMusicMapper.lyricLines(fromSRT: text) { return lines }
            } catch MediaProviderError.notFound {
                continue
            }
        }
        return nil
    }

    // MARK: - Home rails

    func recentlyPlayed(limit: Int) async throws -> [MusicItem] {
        let result = try await query([
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Filters", value: "IsPlayed"),
            URLQueryItem(name: "SortBy", value: "DatePlayed"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            Self.trackFields
        ])
        return (result.items ?? []).map { .track(EmbyMusicMapper.track($0, providerID: id, baseURL: baseURL)) }
    }

    // MARK: - Playback

    /// A profile has to be posted or the reply carries no URL. The server's answer decides direct
    /// play; those containers play from the static file, anything else (ogg) from its AAC HLS
    /// transcode. `Audio/{id}/stream` with no extension or no `static=true` is a 500 or a remux
    /// that cannot seek.
    func resolveStream(for trackRef: MediaItemRef) async throws -> StreamInfo {
        let response: EmbyPlaybackInfoResponse = try await client.post(
            "Items/\(trackRef.itemID)/PlaybackInfo", body: EmbyPlaybackInfoRequest.audio(userId: userID)
        )
        guard let source = response.mediaSources?.first(where: { $0.id != nil }), let sourceID = source.id
        else { throw MediaProviderError.notFound }
        let playSession = response.playSessionId
        let url: URL
        let kind: MediaSource.StreamKind
        if source.supportsDirectPlay == true {
            let container = source.container?.split(separator: ",").first.map(String.init) ?? "mp3"
            var params = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "MediaSourceId", value: sourceID)]
            if let playSession { params.append(URLQueryItem(name: "PlaySessionId", value: playSession)) }
            url = client.authenticatedURL("Audio/\(source.itemId?.value ?? trackRef.itemID)/stream.\(container)", params)
            kind = .directPlay
        } else {
            guard let path = source.transcodingUrl, let transcode = client.resolve(path) else {
                throw MediaProviderError.transcodeRequired
            }
            if let playSession {
                let device: String
                if let found = EmbyProvider.queryValue("DeviceId", in: transcode) { device = found } else { device = await client.deviceID }
                provider.transcodeSessions.withLock { $0[playSession] = device }
            }
            url = transcode
            kind = .hlsTranscode
        }
        let media = MediaSource(
            id: sourceID, container: source.container, duration: EmbyTicks.seconds(source.runTimeTicks) ?? 0,
            bitrate: source.bitrate, fileSize: source.size, fileName: source.name, videoResolution: nil,
            videoTracks: [], audioTracks: [], subtitleTracks: [], streamKind: kind, streamURL: url
        )
        return StreamInfo(source: media, playSessionID: playSession, trackInfoAvailable: true)
    }

    /// The same `Sessions/Playing` reports the video player sends, and the same transcode map
    /// (so `stopped` ends an AAC encode too).
    func progressReporter(for trackRef: MediaItemRef, stream: StreamInfo) -> (any ProgressReporter)? {
        provider.progressReporter(for: trackRef, sourceID: stream.source.id, playSessionID: stream.playSessionID)
    }

    // MARK: - State

    /// Emby accepts a rating write and stores nothing.
    func setRating(_ rating: Double?, for ref: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "Emby stores no star rating")
    }

    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        let path = "Users/\(userID)/FavoriteItems/\(ref.itemID)"
        if favorite { try await client.post(path) } else { try await client.delete(path) }
    }

    // MARK: - Helpers

    enum ListType { case artist, album, track }

    private func libraryItems(_ library: MediaLibrary, type: ListType, sort: MusicSort, filter: MusicFilter,
                              page: Page) async throws -> EmbyQueryResult {
        try await query([
            URLQueryItem(name: "ParentId", value: library.id),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: type == .album ? "MusicAlbum" : "Audio"),
            type == .album ? Self.containerFields : Self.trackFields
        ] + Self.sortItems(sort, type: type) + Self.filterItems(filter) + Self.pageItems(page))
    }

    private func paged<T: Sendable>(_ result: EmbyQueryResult, _ page: Page, _ map: (EmbyItem) -> T) -> PagedResult<T> {
        let items = (result.items ?? []).map(map)
        let total = result.totalRecordCount ?? items.count
        let next: Page? = page.offset + page.limit < total ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
        return PagedResult(items: items, total: total, nextPage: next)
    }

    private static func pageItems(_ page: Page) -> [URLQueryItem] {
        [URLQueryItem(name: "StartIndex", value: "\(page.offset)"),
         URLQueryItem(name: "Limit", value: "\(page.limit)"),
         URLQueryItem(name: "EnableTotalRecordCount", value: "true")]
    }

    /// `SortOrder` takes one value per `SortBy` key (a lone `Descending` applies to every key),
    /// and an unknown key is a 500, so the keys come only from here.
    // ponytail: no album-added date on a track, so the "recently added" track sorts order by each
    // file's own DateCreated.
    static func sortItems(_ sort: MusicSort, type: ListType) -> [URLQueryItem] {
        let trackOrder = "ParentIndexNumber,IndexNumber,SortName"
        let (by, order): (String, String) = switch (sort, type) {
        case (.random, _): ("Random", "Ascending")
        case (.recentlyAdded, _), (.albumRecentlyAdded, _), (.artistRecentlyAdded, _):
            ("DateCreated,SortName", "Descending,Ascending")
        case (.artist, .album): ("AlbumArtist,SortName", "Ascending,Ascending")
        case (.artist, .track): ("AlbumArtist,Album,\(trackOrder)", "Ascending,Ascending,Ascending,Ascending,Ascending")
        case (.year, .album): ("ProductionYear,SortName", "Descending,Ascending")
        case (.year, .track): ("ProductionYear,Album,\(trackOrder)", "Descending,Ascending,Ascending,Ascending,Ascending")
        case (.album, .track): ("Album,\(trackOrder)", "Ascending,Ascending,Ascending,Ascending")
        default: ("SortName", "Ascending")
        }
        return [URLQueryItem(name: "SortBy", value: by), URLQueryItem(name: "SortOrder", value: order)]
    }

    /// `GenreIds` is a comma list of the ids `genres(in:)` returned.
    static func filterItems(_ filter: MusicFilter) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let genreID = filter.genreID { items.append(URLQueryItem(name: "GenreIds", value: genreID)) }
        if filter.favoritesOnly { items.append(URLQueryItem(name: "Filters", value: "IsFavorite")) }
        return items
    }
}
