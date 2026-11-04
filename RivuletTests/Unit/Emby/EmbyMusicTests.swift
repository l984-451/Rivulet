// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyMusicTests.swift
//  RivuletTests
//
//  EmbyMusicProvider against FakeEmbyServer: request shapes, mapping, the stream URL forms and
//  lyrics. Replies are trimmed 4.10.2 captures (EmbyMusicFixtures).
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyMusicTests: XCTestCase {
    private let server = FakeEmbyServer()
    private let uid = EmbyLiveFixtures.userID
    private let pid = "emby:srv"
    private typealias Fixtures = EmbyMusicFixtures
    private let base = EmbyBrowseFixtures.baseURL
    private let library = MediaLibrary(id: "7", providerID: "emby:srv", title: "Music", kind: .music)
    private let page = Page(offset: 0, limit: 50)

    private func videoProvider() -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: uid, policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: base, token: "tok", transport: server.transport))
    }

    private func provider() -> EmbyMusicProvider { EmbyMusicProvider(videoProvider()) }
    private func ref(_ id: String) -> MediaItemRef { MediaItemRef(providerID: pid, itemID: id) }

    private func decode(_ json: String) throws -> [EmbyItem] { try EmbyTestJSON.items(json) }

    private func query(_ request: URLRequest) -> [String: String] {
        let pairs = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    override func tearDown() async throws {
        XCTAssertEqual(server.headerProblems, [])
        try await super.tearDown()
    }

    // MARK: - Mapper

    func test_albumArtists_decodeWithIntegerGenreIds() throws {
        let artists = try decode(Fixtures.albumArtistsWithUser).map { EmbyMusicMapper.artist($0, providerID: pid, baseURL: base) }
        XCTAssertEqual(artists.map(\.name), ["Adam Young", "Adele", "Sample Radio Drama"])
        XCTAssertEqual(artists[0].genres, ["Electronic", "Synthpop", "Films"])
        XCTAssertEqual(artists[1].ref, ref("1531"))
    }

    func test_albums_decodeWithIntegerGenreIds_andFileUnderTheFirstAlbumArtist() throws {
        let albums = try decode(Fixtures.albums).map { EmbyMusicMapper.album($0, providerID: pid, baseURL: base) }
        XCTAssertEqual(albums.map(\.title), ["21", "Aladdin"])
        XCTAssertEqual(albums[0].artistRef, ref("1531"))
        XCTAssertEqual(albums[0].artistName, "Adele")
        XCTAssertEqual(albums[0].year, 2011)
        XCTAssertEqual(albums[0].trackCount, 1)
        XCTAssertEqual(albums[1].trackCount, 21)
        XCTAssertEqual(albums[0].totalDuration ?? 0, 241.73715, accuracy: 0.0001)
        XCTAssertEqual(albums[0].genres, ["Soul"])
    }

    /// The server answers a different artist set without `UserId`, and with none of the user's data.
    func test_userData_isOnlyPresentWithUserId() throws {
        let with = try decode(Fixtures.albumArtistsWithUser)
        let without = try decode(Fixtures.albumArtistsWithoutUser)
        XCTAssertTrue(with.allSatisfy { $0.userData != nil })
        XCTAssertTrue(without.allSatisfy { $0.userData == nil })
        XCTAssertEqual(EmbyMusicMapper.userState(without[0]), .empty)
        XCTAssertFalse(EmbyMusicMapper.userState(with[0]).isFavorite)
    }

    func test_userState_hasNoRatingAndReadsPlays() throws {
        let item = try EmbyTestJSON.decode(#"{"Id":"1","Name":"T","Type":"Audio","UserData":{"PlayCount":3,"IsFavorite":true,"Played":true,"LastPlayedDate":"2026-11-03T10:00:00.0000000Z"}}"#) as EmbyItem
        let state = EmbyMusicMapper.userState(item)
        XCTAssertTrue(state.isFavorite)
        XCTAssertNil(state.userRating)
        XCTAssertEqual(state.playCount, 3)
        XCTAssertNotNil(state.lastPlayedAt)
    }

    func test_track_artistRefIsTheAlbumArtist_nameIsTheTracks() throws {
        let track = EmbyMusicMapper.track(try XCTUnwrap(decode(Fixtures.trackWithStreams).first), providerID: pid, baseURL: base)
        XCTAssertEqual(track.ref, ref("1076"))
        XCTAssertEqual(track.albumRef, ref("1532"))
        XCTAssertEqual(track.albumTitle, "21")
        XCTAssertEqual(track.artistRef, ref("1531"))
        XCTAssertEqual(track.artistName, "Adele")
        XCTAssertEqual(track.trackNumber, 5)
        XCTAssertEqual(track.discNumber, 1)
        XCTAssertEqual(track.duration, 241.73715, accuracy: 0.0001)
        XCTAssertEqual(track.audioCodec, "mp3")
        XCTAssertEqual(track.bitrate, 320, "kbps, as Plex reports it")
        XCTAssertEqual(track.sampleRate, 44100)
    }

    /// A list does not ask for streams (50 tracks are 28 KB without and 190 KB with), so no codec.
    func test_trackList_hasNoStreams_andRequestsNone() async throws {
        server.respond("/Users/\(uid)/Items", body: Fixtures.trackList)
        let tracks = try await provider().tracks(for: ref("1532"))
        XCTAssertEqual(tracks.map(\.title), ["Set Fire to the Rain"])
        XCTAssertNil(tracks[0].audioCodec)
        XCTAssertNil(tracks[0].bitrate)
        XCTAssertEqual(tracks[0].albumRef, ref("1532"))
        let sent = query(server.requests[0])
        XCTAssertEqual(sent["ParentId"], "1532")
        XCTAssertEqual(sent["IncludeItemTypes"], "Audio")
        XCTAssertEqual(sent["SortBy"], "ParentIndexNumber,IndexNumber,SortName")
        XCTAssertFalse(sent["Fields"]?.contains("MediaStreams") ?? true)
    }

    // MARK: - Artwork

    func test_artwork_isRequestedOnlyWhenTheServerNamesAnImage() throws {
        let album = EmbyMusicMapper.album(try XCTUnwrap(decode(Fixtures.albums).first), providerID: pid, baseURL: base)
        XCTAssertNil(album.artwork.poster, "empty ImageTags and no pointer: no request, it would be a 404")
        let track = EmbyMusicMapper.track(try XCTUnwrap(decode(Fixtures.trackWithStreams).first), providerID: pid, baseURL: base)
        XCTAssertNil(track.artwork.poster, "a track's image route is a 500")
        let artist = EmbyMusicMapper.artist(try XCTUnwrap(decode(Fixtures.albumArtistsWithUser).first), providerID: pid, baseURL: base)
        XCTAssertNil(artist.artwork.poster)
        XCTAssertNil(artist.artwork.backdrop)
    }

    func test_artwork_followsThePrimaryImagePointer() throws {
        let folder = try XCTUnwrap(decode(Fixtures.folderWithCover).first)
        let artist = EmbyMusicMapper.artist(folder, providerID: pid, baseURL: base)
        XCTAssertEqual(artist.artwork.poster?.path, "/Items/1078/Images/Primary")
        XCTAssertEqual(artist.artwork.poster?.query, "Tag=90a549da93d63f788714163f18c23f4b_637516808800000000")
        XCTAssertFalse(artist.artwork.poster?.query?.contains("api_key") ?? true, "images are anonymous")
    }

    func test_artwork_prefersTheItemsOwnImage_thenTheAlbumsForATrack() throws {
        let own = try EmbyTestJSON.decode(#"{"Id":"5","Name":"A","Type":"MusicAlbum","ImageTags":{"Primary":"t5"},"PrimaryImageItemId":"9","PrimaryImageTag":"t9"}"#) as EmbyItem
        XCTAssertEqual(EmbyMusicMapper.album(own, providerID: pid, baseURL: base).artwork.poster?.path, "/Items/5/Images/Primary")
        let track = try EmbyTestJSON.decode(#"{"Id":"6","Name":"T","Type":"Audio","AlbumId":"5","AlbumPrimaryImageTag":"t5","ImageTags":{}}"#) as EmbyItem
        XCTAssertEqual(EmbyMusicMapper.track(track, providerID: pid, baseURL: base).artwork.poster?.path, "/Items/5/Images/Primary")
    }

    // MARK: - Browse requests

    func test_artists_areAlbumArtistsOfTheLibrary_withUserId() async throws {
        server.respond("/Artists/AlbumArtists", body: Fixtures.albumArtistsWithUser)
        let result = try await provider().artists(in: library, sort: .title, filter: MusicFilter(genreID: "1533", favoritesOnly: true),
                                                  page: Page(offset: 0, limit: 3))
        XCTAssertEqual(result.items.map(\.name), ["Adam Young", "Adele", "Sample Radio Drama"])
        XCTAssertEqual(result.total, 11)
        XCTAssertEqual(result.nextPage?.offset, 3)
        let sent = query(server.requests[0])
        XCTAssertEqual(sent["UserId"], uid, "without it the route returns every credit string (94) and no UserData")
        XCTAssertEqual(sent["ParentId"], "7")
        XCTAssertEqual(sent["SortBy"], "SortName")
        XCTAssertEqual(sent["GenreIds"], "1533")
        XCTAssertEqual(sent["Filters"], "IsFavorite")
        XCTAssertEqual(sent["StartIndex"], "0")
        XCTAssertEqual(server.requests("GET", "/Users/\(uid)/Items").count, 0)
    }

    func test_albums_andTracks_askForTheirTypeUnderTheLibrary() async throws {
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "MusicAlbum"], body: Fixtures.albums)
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "Audio"], body: Fixtures.trackList)
        let albums = try await provider().albums(in: library, sort: .year, filter: MusicFilter(), page: page)
        XCTAssertEqual(albums.items.count, 2)
        let tracks = try await provider().tracks(in: library, sort: .album, filter: MusicFilter(), page: page)
        XCTAssertEqual(tracks.items.count, 1)
        let sent = query(server.requests[0])
        XCTAssertEqual([sent["ParentId"], sent["Recursive"]], ["7", "true"])
        XCTAssertEqual(sent["SortBy"], "ProductionYear,SortName")
        XCTAssertEqual(sent["SortOrder"], "Descending,Ascending")
        XCTAssertEqual(sent["Fields"], "SortName,Genres,ChildCount,ProductionYear", "neither is on an album by default")
    }

    func test_sortItems_oneOrderPerKey() {
        func pair(_ sort: MusicSort, _ type: EmbyMusicProvider.ListType) -> [String] {
            EmbyMusicProvider.sortItems(sort, type: type).map { $0.value ?? "" }
        }
        XCTAssertEqual(pair(.title, .album), ["SortName", "Ascending"])
        XCTAssertEqual(pair(.artist, .album), ["AlbumArtist,SortName", "Ascending,Ascending"])
        XCTAssertEqual(pair(.year, .album), ["ProductionYear,SortName", "Descending,Ascending"])
        XCTAssertEqual(pair(.year, .track)[1].split(separator: ",").count, 5)
        XCTAssertEqual(pair(.album, .track)[0], "Album,ParentIndexNumber,IndexNumber,SortName")
        XCTAssertEqual(pair(.recentlyAdded, .album), ["DateCreated,SortName", "Descending,Ascending"])
        XCTAssertEqual(pair(.random, .track)[0], "Random")
        for sort in [MusicSort.title, .artist, .year, .album, .recentlyAdded, .albumRecentlyAdded, .artistRecentlyAdded, .random] {
            for type in [EmbyMusicProvider.ListType.artist, .album, .track] {
                let items = EmbyMusicProvider.sortItems(sort, type: type)
                XCTAssertEqual(items[0].value?.split(separator: ",").count, items[1].value?.split(separator: ",").count,
                               "\(sort) \(type): one order per key")
            }
        }
    }

    func test_genres_areTheGlobalMusicGenres() async throws {
        server.respond("/MusicGenres", body: Fixtures.genres)
        let genres = try await provider().genres(in: library)
        XCTAssertEqual(genres.map(\.title), ["Synthpop", "Electronic", "Pop"])
        XCTAssertEqual(genres.map(\.id), ["1495", "1499", "1518"])
        XCTAssertEqual(query(server.requests[0])["UserId"], uid)
        XCTAssertNil(query(server.requests[0])["IncludeItemTypes"], "ignored by the server")
    }

    func test_search_isNameOnlyOverThreeTypes() async throws {
        server.respond("/Users/\(uid)/Items", body: Fixtures.artistSearch)
        let found = try await provider().search("adele")
        XCTAssertEqual(found.count, 2)
        guard case .artist(let artist) = found[0] else { return XCTFail("an artist") }
        XCTAssertEqual(artist.name, "Adele")
        let sent = query(server.requests[0])
        XCTAssertEqual(sent["SearchTerm"], "adele")
        XCTAssertEqual(sent["IncludeItemTypes"], "MusicArtist,MusicAlbum,Audio")
        XCTAssertEqual(sent["Limit"], "50")
    }

    // MARK: - Hierarchy

    /// `ArtistIds` would add every album an artist is merely credited on (a featured one answers 1, not 0).
    func test_artistChildren_useAlbumArtistIds() async throws {
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "MusicAlbum"], body: Fixtures.albums)
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "Audio"], body: Fixtures.trackList)
        let albums = try await provider().albums(for: ref("1531"))
        XCTAssertEqual(albums.map(\.title), ["21", "Aladdin"])
        _ = try await provider().allTracks(for: ref("1531"))
        for request in server.requests {
            let sent = query(request)
            XCTAssertEqual(sent["AlbumArtistIds"], "1531")
            XCTAssertNil(sent["ArtistIds"])
            XCTAssertEqual(sent["Recursive"], "true")
        }
        XCTAssertEqual(query(server.requests[0])["SortOrder"], "Descending,Ascending")
        XCTAssertEqual(query(server.requests[1])["SortBy"], "Album,ParentIndexNumber,IndexNumber,SortName")
    }

    func test_details_readTheSingleItemRoute() async throws {
        server.respond("/Users/\(uid)/Items/1531", body: Fixtures.artistDetail)
        server.respond("/Users/\(uid)/Items/1532", body: Fixtures.albumDetail)
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "MusicAlbum"], body: Fixtures.albums)
        server.respond("/Users/\(uid)/Items", query: ["IncludeItemTypes": "Audio"], body: Fixtures.trackList)
        let artist = try await provider().artistDetail(for: ref("1531"))
        XCTAssertEqual(artist.artist.name, "Adele")
        XCTAssertEqual(artist.genres, ["Soul"])
        XCTAssertEqual(artist.albums.count, 2)
        let album = try await provider().albumDetail(for: ref("1532"))
        XCTAssertEqual(album.album.title, "21")
        XCTAssertEqual(album.album.year, 2011)
        XCTAssertEqual(album.tracks.count, 1)
    }

    func test_musicLibraries_areTheMusicViews() async throws {
        server.respond("/Users/\(uid)/Views", body: EmbyBrowseFixtures.views)
        let libraries = try await provider().musicLibraries()
        XCTAssertEqual(libraries.map(\.title), ["Music"])
        XCTAssertEqual(libraries.first?.kind, .music)
    }

    // MARK: - Playlists

    func test_playlists_areTheAudioPlaylistsOfTheLibrary() async throws {
        server.respond("/Users/\(uid)/Items", body: Fixtures.playlists)
        let lists = try await provider().playlists(in: library, sort: .recentlyAdded)
        XCTAssertEqual(lists.map(\.title), ["zz-media-extras-a", "zz-media-extras-c"])
        XCTAssertEqual(lists.map(\.trackCount), [2, 1])
        XCTAssertTrue(lists.allSatisfy { !$0.isSmart && $0.artworkURL == nil })
        let sent = query(server.requests[0])
        XCTAssertEqual([sent["ParentId"], sent["IncludeItemTypes"], sent["SortBy"]], ["7", "Playlist", "DateCreated,SortName"])
    }

    func test_playlistTracks_pageThePlaylistRoute() async throws {
        server.respond("/Playlists/1803/Items", body: Fixtures.trackList.replacingOccurrences(of: #""TotalRecordCount":1"#, with: #""TotalRecordCount":9"#))
        let result = try await provider().tracks(inPlaylist: ref("1803"), page: Page(offset: 0, limit: 1))
        XCTAssertEqual(result.total, 9)
        XCTAssertEqual(result.nextPage?.offset, 1)
        let sent = query(server.requests[0])
        XCTAssertEqual([sent["UserId"], sent["StartIndex"], sent["Limit"]], [uid, "0", "1"])
    }

    func test_createPlaylist_isAQueryStringPostForAudio_andReadsTheItemBack() async throws {
        server.respond("/Playlists", method: "POST", body: Fixtures.playlistCreated)
        server.respond("/Users/\(uid)/Items/1803", body: EmbyTestJSON.item(Fixtures.playlists))
        let made = try await provider().createPlaylist(title: "Mix", seededWith: [ref("1076"), ref("1077")])
        XCTAssertEqual(made.ref, ref("1803"))
        let post = try XCTUnwrap(server.requests("POST", "/Playlists").first)
        let sent = query(post)
        XCTAssertEqual([sent["Name"], sent["MediaType"], sent["Ids"], sent["UserId"]], ["Mix", "Audio", "1076,1077", uid])
        XCTAssertNil(post.httpBody, "a JSON array of ids is a 500")
    }

    func test_addToPlaylist_sendsCommaIdsInTheQuery() async throws {
        server.respond("/Playlists/1803/Items", method: "POST", body: #"{"Id":"1803","ItemAddedCount":2}"#)
        try await provider().addToPlaylist(ref("1803"), tracks: [ref("1076"), ref("1091")])
        try await provider().addToPlaylist(ref("1803"), tracks: [])
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(query(server.requests[0])["Ids"], "1076,1091")
    }

    // MARK: - Lyrics

    func test_lyrics_sidecarLrcIsTimed() async throws {
        server.respond("/Users/\(uid)/Items/1059", body: Fixtures.sidecarLyricsTrack)
        server.respond("/Videos/1059/mediasource_1059/Subtitles/2/Stream.srt", body: Fixtures.timedSRT, contentType: "text/plain")
        let result = try await provider().lyrics(for: ref("1059"))
        let lines = try XCTUnwrap(result)
        XCTAssertEqual(lines.map(\.start), [1.76, 6.17, 12.58])
        XCTAssertEqual(lines.first?.text, "Where was I when the rockets came to life")
        XCTAssertTrue(server.requests.allSatisfy { !$0.url!.path.contains("/Lyrics") }, "that route is a 500 that leaks the file path")
    }

    func test_lyrics_embeddedTagIsUntimed_soNil() async throws {
        server.respond("/Users/\(uid)/Items/1291", body: Fixtures.embeddedLyricsTrack)
        server.respond("/Videos/1291/mediasource_1291/Subtitles/2/Stream.srt", body: Fixtures.untimedSRT)
        let lines = try await provider().lyrics(for: ref("1291"))
        XCTAssertNil(lines)
        XCTAssertEqual(server.requests("GET", "/Videos/1291/mediasource_1291/Subtitles/2/Stream.srt").count, 1)
    }

    func test_lyrics_emptyBodyIsNil() async throws {
        server.respond("/Users/\(uid)/Items/1291", body: Fixtures.embeddedLyricsTrack)
        server.respond("/Videos/1291/mediasource_1291/Subtitles/2/Stream.srt", body: "")
        let lines = try await provider().lyrics(for: ref("1291"))
        XCTAssertNil(lines)
    }

    func test_lyrics_aTrackWithNoSubtitleStreamAsksForNothing() async throws {
        server.respond("/Users/\(uid)/Items/1076", body: EmbyTestJSON.item(Fixtures.trackWithStreams))
        let lines = try await provider().lyrics(for: ref("1076"))
        XCTAssertNil(lines)
        XCTAssertEqual(server.requests.count, 1)
    }

    func test_lyricLines_parsing() {
        XCTAssertNil(EmbyMusicMapper.lyricLines(fromSRT: ""))
        let crlf = "1\r\n00:01:02.500 --> 00:01:04,000\r\nline one\r\nline two\r\n\r\n2\r\n00:01:05,000 --> 00:01:06,000\r\nnext\r\n"
        let lines = EmbyMusicMapper.lyricLines(fromSRT: crlf)
        XCTAssertEqual(lines?.map(\.start), [62.5, 65])
        XCTAssertEqual(lines?.first?.text, "line one line two")
    }

    // MARK: - Playback

    func test_resolveStream_direct_isTheStaticFileWithItsExtension() async throws {
        server.respond("/Items/966/PlaybackInfo", method: "POST", body: Fixtures.playbackInfoFlac)
        let stream = try await provider().resolveStream(for: ref("966"))
        XCTAssertEqual(stream.source.streamKind, .directPlay)
        let url = try XCTUnwrap(stream.source.streamURL)
        XCTAssertEqual(url.path, "/Audio/966/stream.flac", "no extension is a 500")
        let sent = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(sent["static"], "true", "without it the stream is a remux that cannot seek")
        XCTAssertEqual(sent["MediaSourceId"], "mediasource_966")
        XCTAssertEqual(sent["PlaySessionId"], "c6897fbf7781464ebedf993e9dbb85a5")
        XCTAssertEqual(sent["api_key"], "tok")
        XCTAssertNil(sent["ApiKey"])
        XCTAssertEqual(stream.playSessionID, "c6897fbf7781464ebedf993e9dbb85a5")
    }

    func test_resolveStream_withNoURLInTheReply_stillBuildsTheStaticFile() async throws {
        server.respond("/Items/961/PlaybackInfo", method: "POST", body: Fixtures.playbackInfoMp3NoProfile)
        let stream = try await provider().resolveStream(for: ref("961"))
        XCTAssertEqual(stream.source.streamURL?.path, "/Audio/961/stream.mp3")
        XCTAssertTrue(stream.source.streamURL?.query?.contains("static=true") == true)
    }

    func test_resolveStream_postsAnAudioProfileWithAnAacHlsTranscode() async throws {
        server.respond("/Items/966/PlaybackInfo", method: "POST", body: Fixtures.playbackInfoFlac)
        _ = try await provider().resolveStream(for: ref("966"))
        let body = server.jsonBody(0)
        XCTAssertEqual(body["UserId"] as? String, uid)
        let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
        let direct = try XCTUnwrap((profile["DirectPlayProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(direct["Type"] as? String, "Audio")
        XCTAssertEqual(direct["Container"] as? String, "mp3,aac,m4a,flac,wav,alac")
        let transcode = try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual([transcode["Type"], transcode["Container"], transcode["Protocol"], transcode["AudioCodec"]] as? [String],
                       ["Audio", "aac", "hls", "aac"])
        XCTAssertNil(transcode["VideoCodec"])
    }

    func test_resolveStream_ogg_isTheServersAacHls() async throws {
        server.respond("/Items/1480/PlaybackInfo", method: "POST", body: Fixtures.playbackInfoOgg)
        let music = provider()
        let stream = try await music.resolveStream(for: ref("1480"))
        XCTAssertEqual(stream.source.streamKind, .hlsTranscode)
        XCTAssertEqual(stream.source.streamURL?.path, "/audio/1480/master.m3u8")
        XCTAssertTrue(stream.source.streamURL?.query?.contains("api_key=") == true, "the server's URL carries the key")
        let reporter = try XCTUnwrap(music.progressReporter(for: ref("1480"), stream: stream) as? EmbyProgressReporter)
        XCTAssertEqual(reporter.transcodeDeviceID, "rivulet-research-2", "stopped frees the encode")
        XCTAssertEqual(reporter.playSessionID, "b3f0f6389a0f466bbe64be2ec284957a")
        XCTAssertEqual(reporter.mediaSourceID, "mediasource_1480")
    }

    func test_progressReporter_directPlayHasNoEncodeToStop() async throws {
        server.respond("/Items/966/PlaybackInfo", method: "POST", body: Fixtures.playbackInfoFlac)
        let music = provider()
        let stream = try await music.resolveStream(for: ref("966"))
        let reporter = try XCTUnwrap(music.progressReporter(for: ref("966"), stream: stream) as? EmbyProgressReporter)
        XCTAssertNil(reporter.transcodeDeviceID)
        XCTAssertEqual(reporter.itemID, "966")
    }

    func test_recentlyPlayed_isPlayedTracksByDatePlayed() async throws {
        server.respond("/Users/\(uid)/Items", body: Fixtures.trackList)
        let items = try await provider().recentlyPlayed(limit: 12)
        XCTAssertEqual(items.count, 1)
        guard case .track = items[0] else { return XCTFail("a track") }
        let sent = query(server.requests[0])
        XCTAssertEqual([sent["Filters"], sent["SortBy"], sent["SortOrder"], sent["Limit"]], ["IsPlayed", "DatePlayed", "Descending", "12"])
        XCTAssertTrue(sent["Fields"]?.contains("UserDataLastPlayedDate") == true)
    }

    // MARK: - State

    func test_setFavorite_postsAndDeletesTheUsersRoute() async throws {
        server.respond("/Users/\(uid)/FavoriteItems/1076", method: "POST", body: Fixtures.favoriteReply)
        server.respond("/Users/\(uid)/FavoriteItems/1076", method: "DELETE", body: Fixtures.favoriteReply)
        try await provider().setFavorite(true, for: ref("1076"))
        try await provider().setFavorite(false, for: ref("1076"))
        XCTAssertEqual(server.requests.map(\.httpMethod), ["POST", "DELETE"])
    }

    func test_starRatings_areUnsupported() async {
        let music = provider()
        do {
            try await music.setRating(4, for: ref("1076"))
            XCTFail("a write Emby discards must not look like it worked")
        } catch {
            XCTAssertTrue(server.requests.isEmpty)
        }
    }
}
