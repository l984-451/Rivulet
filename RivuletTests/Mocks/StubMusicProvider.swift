// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
@testable import Rivulet

/// Empty MusicProvider for tests. Records favorite writes; can fail them and serve lyrics.
final class StubMusicProvider: MusicProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind
    nonisolated let displayName: String = "Stub"
    nonisolated var connectionState: ConnectionState { .connected }
    init(id: String, kind: MediaProviderKind = .plex) {
        self.id = id
        self.kind = kind
    }

    var favoriteWrites: [Bool] = []
    var failFavorite = false
    /// How long a favorite write stays in flight.
    var favoriteDelay: Duration = .zero
    var lyricLines: [MusicLyricLine]?

    private static let noArtwork = MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil)

    func musicLibraries() async throws -> [MediaLibrary] { [] }
    func artists(in library: MediaLibrary, sort: MusicSort, filter: MusicFilter, page: Page) async throws -> PagedResult<MusicArtist> {
        PagedResult(items: [], total: 0, nextPage: nil)
    }
    func albums(in library: MediaLibrary, sort: MusicSort, filter: MusicFilter, page: Page) async throws -> PagedResult<MusicAlbum> {
        PagedResult(items: [], total: 0, nextPage: nil)
    }
    func tracks(in library: MediaLibrary, sort: MusicSort, filter: MusicFilter, page: Page) async throws -> PagedResult<MusicTrack> {
        PagedResult(items: [], total: 0, nextPage: nil)
    }
    func genres(in library: MediaLibrary) async throws -> [MusicGenre] { [] }
    func search(_ query: String) async throws -> [MusicItem] { [] }
    func albums(for artistRef: MediaItemRef) async throws -> [MusicAlbum] { [] }
    func tracks(for albumRef: MediaItemRef) async throws -> [MusicTrack] { [] }
    func allTracks(for artistRef: MediaItemRef) async throws -> [MusicTrack] { [] }
    func playlists(in library: MediaLibrary, sort: MusicSort) async throws -> [MusicPlaylist] { [] }
    func tracks(inPlaylist playlistRef: MediaItemRef, page: Page) async throws -> PagedResult<MusicTrack> {
        PagedResult(items: [], total: 0, nextPage: nil)
    }
    func addToPlaylist(_ playlistRef: MediaItemRef, tracks: [MediaItemRef]) async throws {}
    func createPlaylist(title: String, seededWith tracks: [MediaItemRef]) async throws -> MusicPlaylist {
        MusicPlaylist(ref: MediaItemRef(providerID: id, itemID: title), title: title, artworkURL: nil,
                      trackCount: tracks.count, duration: 0, isSmart: false)
    }
    func artistDetail(for ref: MediaItemRef) async throws -> MusicArtistDetail {
        MusicArtistDetail(artist: MusicArtist(ref: ref, name: "", sortName: nil, artwork: Self.noArtwork,
                                              genres: [], yearRange: nil, userState: .empty),
                          bio: nil, genres: [], albums: [], similarArtists: [])
    }
    func albumDetail(for ref: MediaItemRef) async throws -> MusicAlbumDetail {
        MusicAlbumDetail(album: MusicAlbum(ref: ref, title: "", sortTitle: nil, artistRef: nil, artistName: nil,
                                           year: nil, artwork: Self.noArtwork, trackCount: nil,
                                           totalDuration: nil, genres: [], userState: .empty),
                         tracks: [], genres: [], contributors: [])
    }
    func lyrics(for trackRef: MediaItemRef) async throws -> [MusicLyricLine]? { lyricLines }
    func recentlyPlayed(limit: Int) async throws -> [MusicItem] { [] }
    func resolveStream(for trackRef: MediaItemRef) async throws -> StreamInfo {
        StreamInfo(source: MediaSource(id: "", container: nil, duration: 0, bitrate: nil, fileSize: nil,
                                       fileName: nil, videoResolution: nil, videoTracks: [], audioTracks: [],
                                       subtitleTracks: [], streamKind: .directPlay, streamURL: nil),
                   playSessionID: nil, trackInfoAvailable: false)
    }
    func progressReporter(for trackRef: MediaItemRef, stream: StreamInfo) -> (any Rivulet.ProgressReporter)? { nil }
    func setRating(_ rating: Double?, for ref: MediaItemRef) async throws {}
    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        try? await Task.sleep(for: favoriteDelay)
        if failFavorite { throw MediaProviderError.notFound }
        favoriteWrites.append(favorite)
    }
}
