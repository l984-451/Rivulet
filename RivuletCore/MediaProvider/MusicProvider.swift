// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicProvider.swift
//  Rivulet
//
//  Sibling to MediaProvider for the music surface. Music-only backends
//  (Navidrome, Subsonic) and music-capable general backends (Plex,
//  Jellyfin) conform. Reuses the video-agnostic MediaItemRef, MediaLibrary,
//  Page, PagedResult, StreamInfo, MediaProviderKind, ConnectionState.
//

import Foundation

protocol MusicProvider: Sendable, Identifiable {
    var id: String { get }                       // same shape as MediaProvider: "plex:<machineID>"
    var kind: MediaProviderKind { get }
    var displayName: String { get }
    var connectionState: ConnectionState { get }

    // MARK: - Browse
    func musicLibraries() async throws -> [MediaLibrary]
    func artists(in library: MediaLibrary,
                 sort: MusicSort,
                 filter: MusicFilter,
                 page: Page) async throws -> PagedResult<MusicArtist>
    func albums(in library: MediaLibrary,
                sort: MusicSort,
                filter: MusicFilter,
                page: Page) async throws -> PagedResult<MusicAlbum>
    func tracks(in library: MediaLibrary,
                sort: MusicSort,
                filter: MusicFilter,
                page: Page) async throws -> PagedResult<MusicTrack>
    /// The genres the library's ALBUMS carry; `MusicFilter.genreID` takes their ids.
    func genres(in library: MediaLibrary) async throws -> [MusicGenre]
    func search(_ query: String) async throws -> [MusicItem]

    // MARK: - Hierarchy
    func albums(for artistRef: MediaItemRef) async throws -> [MusicAlbum]
    func tracks(for albumRef: MediaItemRef) async throws -> [MusicTrack]
    func allTracks(for artistRef: MediaItemRef) async throws -> [MusicTrack]

    // MARK: - Playlists
    func playlists(in library: MediaLibrary, sort: MusicSort) async throws -> [MusicPlaylist]
    func tracks(inPlaylist playlistRef: MediaItemRef,
                page: Page) async throws -> PagedResult<MusicTrack>
    /// Appends tracks to a regular playlist. Smart playlists reject them.
    func addToPlaylist(_ playlistRef: MediaItemRef, tracks: [MediaItemRef]) async throws
    /// A new regular audio playlist holding `tracks`.
    func createPlaylist(title: String, seededWith tracks: [MediaItemRef]) async throws -> MusicPlaylist

    // MARK: - Detail
    func artistDetail(for ref: MediaItemRef) async throws -> MusicArtistDetail
    func albumDetail(for ref: MediaItemRef) async throws -> MusicAlbumDetail
    /// Time-synced lyric lines, or nil when the backend has none for the track.
    func lyrics(for trackRef: MediaItemRef) async throws -> [MusicLyricLine]?

    // MARK: - Home rails
    func recentlyPlayed(limit: Int) async throws -> [MusicItem]

    // MARK: - Playback
    func resolveStream(for trackRef: MediaItemRef) async throws -> StreamInfo
    /// Play reports for a resolved track; nil keeps `MusicQueue`'s Plex timeline reports.
    func progressReporter(for trackRef: MediaItemRef, stream: StreamInfo) -> (any ProgressReporter)?

    // MARK: - State
    func setRating(_ rating: Double?, for ref: MediaItemRef) async throws
    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws
}
