// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinMusicProviderTests.swift
//  RivuletTests
//
//  Fixtures trimmed from a Jellyfin 12.1 server's real answers.
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinMusicProviderTests: XCTestCase {
    private let server = FakeJellyfinServer()
    private let base = JellyfinFixtures.baseURL
    private let pid = "jellyfin:srv"

    private func provider() -> JellyfinMusicProvider {
        JellyfinMusicProvider(JellyfinProvider(
            serverID: "srv", displayName: "NAS", userID: "user-1",
            client: JellyfinClient(baseURL: base, token: "tok", transport: server.transport)
        ))
    }

    private func decode<T: Decodable>(_ json: String, as type: T.Type = JFItem.self) throws -> T {
        try JellyfinJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    private func ref(_ id: String) -> MediaItemRef { MediaItemRef(providerID: pid, itemID: id) }

    // MARK: - Fixtures

    /// A list-call track (fields=SortName,MediaStreams) with no image of its own.
    private static let track = """
    {"Name":"Tokyo","Id":"712c","Container":"flac","RunTimeTicks":2197600000,"IndexNumber":1,
     "ParentIndexNumber":1,"Type":"Audio",
     "UserData":{"PlayCount":3,"IsFavorite":true,"Played":true,"Rating":8,"LastPlayedDate":"2026-10-21T12:00:00.0000000Z"},
     "Artists":["Owl City, Sekai No Owari"],"ArtistItems":[{"Name":"Owl City, Sekai No Owari","Id":"86db"}],
     "Album":"Tokyo","AlbumId":"c262","AlbumPrimaryImageTag":"879b","AlbumArtist":"Owl City",
     "AlbumArtists":[{"Name":"Owl City","Id":"1dda"}],
     "MediaStreams":[{"Codec":"flac","BitRate":999874,"Channels":2,"SampleRate":44100,"Type":"Audio","Index":0},
                     {"Codec":"mjpeg","Type":"EmbeddedImage","Index":1}],
     "ImageTags":{}}
    """

    private static let album = """
    {"Name":"Tokyo","Id":"c262","SortName":"tokyo","RunTimeTicks":2197600000,"ProductionYear":2014,
     "Type":"MusicAlbum","Genres":["Pop"],"ChildCount":1,"UserData":{"PlayCount":0,"IsFavorite":false},
     "AlbumArtist":"Owl City",
     "AlbumArtists":[{"Name":"Owl City","Id":"1dda"},{"Name":"SEKAI NO OWARI","Id":"629e"}],
     "ImageTags":{"Primary":"879b"}}
    """

    private static let artist = """
    {"Name":"Owl City","Id":"1dda","SortName":"owl city","Overview":"Adam Young's project.",
     "Genres":["pop","synth-pop"],"Type":"MusicArtist","UserData":{"IsFavorite":false},
     "ImageTags":{"Primary":"3e71","Logo":"58b9"},"BackdropImageTags":["5f4f"]}
    """

    // MARK: - Mapper

    func test_track_mapsAlbumArtistRefAndTrackArtistName() throws {
        let track = JellyfinMusicMapper.track(try decode(Self.track), providerID: pid, baseURL: base)
        XCTAssertEqual(track.ref, ref("712c"))
        XCTAssertEqual(track.albumRef, ref("c262"))
        XCTAssertEqual(track.albumTitle, "Tokyo")
        XCTAssertEqual(track.artistRef, ref("1dda"), "Go to Artist opens the album artist, as on Plex")
        XCTAssertEqual(track.artistName, "Owl City, Sekai No Owari")
        XCTAssertEqual(track.trackNumber, 1)
        XCTAssertEqual(track.discNumber, 1)
        XCTAssertEqual(track.duration, 219.76, accuracy: 0.001)
        XCTAssertEqual(track.audioCodec, "flac")
        XCTAssertEqual(track.bitrate, 999, "kbps, as Plex reports it")
        XCTAssertEqual(track.sampleRate, 44100)
        XCTAssertEqual(track.artwork.poster?.path, "/Items/c262/Images/Primary", "no image of its own: the album's")
    }

    func test_userState_ratingIsHalvedToFiveStars() throws {
        let state = JellyfinMusicMapper.userState(try decode(Self.track))
        XCTAssertTrue(state.isFavorite)
        XCTAssertEqual(state.userRating, 4)
        XCTAssertEqual(state.playCount, 3)
        XCTAssertNotNil(state.lastPlayedAt)
        XCTAssertNil(JellyfinMusicMapper.userState(try decode(Self.album)).userRating, "unrated has no Rating key")
    }

    func test_album_filesUnderFirstAlbumArtist() throws {
        let album = JellyfinMusicMapper.album(try decode(Self.album), providerID: pid, baseURL: base)
        XCTAssertEqual(album.title, "Tokyo")
        XCTAssertEqual(album.artistRef, ref("1dda"))
        XCTAssertEqual(album.artistName, "Owl City")
        XCTAssertEqual(album.year, 2014)
        XCTAssertEqual(album.trackCount, 1)
        XCTAssertEqual(album.genres, ["Pop"])
        XCTAssertEqual(album.artwork.poster?.query, "tag=879b")
    }

    func test_artist_hasPosterAndBackdrop() throws {
        let artist = JellyfinMusicMapper.artist(try decode(Self.artist), providerID: pid, baseURL: base)
        XCTAssertEqual(artist.name, "Owl City")
        XCTAssertEqual(artist.artwork.poster?.path, "/Items/1dda/Images/Primary")
        XCTAssertEqual(artist.artwork.backdrop?.path, "/Items/1dda/Images/Backdrop")
    }

    func test_playlist() throws {
        let playlist = JellyfinMusicMapper.playlist(try decode("""
        {"Name":"Rivulet Test Mix","Id":"6aa0","RunTimeTicks":2146666670,"Type":"Playlist","ChildCount":2,
         "ImageTags":{"Primary":"dc99"},"MediaType":"Audio"}
        """), providerID: pid, baseURL: base)
        XCTAssertEqual(playlist.trackCount, 2)
        XCTAssertEqual(playlist.duration, 214.666667, accuracy: 0.001)
        XCTAssertFalse(playlist.isSmart)
        XCTAssertNotNil(playlist.artworkURL)
    }

    func test_lyrics_timedLinesInSeconds_untimedIsNil() throws {
        let timed: JFLyrics = try decode("""
        {"Metadata":{},"Lyrics":[{"Text":"I saw the autumn leaves peel up off the street,","Start":156900000,"Cues":[]},
                                 {"Text":"","Start":635600000,"Cues":[]}]}
        """, as: JFLyrics.self)
        let lines = try XCTUnwrap(JellyfinMusicMapper.lyricLines(timed))
        XCTAssertEqual(lines.map(\.start), [15.69, 63.56])
        XCTAssertEqual(lines.first?.text, "I saw the autumn leaves peel up off the street,")

        let untimed: JFLyrics = try decode(#"{"Metadata":{},"Lyrics":[{"Text":"No clock"}]}"#, as: JFLyrics.self)
        XCTAssertNil(JellyfinMusicMapper.lyricLines(untimed))
    }

    // MARK: - Provider

    func test_artists_areAlbumArtistsOfTheLibrary() async throws {
        server.respond("/Artists/AlbumArtists", body: #"{"Items":[\#(Self.artist)],"TotalRecordCount":14}"#)
        let library = MediaLibrary(id: "lib", providerID: pid, title: "Music", kind: .music)
        let page = try await provider().artists(in: library, sort: .title, filter: MusicFilter(favoritesOnly: true),
                                                page: Page(offset: 0, limit: 1))
        XCTAssertEqual(page.items.map(\.name), ["Owl City"])
        XCTAssertEqual(page.total, 14)
        XCTAssertEqual(page.nextPage?.offset, 1)
        let query = server.query(0)
        XCTAssertTrue(query.contains(URLQueryItem(name: "parentId", value: "lib")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "filters", value: "IsFavorite")))
    }

    func test_sortItems_oneOrderPerKey() {
        XCTAssertEqual(JellyfinMusicProvider.sortItems(.year, type: .album), [
            URLQueryItem(name: "sortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending,Ascending")
        ])
        XCTAssertEqual(JellyfinMusicProvider.sortItems(.random, type: .track).first?.value, "Random")
    }

    func test_resolveStream_directPlay_isTheStaticFile() async throws {
        server.respond("/Items/t1/PlaybackInfo", body: """
        {"PlaySessionId":"ps","MediaSources":[{"Id":"t1","Container":"flac","SupportsDirectPlay":true}]}
        """)
        let stream = try await provider().resolveStream(for: ref("t1"))
        XCTAssertEqual(stream.source.streamKind, .directPlay)
        XCTAssertEqual(stream.source.streamURL?.path, "/Videos/t1/stream")
        XCTAssertTrue(stream.source.streamURL?.query?.contains("static=true") == true)
        XCTAssertNil(stream.normalizationGainDB, "no item answer, no gain")
        // The item read runs beside PlaybackInfo, so either may be recorded first.
        let info = try XCTUnwrap(server.requests.firstIndex { $0.url?.path.hasSuffix("PlaybackInfo") == true })
        let profile = server.jsonBody(info)["DeviceProfile"] as? [String: Any]
        let direct = (profile?["DirectPlayProfiles"] as? [[String: Any]])?.first
        XCTAssertEqual(direct?["Type"] as? String, "Audio")
        XCTAssertTrue((direct?["Container"] as? String)?.contains("flac") == true)
    }

    func test_resolveStream_carriesTheItemsNormalizationGain() async throws {
        server.respond("/Items/t3/PlaybackInfo", body: """
        {"PlaySessionId":"ps","MediaSources":[{"Id":"t3","Container":"flac","SupportsDirectPlay":true}]}
        """)
        server.respond("/Items/t3", body: #"{"Id":"t3","Type":"Audio","NormalizationGain":-7.35}"#)
        let stream = try await provider().resolveStream(for: ref("t3"))
        XCTAssertEqual(stream.normalizationGainDB, -7.35)
    }

    func test_resolveStream_ogg_isTheServersHLSTranscode() async throws {
        server.respond("/Items/t2/PlaybackInfo", body: """
        {"PlaySessionId":"ps","MediaSources":[{"Id":"t2","Container":"ogg","SupportsDirectPlay":false,
         "TranscodingUrl":"/audio/t2/master.m3u8?AudioCodec=aac&PlaySessionId=ps&ApiKey=tok"}]}
        """)
        let p = provider()
        let stream = try await p.resolveStream(for: ref("t2"))
        XCTAssertEqual(stream.source.streamKind, .hlsTranscode)
        XCTAssertEqual(stream.source.streamURL?.path, "/audio/t2/master.m3u8")
        let reporter = try XCTUnwrap(p.progressReporter(for: ref("t2"), stream: stream) as? JellyfinProgressReporter)
        XCTAssertTrue(reporter.isTranscode)
        XCTAssertEqual(reporter.playSessionID, "ps")
    }

    func test_lyrics_notFoundIsNoLyrics() async throws {
        server.respond("/Audio/t3/Lyrics", status: 404)
        let lines = try await provider().lyrics(for: ref("t3"))
        XCTAssertNil(lines)
    }

    func test_setRating_writesTenPointScale_nilDeletes() async throws {
        server.respond("/UserItems/t1/UserData", body: "{}")
        server.respond("/UserItems/t1/Rating", body: "{}")
        try await provider().setRating(4, for: ref("t1"))
        try await provider().setRating(nil, for: ref("t1"))
        XCTAssertEqual(server.jsonBody(0)["Rating"] as? Double, 8)
        XCTAssertEqual(server.requests[1].httpMethod, "DELETE")
    }

    func test_setFavorite_postsAndDeletes() async throws {
        server.respond("/UserFavoriteItems/t1", body: "{}")
        try await provider().setFavorite(true, for: ref("t1"))
        try await provider().setFavorite(false, for: ref("t1"))
        XCTAssertEqual(server.requests.map(\.httpMethod), ["POST", "DELETE"])
    }
}
