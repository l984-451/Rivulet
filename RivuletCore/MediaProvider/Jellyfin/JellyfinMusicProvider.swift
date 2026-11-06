// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinMusicProvider.swift
//  Rivulet
//
//  Jellyfin music libraries behind MusicProvider. Every assumption about
//  what the server answers lives in this file. Measured on Jellyfin 12.1.
//

import Foundation

enum JellyfinMusicMapper {
    static func userState(_ dto: JFItem) -> MusicUserState {
        let data = dto.userData
        return MusicUserState(
            isFavorite: data?.isFavorite ?? false,
            // UserData.Rating is 0-10; the music layer counts five stars.
            userRating: data?.rating.map { $0 / 2 },
            playCount: data?.playCount ?? 0,
            lastPlayedAt: data?.lastPlayedDate.flatMap(JellyfinMediaMapper.parseDate)
        )
    }

    private static func ref(_ id: String?, _ providerID: String) -> MediaItemRef? {
        id.map { MediaItemRef(providerID: providerID, itemID: $0) }
    }

    private static func artwork(_ url: URL?) -> MediaArtwork {
        MediaArtwork(poster: url, backdrop: nil, thumbnail: url, logo: nil)
    }

    private static func primary(_ dto: JFItem, _ baseURL: URL) -> URL? {
        JellyfinMediaMapper.imageURL(baseURL, itemID: dto.id, type: "Primary", tag: dto.imageTags?["Primary"])
    }

