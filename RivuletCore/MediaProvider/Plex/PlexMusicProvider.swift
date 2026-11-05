// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexMusicProvider.swift
//  Rivulet
//
//  Plex implementation of MusicProvider. Wraps PlexNetworkManager + maps
//  responses through PlexMusicMapper.
//

import Foundation

final class PlexMusicProvider: MusicProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .plex
    nonisolated let displayName: String
    private(set) var connectionState: ConnectionState = .connected

    let serverURL: String
    let authToken: String
    let networkManager: PlexNetworkManager

    init(
        machineIdentifier: String,
        displayName: String,
        serverURL: String,
        authToken: String,
        networkManager: PlexNetworkManager = .shared
    ) {
        self.id = "plex:\(machineIdentifier)"
        self.displayName = displayName
        self.serverURL = serverURL
        self.authToken = authToken
        self.networkManager = networkManager
    }

    // MARK: - Browse

    func musicLibraries() async throws -> [MediaLibrary] {
        try await plexCall {
            let all = try await networkManager.getLibraries(
                serverURL: serverURL, authToken: authToken
            )
            return all
                .filter { $0.type == "artist" }
                .map { PlexMediaMapper.library($0, providerID: id) }
        }
    }

    func artists(
        in library: MediaLibrary,
        sort: MusicSort,
        filter: MusicFilter,
        page: Page
    ) async throws -> PagedResult<MusicArtist> {
        try await sectionItems(in: library, type: 8, sort: sort, filter: filter, page: page) {
            PlexMusicMapper.artist($0, providerID: id, serverURL: serverURL, authToken: authToken)
        }
    }

    func albums(
        in library: MediaLibrary,
        sort: MusicSort,
        filter: MusicFilter,
        page: Page
    ) async throws -> PagedResult<MusicAlbum> {
        try await sectionItems(in: library, type: 9, sort: sort, filter: filter, page: page) {
            PlexMusicMapper.album($0, providerID: id, serverURL: serverURL, authToken: authToken)
        }
    }

    func tracks(
        in library: MediaLibrary,
        sort: MusicSort,
        filter: MusicFilter,
        page: Page
    ) async throws -> PagedResult<MusicTrack> {
        try await sectionItems(in: library, type: 10, sort: sort, filter: filter, page: page) {
            PlexMusicMapper.track($0, providerID: id, serverURL: serverURL, authToken: authToken)
        }
    }

    func genres(in library: MediaLibrary) async throws -> [MusicGenre] {
        try await plexCall {
            try await networkManager.getGenres(
                serverURL: serverURL, authToken: authToken, sectionId: library.id, type: 9
            ).map { MusicGenre(id: $0.key, title: $0.title) }
        }
    }

    func search(_ query: String) async throws -> [MusicItem] {
        // Parallels PlexProvider.search — routes through /hubs/search which
        // isn't typed yet.
        //
        // TODO(post-wave-1): wire Plex music search once PlexNetworkManager
        // has a typed search helper.
        throw MediaProviderError.backendSpecific(
            underlying: "Plex music search not implemented in Wave 1"
        )
    }

    // MARK: - Hierarchy

    func albums(for artistRef: MediaItemRef) async throws -> [MusicAlbum] {
        try await plexCall {
            let kids = try await networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: artistRef.itemID
            )
            return kids.compactMap { meta -> MusicAlbum? in
                guard meta.type == "album" else { return nil }
                return PlexMusicMapper.album(
                    meta, providerID: id,
                    serverURL: serverURL, authToken: authToken
                )
            }
        }
    }

    func tracks(for albumRef: MediaItemRef) async throws -> [MusicTrack] {
        try await plexCall {
            let kids = try await networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: albumRef.itemID
            )
            return kids.compactMap { meta -> MusicTrack? in
                guard meta.type == "track" else { return nil }
                return PlexMusicMapper.track(
                    meta, providerID: id,
                    serverURL: serverURL, authToken: authToken
                )
            }
        }
    }

    func allTracks(for artistRef: MediaItemRef) async throws -> [MusicTrack] {
        try await plexCall {
            let leaves = try await networkManager.getAllLeaves(
                serverURL: serverURL, authToken: authToken, ratingKey: artistRef.itemID
            )
            return leaves.map {
                PlexMusicMapper.track(
                    $0, providerID: id,
                    serverURL: serverURL, authToken: authToken
                )
            }
        }
    }

    // MARK: - Playlists

    func playlists(in library: MediaLibrary, sort: MusicSort) async throws -> [MusicPlaylist] {
        try await plexCall {
            try await networkManager.getAudioPlaylists(
                serverURL: serverURL, authToken: authToken, sectionId: library.id,
                sort: Self.sortString(sort, type: 15)
            ).map {
                PlexMusicMapper.playlist($0, providerID: id, serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func tracks(
        inPlaylist playlistRef: MediaItemRef,
        page: Page
    ) async throws -> PagedResult<MusicTrack> {
        try await plexCall {
            let result = try await networkManager.getPlaylistItemsWithTotal(
                serverURL: serverURL, authToken: authToken,
                ratingKey: playlistRef.itemID, start: page.offset, size: page.limit
            )
            let tracks = result.items.filter { $0.type == "track" }.map {
                PlexMusicMapper.track($0, providerID: id, serverURL: serverURL, authToken: authToken)
            }
            return Self.paged(tracks, total: result.totalSize, page: page)
        }
    }

    func addToPlaylist(_ playlistRef: MediaItemRef, tracks: [MediaItemRef]) async throws {
        guard !tracks.isEmpty else { return }
        try await plexCall {
            // Asked of the server: the id this provider was built with can be
            // a URL hash when the server list had not loaded yet.
            let machineID = try await networkManager.getMachineIdentifier(
                serverURL: serverURL, authToken: authToken
            )
            try await networkManager.addToPlaylist(
                serverURL: serverURL, authToken: authToken,
                playlistRatingKey: playlistRef.itemID,
                machineIdentifier: machineID,
                ratingKeys: tracks.map(\.itemID)
            )
        }
    }

    func createPlaylist(title: String, seededWith tracks: [MediaItemRef]) async throws -> MusicPlaylist {
        try await plexCall {
            let machineID = try await networkManager.getMachineIdentifier(serverURL: serverURL, authToken: authToken)
            let created = try await networkManager.createPlaylist(
                serverURL: serverURL, authToken: authToken, type: "audio", title: title,
                uri: PlexNetworkManager.libraryURI(machineIdentifier: machineID, ratingKeys: tracks.map(\.itemID))
            )
            return PlexMusicMapper.playlist(created, providerID: id, serverURL: serverURL, authToken: authToken)
        }
    }

    // MARK: - Detail

    func artistDetail(for ref: MediaItemRef) async throws -> MusicArtistDetail {
        try await plexCall {
            async let metaFetch = networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            async let childrenFetch = networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            let meta = try await metaFetch
            let albumsMeta = try await childrenFetch

            let albums = albumsMeta.filter { $0.type == "album" }
            // TODO(post-wave-1): wire /library/metadata/{id}/similar.
            return PlexMusicMapper.artistDetail(
                meta,
                albums: albums,
                similarArtists: [],
                providerID: id,
                serverURL: serverURL, authToken: authToken
            )
        }
    }

    func albumDetail(for ref: MediaItemRef) async throws -> MusicAlbumDetail {
        try await plexCall {
            async let metaFetch = networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            async let childrenFetch = networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            let meta = try await metaFetch
            let allChildren = try await childrenFetch
            let tracks = allChildren.filter { $0.type == "track" }
            return PlexMusicMapper.albumDetail(
                meta, tracks: tracks,
                providerID: id,
                serverURL: serverURL, authToken: authToken
            )
        }
    }

    func lyrics(for trackRef: MediaItemRef) async throws -> [MusicLyricLine]? {
        try await plexCall {
            // Lyric streams are listed on single-item metadata only.
            let meta = try await networkManager.getMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: trackRef.itemID
            )
            for key in PlexMusicMapper.lyricStreamKeys(meta) {
                // A LyricFind stream is often listed and then answers 404: try the next.
                if let lyrics = try? await networkManager.getLyrics(
                    serverURL: serverURL, authToken: authToken, streamKey: key
                ), let lines = PlexMusicMapper.lyricLines(lyrics) {
                    return lines
                }
            }
            return nil
        }
    }

    // MARK: - Home rails

    func recentlyPlayed(limit: Int) async throws -> [MusicItem] {
        // TODO(post-wave-1): wire music recently-played hub.
        return []
    }

    // MARK: - Playback

    func resolveStream(for trackRef: MediaItemRef) async throws -> StreamInfo {
        try await plexCall {
            let meta = try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: trackRef.itemID
            )
            let sources: [MediaSource] = (meta.Media ?? []).flatMap { media in
                (media.Part ?? []).map { part in
                    PlexMediaMapper.mediaSource(
                        media, part,
                        serverURL: serverURL, authToken: authToken
                    )
                }
            }
            guard let source = sources.first else {
                throw MediaProviderError.notFound
            }
            return StreamInfo(source: source, playSessionID: nil, trackInfoAvailable: true)
        }
    }

    func progressReporter(for trackRef: MediaItemRef, stream: StreamInfo) -> (any ProgressReporter)? { nil }

    // MARK: - State

    func setRating(_ rating: Double?, for ref: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.setRating(
                serverURL: serverURL, authToken: authToken,
                ratingKey: ref.itemID,
                rating: rating.map { Int(($0 * PlexUserRating.starScale).rounded()) }
            )
        }
    }

    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        // Plex has no favorite flag: a rating above three stars is one
        // (PlexUserRating). Unfavoriting clears the rating.
        try await setRating(favorite ? 5.0 : nil, for: ref)
    }

    // MARK: - Helpers

    /// One page of a section's artists (8), albums (9) or tracks (10).
    private func sectionItems<T: Sendable>(
        in library: MediaLibrary,
        type: Int,
        sort: MusicSort,
        filter: MusicFilter,
        page: Page,
        map: (PlexMetadata) -> T
    ) async throws -> PagedResult<T> {
        try await plexCall {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL, authToken: authToken,
                sectionId: library.id,
                start: page.offset,
                size: page.limit,
                sort: Self.sortString(sort, type: type),
                type: type,
                filters: Self.filterItems(filter, type: type)
            )
            return Self.paged(result.items.map(map), total: result.totalSize, page: page)
        }
    }

    private static func paged<T: Sendable>(_ items: [T], total: Int?, page: Page) -> PagedResult<T> {
        let total = total ?? items.count
        let next: Page? = (page.offset + page.limit < total)
            ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
        return PagedResult(items: items, total: total, nextPage: next)
    }

    /// Plex `sort` value for artists (8), albums (9), tracks (10) and playlists (15).
    /// The artist sorts are the server's own "Album Artist" keys.
    static func sortString(_ sort: MusicSort, type: Int) -> String {
        let trackOrder = "track.absoluteIndex,track.index,track.titleSort,track.id"
        switch (sort, type) {
        case (.recentlyAdded, _): return "addedAt:desc"
        case (.albumRecentlyAdded, _): return "album.addedAt:desc,album.id,\(trackOrder)"
        case (.artistRecentlyAdded, _):
            return "artist.addedAt:desc,artist.id,album.titleSort,album.year,\(trackOrder)"
        case (.random, _): return "random"
        case (.artist, 9):
            return "artist.titleSort,album.titleSort,album.index,album.id,album.originallyAvailableAt"
        case (.artist, 10):
            return "artist.titleSort,album.titleSort,album.year,\(trackOrder)"
        case (.year, 9): return "year:desc,titleSort"
        case (.year, 10): return "album.year:desc,album.titleSort,\(trackOrder)"
        case (.album, 10): return "album.titleSort,album.year,\(trackOrder)"
        default: return "titleSort:asc"
        }
    }

    /// Plex filter query items. Genre ids come from the ALBUM genre directory.
    static func filterItems(_ filter: MusicFilter, type: Int) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let genreID = filter.genreID {
            items.append(URLQueryItem(name: type == 9 ? "genre" : "album.genre", value: genreID))
        }
        if filter.favoritesOnly {
            // ">>=" is Plex's "greater than"; the threshold matches PlexUserRating.isFavorite.
            let threshold = Int(PlexUserRating.favoriteStarThreshold * PlexUserRating.starScale)
            items.append(URLQueryItem(name: "userRating>>", value: "\(threshold)"))
        }
        return items
    }
}