    static func artist(_ dto: JFItem, providerID: String, baseURL: URL) -> MusicArtist {
        let primary = primary(dto, baseURL)
        let backdrop = JellyfinMediaMapper.imageURL(baseURL, itemID: dto.id, type: "Backdrop",
                                                    tag: dto.backdropImageTags?.first)
        return MusicArtist(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id ?? ""),
            name: dto.name ?? "",
            sortName: dto.sortName,
            artwork: MediaArtwork(poster: primary, backdrop: backdrop, thumbnail: primary, logo: nil),
            genres: dto.genres ?? [],
            yearRange: nil,
            userState: userState(dto)
        )
    }

    /// The first album artist is the one the album files under ("Tokyo" lists two).
    static func album(_ dto: JFItem, providerID: String, baseURL: URL) -> MusicAlbum {
        MusicAlbum(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id ?? ""),
            title: dto.name ?? "",
            sortTitle: dto.sortName,
            artistRef: ref(dto.albumArtists?.first?.id, providerID),
            artistName: dto.albumArtist ?? dto.albumArtists?.first?.name,
            year: dto.productionYear,
            artwork: artwork(primary(dto, baseURL)),
            trackCount: dto.childCount,
            totalDuration: JellyfinTicks.seconds(dto.runTimeTicks),
            genres: dto.genres ?? [],
            userState: userState(dto)
        )
    }

    /// `artistRef` is the album artist, as on Plex; the name is the track's own
    /// artist, which differs on compilations and features.
    static func track(_ dto: JFItem, providerID: String, baseURL: URL) -> MusicTrack {
        let audio = dto.mediaStreams?.first { $0.type == "Audio" }
        let art = primary(dto, baseURL)
            ?? JellyfinMediaMapper.imageURL(baseURL, itemID: dto.albumId, type: "Primary", tag: dto.albumPrimaryImageTag)
        return MusicTrack(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id ?? ""),
            title: dto.name ?? "",
            albumRef: ref(dto.albumId, providerID),
            albumTitle: dto.album,
            artistRef: ref(dto.albumArtists?.first?.id, providerID),
            artistName: dto.artistItems?.first?.name ?? dto.albumArtist,
            trackNumber: dto.indexNumber,
            discNumber: dto.parentIndexNumber,
            duration: JellyfinTicks.seconds(dto.runTimeTicks) ?? 0,
            audioCodec: audio?.codec ?? dto.container,
            bitrate: audio?.bitRate.map { $0 / 1000 },
            sampleRate: audio?.sampleRate,
            artwork: artwork(art),
            userState: userState(dto)
        )
    }

    /// Jellyfin playlists have no rules, so none is smart.
    static func playlist(_ dto: JFItem, providerID: String, baseURL: URL) -> MusicPlaylist {
        MusicPlaylist(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id ?? ""),
            title: dto.name ?? "",
            artworkURL: primary(dto, baseURL),
            trackCount: dto.childCount ?? 0,
            duration: JellyfinTicks.seconds(dto.runTimeTicks) ?? 0,
            isSmart: false
        )
    }

    static func genre(_ dto: JFItem) -> MusicGenre? {
        guard let id = dto.id else { return nil }
        return MusicGenre(id: id, title: dto.name ?? "")
    }

    /// Timed lines only, as on Plex: nil when the lyrics are untimed or empty.
    static func lyricLines(_ lyrics: JFLyrics) -> [MusicLyricLine]? {
        let lines = (lyrics.lyrics ?? []).compactMap { line -> MusicLyricLine? in
            guard let start = JellyfinTicks.seconds(line.start) else { return nil }
            return MusicLyricLine(start: start, text: (line.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines.isEmpty ? nil : lines
    }
}

final class JellyfinMusicProvider: MusicProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .jellyfin
    nonisolated let displayName: String
    let connectionState: ConnectionState = .connected
    let userID: String
    let client: JellyfinClient

    /// Shares the video provider's id and client, so refs resolve in both registries.
    init(_ provider: JellyfinProvider) {
        id = provider.id
        displayName = provider.displayName
        userID = provider.userID
        client = provider.client
    }

    private var baseURL: URL { client.baseURL }

    private static let trackFields = URLQueryItem(name: "fields", value: "SortName,MediaStreams")
    private static let containerFields = URLQueryItem(name: "fields", value: "SortName,Genres,ChildCount")

    // MARK: - Browse

    func musicLibraries() async throws -> [MediaLibrary] {
        let result: JFQueryResult = try await client.get("UserViews")
        return (result.items ?? []).compactMap { JellyfinMediaMapper.library($0, providerID: id) }
            .filter { $0.kind == .music }
    }

    /// Album artists, as Plex lists them: `Items?includeItemTypes=MusicArtist` also
    /// returns every featured and track artist (84 against 13 on the test server).
    func artists(in library: MediaLibrary, sort: MusicSort, filter: MusicFilter,
                 page: Page) async throws -> PagedResult<MusicArtist> {
        let result: JFQueryResult = try await client.get("Artists/AlbumArtists", [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "fields", value: "SortName,Genres")
        ] + Self.sortItems(sort, type: .artist) + Self.filterItems(filter) + Self.pageItems(page))
        return paged(result, page) { JellyfinMusicMapper.artist($0, providerID: id, baseURL: baseURL) }
    }

    func albums(in library: MediaLibrary, sort: MusicSort, filter: MusicFilter,
                page: Page) async throws -> PagedResult<MusicAlbum> {
        let result = try await libraryItems(library, type: .album, sort: sort, filter: filter, page: page)
        return paged(result, page) { JellyfinMusicMapper.album($0, providerID: id, baseURL: baseURL) }
    }

    func tracks(in library: MediaLibrary, sort: MusicSort, filter: MusicFilter,
                page: Page) async throws -> PagedResult<MusicTrack> {
        let result = try await libraryItems(library, type: .track, sort: sort, filter: filter, page: page)
        return paged(result, page) { JellyfinMusicMapper.track($0, providerID: id, baseURL: baseURL) }
    }

    /// Album genres only: without `includeItemTypes` the library answers 39
    /// (artist and track tags too) against its albums' 12.
    func genres(in library: MediaLibrary) async throws -> [MusicGenre] {
        let result: JFQueryResult = try await client.get("Genres", [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "sortBy", value: "SortName")
        ])
        return (result.items ?? []).compactMap(JellyfinMusicMapper.genre)
    }

    func search(_ query: String) async throws -> [MusicItem] {
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "searchTerm", value: query),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "MusicArtist,MusicAlbum,Audio"),
            URLQueryItem(name: "limit", value: "50"),
            Self.trackFields
        ])
        return (result.items ?? []).compactMap { dto in
            switch dto.type {
            case "MusicArtist": .artist(JellyfinMusicMapper.artist(dto, providerID: id, baseURL: baseURL))
            case "MusicAlbum": .album(JellyfinMusicMapper.album(dto, providerID: id, baseURL: baseURL))
            case "Audio": .track(JellyfinMusicMapper.track(dto, providerID: id, baseURL: baseURL))
            default: nil
            }
        }
    }

    // MARK: - Hierarchy

    /// Newest first. Artist ids are server-wide, so no library is needed.
    func albums(for artistRef: MediaItemRef) async throws -> [MusicAlbum] {
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "albumArtistIds", value: artistRef.itemID),
            URLQueryItem(name: "sortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending,Ascending"),
            Self.containerFields
        ])
        return (result.items ?? []).map { JellyfinMusicMapper.album($0, providerID: id, baseURL: baseURL) }
    }

    func tracks(for albumRef: MediaItemRef) async throws -> [MusicTrack] {
        try await trackList([URLQueryItem(name: "parentId", value: albumRef.itemID)],
                            sortBy: "ParentIndexNumber,IndexNumber,SortName")
    }

    func allTracks(for artistRef: MediaItemRef) async throws -> [MusicTrack] {
        try await trackList([URLQueryItem(name: "albumArtistIds", value: artistRef.itemID)],
                            sortBy: "Album,ParentIndexNumber,IndexNumber,SortName")
    }

    private func trackList(_ scope: [URLQueryItem], sortBy: String) async throws -> [MusicTrack] {
        let result: JFQueryResult = try await client.get("Items", scope + [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "sortBy", value: sortBy),
            Self.trackFields
        ])
        return (result.items ?? []).map { JellyfinMusicMapper.track($0, providerID: id, baseURL: baseURL) }
    }

    // MARK: - Playlists

    /// `parentId` on a music library returns only audio playlists (a video
    /// playlist does not come back), so it scopes as Plex's section does.
    func playlists(in library: MediaLibrary, sort: MusicSort) async throws -> [MusicPlaylist] {
        let order = sort == .recentlyAdded ? ("DateCreated,SortName", "Descending,Ascending") : ("SortName", "Ascending")
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Playlist"),
            URLQueryItem(name: "sortBy", value: order.0),
            URLQueryItem(name: "sortOrder", value: order.1),
            URLQueryItem(name: "fields", value: "ChildCount")
        ])
        return (result.items ?? []).map { JellyfinMusicMapper.playlist($0, providerID: id, baseURL: baseURL) }
    }

    func tracks(inPlaylist playlistRef: MediaItemRef, page: Page) async throws -> PagedResult<MusicTrack> {
        let result: JFQueryResult = try await client.get("Playlists/\(playlistRef.itemID)/Items",
                                                         Self.pageItems(page) + [Self.trackFields])
        return paged(result, page) { JellyfinMusicMapper.track($0, providerID: id, baseURL: baseURL) }
    }

    /// The server keeps duplicates, as Plex does.
    func addToPlaylist(_ playlistRef: MediaItemRef, tracks: [MediaItemRef]) async throws {
        guard !tracks.isEmpty else { return }
        try await client.post("Playlists/\(playlistRef.itemID)/Items", query: [
            URLQueryItem(name: "ids", value: tracks.map(\.itemID).joined(separator: ",")),
            URLQueryItem(name: "userId", value: userID)
        ])
    }

    func createPlaylist(title: String, seededWith tracks: [MediaItemRef]) async throws -> MusicPlaylist {
        let created: JFCreated = try await client.post("Playlists", body: JFCreatePlaylist(
            name: title, ids: tracks.map(\.itemID), userId: userID, mediaType: "Audio"
        ))
        let dto: JFItem = try await client.get("Items/\(created.id)", [URLQueryItem(name: "userId", value: userID)])
        return JellyfinMusicMapper.playlist(dto, providerID: id, baseURL: baseURL)
    }

    // MARK: - Detail

    func artistDetail(for ref: MediaItemRef) async throws -> MusicArtistDetail {
        async let dto: JFItem = client.get("Items/\(ref.itemID)")
        async let albums = albums(for: ref)
        let artist = try await dto
        return MusicArtistDetail(
            artist: JellyfinMusicMapper.artist(artist, providerID: id, baseURL: baseURL),
            bio: artist.overview, genres: artist.genres ?? [], albums: try await albums, similarArtists: []
        )
    }

    func albumDetail(for ref: MediaItemRef) async throws -> MusicAlbumDetail {
        async let dto: JFItem = client.get("Items/\(ref.itemID)")
        async let tracks = tracks(for: ref)
        let album = try await dto
        return MusicAlbumDetail(
            album: JellyfinMusicMapper.album(album, providerID: id, baseURL: baseURL),
            tracks: try await tracks, genres: album.genres ?? [], contributors: []
        )
    }

    /// 404 is a track with no lyrics.
    func lyrics(for trackRef: MediaItemRef) async throws -> [MusicLyricLine]? {
        do {
            let lyrics: JFLyrics = try await client.get("Audio/\(trackRef.itemID)/Lyrics")
            return JellyfinMusicMapper.lyricLines(lyrics)
        } catch MediaProviderError.notFound {
            return nil
        }
    }

    // MARK: - Home rails

    func recentlyPlayed(limit: Int) async throws -> [MusicItem] { [] }

    // MARK: - Playback

    /// What AVPlayer plays direct; anything else (ogg, opus, wma) comes back as
    /// the server's AAC HLS transcode.
    func resolveStream(for trackRef: MediaItemRef) async throws -> StreamInfo {
        let response: JFPlaybackInfoResponse = try await client.post(
            "Items/\(trackRef.itemID)/PlaybackInfo", body: JFPlaybackInfoRequest.audio(userId: userID)
        )
        guard let source = response.mediaSources?.first else { throw MediaProviderError.notFound }
        var transcodeURL: URL?
        if source.supportsDirectPlay != true {
            guard let path = source.transcodingUrl,
                  let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
            else { throw MediaProviderError.transcodeRequired }
            transcodeURL = url
        }
        let media = JellyfinMediaMapper.mediaSource(
            source, itemID: trackRef.itemID, playSessionID: response.playSessionId, baseURL: baseURL,
            token: client.token ?? "", transcodeURL: transcodeURL
        )
        return StreamInfo(source: media, playSessionID: response.playSessionId, trackInfoAvailable: true)
    }

    /// The same /Sessions/Playing reports the video player sends: the server
    /// counts plays and marks a track played from them.
    func progressReporter(for trackRef: MediaItemRef, stream: StreamInfo) -> (any ProgressReporter)? {
        JellyfinProgressReporter(client: client, itemID: trackRef.itemID, mediaSourceID: stream.source.id,
                                 playSessionID: stream.playSessionID,
                                 isTranscode: stream.source.streamKind == .hlsTranscode)
    }

    // MARK: - State

    /// Stars go in UserData.Rating (0-10); clearing deletes the rating (and its like).
    func setRating(_ rating: Double?, for ref: MediaItemRef) async throws {
        guard let rating else { return try await client.delete("UserItems/\(ref.itemID)/Rating") }
        try await client.post("UserItems/\(ref.itemID)/UserData", body: JFRatingUpdate(rating: rating * 2))
    }

    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        if favorite {
            try await client.post("UserFavoriteItems/\(ref.itemID)")
        } else {
            try await client.delete("UserFavoriteItems/\(ref.itemID)")
        }
    }

    // MARK: - Helpers

    enum ListType { case artist, album, track }

    private func libraryItems(_ library: MediaLibrary, type: ListType, sort: MusicSort, filter: MusicFilter,
                              page: Page) async throws -> JFQueryResult {
        try await client.get("Items", [
            URLQueryItem(name: "parentId", value: library.id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: type == .album ? "MusicAlbum" : "Audio"),
            type == .album ? Self.containerFields : Self.trackFields
        ] + Self.sortItems(sort, type: type) + Self.filterItems(filter) + Self.pageItems(page))
    }

    private func paged<T: Sendable>(_ result: JFQueryResult, _ page: Page, _ map: (JFItem) -> T) -> PagedResult<T> {
        let items = (result.items ?? []).map(map)
        let total = result.totalRecordCount ?? items.count
        let next: Page? = page.offset + page.limit < total ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
        return PagedResult(items: items, total: total, nextPage: next)
    }

    private static func pageItems(_ page: Page) -> [URLQueryItem] {
        [URLQueryItem(name: "startIndex", value: "\(page.offset)"),
         URLQueryItem(name: "limit", value: "\(page.limit)"),
         URLQueryItem(name: "enableTotalRecordCount", value: "true")]
    }

    /// `sortOrder` takes one value per `sortBy` key (measured).
    // ponytail: Jellyfin has no album-added date on a track, so the two
    // "recently added" track sorts order by each file's own DateCreated.
    static func sortItems(_ sort: MusicSort, type: ListType) -> [URLQueryItem] {
        let trackOrder = "ParentIndexNumber,IndexNumber,SortName"
        let (by, order): (String, String) = switch (sort, type) {
        case (.random, _): ("Random", "Ascending")
        case (.recentlyAdded, _), (.albumRecentlyAdded, _), (.artistRecentlyAdded, _):
            ("DateCreated,SortName", "Descending,Ascending")
        case (.artist, .album): ("AlbumArtist,SortName", "Ascending")
        case (.artist, .track): ("AlbumArtist,Album,\(trackOrder)", "Ascending")
        case (.year, .album): ("ProductionYear,SortName", "Descending,Ascending")
        case (.year, .track): ("ProductionYear,Album,\(trackOrder)", "Descending,Ascending,Ascending,Ascending,Ascending")
        case (.album, .track): ("Album,\(trackOrder)", "Ascending")
        default: ("SortName", "Ascending")
        }
        return [URLQueryItem(name: "sortBy", value: by), URLQueryItem(name: "sortOrder", value: order)]
    }

    static func filterItems(_ filter: MusicFilter) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let genreID = filter.genreID { items.append(URLQueryItem(name: "genreIds", value: genreID)) }
        if filter.favoritesOnly { items.append(URLQueryItem(name: "filters", value: "IsFavorite")) }
        return items
    }
}
