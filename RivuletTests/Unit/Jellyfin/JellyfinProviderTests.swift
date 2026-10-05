// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinProviderTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinProviderTests: XCTestCase {
    private let server = FakeJellyfinServer()
    private let ref = MediaItemRef(providerID: "jellyfin:srv", itemID: "ep1")

    private func provider() -> JellyfinProvider {
        JellyfinProvider(
            serverID: "srv", displayName: "NAS", userID: "user-1",
            client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok", transport: server.transport)
        )
    }

    func test_identity() {
        let p = provider()
        XCTAssertEqual(p.id, "jellyfin:srv")
        XCTAssertEqual(p.kind, .jellyfin)
        XCTAssertFalse(p.supportsWatchlist)
    }

    // MARK: - Playback

    func test_resolveStream_noSourceID_picksTheBestVersion() async throws {
        server.respond("/Items/m1/PlaybackInfo", body: """
            {"PlaySessionId":"ps","MediaSources":[
              {"Id":"hd","Name":"1080p","SupportsDirectPlay":true,
               "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080}]},
              {"Id":"uhd","Name":"2160p","SupportsDirectPlay":true,
               "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160}]}]}
            """)
        let stream = try await provider().resolveStream(
            for: MediaItemRef(providerID: "jellyfin:srv", itemID: "m1"), sourceID: nil)
        XCTAssertEqual(stream.source.id, "uhd")
    }

    func test_resolveStream_firstSource_withSessionID() async throws {
        server.respond("/Items/ep1/PlaybackInfo", body: JellyfinFixtures.playbackInfo)
        let stream = try await provider().resolveStream(for: ref, sourceID: nil)
        XCTAssertEqual(stream.source.id, "src-4k")
        XCTAssertEqual(stream.playSessionID, "psid-1")
        XCTAssertTrue(stream.trackInfoAvailable)
        XCTAssertEqual(server.requests.first?.httpMethod, "POST")
    }

    func test_resolveStream_body_isPascalCaseDirectPlayProfile() async throws {
        server.respond("/Items/ep1/PlaybackInfo", body: JellyfinFixtures.playbackInfo)
        _ = try await provider().resolveStream(for: ref, sourceID: nil)
        let body = server.jsonBody(0)
        XCTAssertEqual(body["UserId"] as? String, "user-1")
        XCTAssertEqual(body["EnableTranscoding"] as? Bool, true)
        XCTAssertNil(body["MediaSourceId"])
        let profiles = (body["DeviceProfile"] as? [String: Any])?["DirectPlayProfiles"] as? [[String: Any]]
        XCTAssertEqual(profiles?.compactMap { $0["Type"] as? String }, ["Video", "Audio"])
    }

    /// Without subtitle profiles a selected subtitle resolves to burn-in, which
    /// rules out direct play. On a 12.1 server that blocked 3 of 9 movies, each
    /// with a default subtitle.
    func test_resolveStream_body_declaresEmbeddedAndExternalSubtitles() async throws {
        server.respond("/Items/ep1/PlaybackInfo", body: JellyfinFixtures.playbackInfo)
        _ = try await provider().resolveStream(for: ref, sourceID: nil)
        let profile = server.jsonBody(0)["DeviceProfile"] as? [String: Any]
        let subtitles = (profile?["SubtitleProfiles"] as? [[String: Any]] ?? []).map {
            "\($0["Method"] as? String ?? "?"):\($0["Format"] as? String ?? "?")"
        }
        for expected in ["Embed:subrip", "Embed:ass", "Embed:pgssub", "Embed:dvdsub",
                         "External:srt", "External:ass", "External:pgssub"] {
            XCTAssertTrue(subtitles.contains(expected), "missing \(expected) in \(subtitles)")
        }
    }

    func test_resolveStream_sourceTheServerWontDirectPlay_throwsTranscodeRequired() async {
        server.respond("/Items/ep1/PlaybackInfo", body: JellyfinFixtures.playbackInfo)
        do {
            _ = try await provider().resolveStream(for: ref, sourceID: "src-1080")
            XCTFail("expected a throw")
        } catch MediaProviderError.transcodeRequired {
        } catch { XCTFail("got \(error)") }
    }

    func test_resolveStream_noDirectPlay_returnsTheServerTranscode() async throws {
        server.respond("/Items/m1/PlaybackInfo", body: """
            {"MediaSources":[{"Id":"m1","Container":"mkv","SupportsDirectPlay":false,"SupportsTranscoding":true,
              "TranscodingUrl":"/videos/m1/master.m3u8?PlaySessionId=ps1&ApiKey=tok","MediaStreams":[]}],
             "PlaySessionId":"ps1"}
            """)
        let info = try await provider().resolveStream(for: MediaItemRef(providerID: "jellyfin:srv", itemID: "m1"), sourceID: nil)
        XCTAssertEqual(info.source.streamKind, .hlsTranscode)
        XCTAssertEqual(info.source.streamURL?.absoluteString, "\(JellyfinFixtures.baseURL.absoluteString)/videos/m1/master.m3u8?PlaySessionId=ps1&ApiKey=tok")
        let body = server.jsonBody(0)
        XCTAssertEqual(body["EnableTranscoding"] as? Bool, true)
    }

    func test_transcodeStream_neverDirectPlay_andStartsAtTheOffset() async throws {
        server.respond("/Items/m1/PlaybackInfo", body: """
            {"MediaSources":[{"Id":"m1","SupportsDirectPlay":true,"SupportsTranscoding":true,
              "TranscodingUrl":"/videos/m1/master.m3u8?ApiKey=tok","MediaStreams":[]}],"PlaySessionId":"ps2"}
            """)
        let info = try await provider().transcodeStream(for: MediaItemRef(providerID: "jellyfin:srv", itemID: "m1"),
                                                        sourceID: "m1", startTime: 90)
        XCTAssertEqual(info.source.streamKind, .hlsTranscode)
        let body = server.jsonBody(0)
        XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false)
        XCTAssertEqual((body["StartTimeTicks"] as? NSNumber)?.int64Value, 900_000_000)
    }

    func test_transcodeStream_withoutATranscodingUrl_throwsTranscodeRequired() async {
        server.respond("/Items/m1/PlaybackInfo", body: """
            {"MediaSources":[{"Id":"m1","SupportsDirectPlay":true,"MediaStreams":[]}],"PlaySessionId":"ps4"}
            """)
        do {
            _ = try await provider().transcodeStream(for: MediaItemRef(providerID: "jellyfin:srv", itemID: "m1"),
                                                     sourceID: "m1", startTime: 0)
            XCTFail("expected a throw")
        } catch MediaProviderError.transcodeRequired {
        } catch { XCTFail("got \(error)") }
    }

    func test_transcodeReporter_saysTranscode_andStopsTheEncoding() async throws {
        server.respond("/Items/m1/PlaybackInfo", body: """
            {"MediaSources":[{"Id":"m1","SupportsDirectPlay":false,"TranscodingUrl":"/videos/m1/master.m3u8?ApiKey=tok","MediaStreams":[]}],
             "PlaySessionId":"ps3"}
            """)
        server.respond("/Sessions/Playing/Stopped", status: 204)
        server.respond("/Videos/ActiveEncodings", status: 204)
        let p = provider()
        let ref = MediaItemRef(providerID: "jellyfin:srv", itemID: "m1")
        _ = try await p.resolveStream(for: ref, sourceID: nil)
        await p.progressReporter(for: ref, sourceID: "m1", playSessionID: "ps3").stopped(at: 12)
        let stopped = try XCTUnwrap(server.requests.firstIndex { $0.url?.path.hasSuffix("/Sessions/Playing/Stopped") == true })
        XCTAssertEqual(server.jsonBody(stopped)["PlayMethod"] as? String, "Transcode")
        let kill = try XCTUnwrap(server.requests.first { $0.url?.path.hasSuffix("/Videos/ActiveEncodings") == true })
        XCTAssertEqual(kill.httpMethod, "DELETE")
        XCTAssertTrue(kill.url!.query!.contains("playSessionId=ps3"))
    }

    func test_progressReporter_sendsTicksAndIDs() async {
        server.respond("/Sessions/Playing", status: 204)
        server.respond("/Sessions/Playing/Progress", status: 204)
        server.respond("/Sessions/Playing/Stopped", status: 204)
        let reporter = provider().progressReporter(for: ref, sourceID: "src-4k", playSessionID: "psid-1")
        await reporter.start(position: 412)
        await reporter.paused(at: 61.5)
        await reporter.stopped(at: 62)
        XCTAssertEqual(server.requests.map { $0.url!.path },
                       ["/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"])
        XCTAssertEqual(server.jsonBody(0)["PositionTicks"] as? Int, 4_120_000_000)
        XCTAssertEqual(server.jsonBody(1)["PositionTicks"] as? Int, 615_000_000)
        XCTAssertEqual(server.jsonBody(1)["IsPaused"] as? Bool, true)
        XCTAssertEqual(server.jsonBody(2)["MediaSourceId"] as? String, "src-4k")
        XCTAssertEqual(server.jsonBody(2)["PlaySessionId"] as? String, "psid-1")
    }

    // MARK: - Browse

    func test_children_ofSeason_usesShowEpisodesRoute() async throws {
        server.respond("/Items/season1", body: #"{"Id":"season1","Type":"Season","SeriesId":"show1"}"#)
        server.respond("/Shows/show1/Episodes", body: #"{"Items":[\#(JellyfinFixtures.episode)],"TotalRecordCount":1}"#)
        let kids = try await provider().children(of: MediaItemRef(providerID: "jellyfin:srv", itemID: "season1"))
        XCTAssertEqual(kids.map(\.ref.itemID), ["ep1"])
        XCTAssertTrue(server.query(1).contains(URLQueryItem(name: "seasonId", value: "season1")))
    }

    func test_children_ofSeries_usesSeasonsRoute() async throws {
        server.respond("/Items/show1", body: #"{"Id":"show1","Type":"Series"}"#)
        server.respond("/Shows/show1/Seasons", body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider().children(of: MediaItemRef(providerID: "jellyfin:srv", itemID: "show1"))
        XCTAssertEqual(server.requests.last?.url?.path, "/Shows/show1/Seasons")
    }

    func test_items_pagesAndFiltersByLibraryKind() async throws {
        server.respond("/Items", body: #"{"Items":[\#(JellyfinFixtures.series)],"TotalRecordCount":120}"#)
        let lib = MediaLibrary(id: "lib-tv", providerID: "jellyfin:srv", title: "TV", kind: .shows)
        let page = try await provider().items(in: lib, sort: .titleAsc, page: Page(offset: 0, limit: 50))
        XCTAssertEqual(page.total, 120)
        XCTAssertEqual(page.nextPage, Page(offset: 50, limit: 50))
        let query = server.query(0)
        XCTAssertTrue(query.contains(URLQueryItem(name: "parentId", value: "lib-tv")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "includeItemTypes", value: "Series")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "sortBy", value: "SortName")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "fields", value: "Overview,RecursiveItemCount,SortName,ParentId,MediaSourceCount")))
    }

    func test_items_lastPage_hasNoNextPage() async throws {
        server.respond("/Items", body: #"{"Items":[],"TotalRecordCount":40}"#)
        let lib = MediaLibrary(id: "lib", providerID: "jellyfin:srv", title: "M", kind: .movies)
        let page = try await provider().items(in: lib, sort: .addedAtDesc, page: Page(offset: 0, limit: 50))
        XCTAssertNil(page.nextPage)
    }

    /// /Items/Latest across every library returns only the newest grouped
    /// series on a 12.1 server: all nine movies vanished. Each library is
    /// asked on its own, as Jellyfin's clients do, and the results merged
    /// newest first. A series sorts by its newest episode.
    func test_recentlyAdded_asksEachVideoLibrary_newestFirst() async throws {
        server.respond("/UserViews", body: """
        {"Items":[{"Id":"lib-m","Name":"Movies","CollectionType":"movies"},
                  {"Id":"lib-tv","Name":"TV","CollectionType":"tvshows"},
                  {"Id":"lib-music","Name":"Music","CollectionType":"music"}],"TotalRecordCount":3}
        """)
        server.respond("/Items/Latest", query: ["parentId": "lib-m"], body: """
        [{"Id":"m-old","Name":"Old","Type":"Movie","DateCreated":"2026-09-01T10:00:00.0000000Z"},
         {"Id":"m-new","Name":"New","Type":"Movie","DateCreated":"2026-09-30T10:00:00.0000000Z"}]
        """)
        server.respond("/Items/Latest", query: ["parentId": "lib-tv"], body: """
        [{"Id":"show","Name":"Show","Type":"Series","DateCreated":"2020-01-01T00:00:00.0000000Z",
          "DateLastContentAdded":"2026-09-15T10:00:00.0000000Z"}]
        """)

        let items = try await provider().recentlyAdded(limit: 2)

        XCTAssertEqual(items.map(\.ref.itemID), ["m-new", "show"])
        XCTAssertFalse(server.requests.contains { $0.url?.query?.contains("lib-music") == true })
    }

    func test_fullDetail_series_fetchesNextUp() async throws {
        server.respond("/Items/show1", body: JellyfinFixtures.series)
        server.respond("/Shows/NextUp", body: #"{"Items":[\#(JellyfinFixtures.episode)],"TotalRecordCount":1}"#)
        let detail = try await provider().fullDetail(for: MediaItemRef(providerID: "jellyfin:srv", itemID: "show1"))
        XCTAssertEqual(detail.nextEpisode?.ref.itemID, "ep1")
        XCTAssertTrue(server.query(1).contains(URLQueryItem(name: "seriesId", value: "show1")))
    }

    func test_related_returnsSimilar_withoutCollection() async throws {
        server.respond("/Items/m1/Similar", body: #"{"Items":[\#(JellyfinFixtures.series)],"TotalRecordCount":1}"#)
        let related = try await provider().related(for: MediaItemRef(providerID: "jellyfin:srv", itemID: "m1"), kind: .movie)
        XCTAssertEqual(related.items.map(\.ref.itemID), ["show1"])
        XCTAssertNil(related.collection)
    }

    // MARK: - Watch state

    func test_markPlayed_andUnplayed_useUserPlayedItems() async throws {
        server.respond("/UserPlayedItems/ep1", body: "{}")
        let p = provider()
        try await p.markPlayed(ref)
        try await p.markUnplayed(ref)
        XCTAssertEqual(server.requests.map(\.httpMethod), ["POST", "DELETE"])
    }

    // MARK: - Continue Watching

    func test_continueWatching_resumeThenNextUp_videoOnly() async throws {
        server.respond("/UserItems/Resume", body: """
            {"Items":[{"Id":"m1","Name":"American Made","Type":"Movie",
              "UserData":{"PlaybackPositionTicks":18000000000,"Played":false}}],"TotalRecordCount":1}
            """)
        server.respond("/Shows/NextUp", body: """
            {"Items":[{"Id":"ep2","Name":"Light Bulb","Type":"Episode","SeriesId":"show1",
              "ParentIndexNumber":1,"IndexNumber":2}],"TotalRecordCount":1}
            """)

        let items = try await provider().continueWatching(limit: 20)

        XCTAssertEqual(items.map(\.ref.itemID), ["m1", "ep2"])
        let resume = try XCTUnwrap(server.requests.firstIndex { $0.url?.path.hasSuffix("/UserItems/Resume") == true })
        XCTAssertTrue(server.query(resume).contains(URLQueryItem(name: "mediaTypes", value: "Video")),
                      "without mediaTypes=Video, 12.1 lists series and seasons at position 0 in Resume")
        let nextUp = try XCTUnwrap(server.requests.firstIndex { $0.url?.path.hasSuffix("/Shows/NextUp") == true })
        XCTAssertTrue(server.query(nextUp).contains(URLQueryItem(name: "enableResumable", value: "false")),
                      "a half-watched episode is already in Resume; Next Up must not list it again")
    }

    func test_continueWatching_nextUpFailure_stillReturnsResume() async throws {
        server.respond("/UserItems/Resume",
                       body: #"{"Items":[{"Id":"m1","Name":"American Made","Type":"Movie"}],"TotalRecordCount":1}"#)
        server.respond("/Shows/NextUp", status: 500)

        let items = try await provider().continueWatching(limit: 20)

        XCTAssertEqual(items.map(\.ref.itemID), ["m1"])
    }

    func test_continueWatching_capsAtLimit() async throws {
        server.respond("/UserItems/Resume",
                       body: #"{"Items":[{"Id":"m1","Name":"A","Type":"Movie"},{"Id":"m2","Name":"B","Type":"Movie"}],"TotalRecordCount":2}"#)
        server.respond("/Shows/NextUp",
                       body: #"{"Items":[{"Id":"ep2","Name":"C","Type":"Episode","SeriesId":"show1"}],"TotalRecordCount":1}"#)

        let items = try await provider().continueWatching(limit: 2)

        XCTAssertEqual(items.map(\.ref.itemID), ["m1", "m2"])
    }

    // MARK: - Sort

    func test_sortParameters_coverEverySortOption() {
        XCTAssertEqual(JellyfinProvider.sortParameters(.addedAtAsc).0, "DateCreated,SortName")
        XCTAssertEqual(JellyfinProvider.sortParameters(.addedAtAsc).1, "Ascending")
        XCTAssertEqual(JellyfinProvider.sortParameters(.releaseDateAsc).0, "PremiereDate,SortName")
        XCTAssertEqual(JellyfinProvider.sortParameters(.releaseDateAsc).1, "Ascending")
        XCTAssertEqual(JellyfinProvider.sortParameters(.lastContentAddedDesc).0, "DateLastContentAdded,SortName")
        XCTAssertEqual(JellyfinProvider.sortParameters(.lastContentAddedDesc).1, "Descending")
    }

    // MARK: - Library extras

    private let movies = MediaLibrary(id: "lib-m", providerID: "jellyfin:srv", title: "Movies", kind: .movies)

    /// Home's per-library reload: one request, not the three `hubs(in:)` makes.
    func test_recentlyAddedHub_isOneRequest() async throws {
        server.respond("/Items/Latest", body: #"[{"Id":"m2","Name":"28 Years Later","Type":"Movie"}]"#)
        let hub = try await provider().recentlyAddedHub(in: movies)
        XCTAssertEqual(hub?.id, "lib-m.recentlyAdded")
        XCTAssertEqual(hub?.title, "Recently Added in Movies")
        XCTAssertEqual(hub?.items.map(\.ref.itemID), ["m2"])
        XCTAssertEqual(server.requests.map { $0.url!.path }, ["/Items/Latest"])
    }

    func test_recentlyAddedHub_nilWhenEmpty() async throws {
        server.respond("/Items/Latest", body: "[]")
        let hub = try await provider().recentlyAddedHub(in: movies)
        XCTAssertNil(hub)
    }

    func test_hubsInLibrary_continueWatchingThenRecentlyAdded_scopedToTheLibrary() async throws {
        server.respond("/UserItems/Resume",
                       body: #"{"Items":[{"Id":"m1","Name":"American Made","Type":"Movie"}],"TotalRecordCount":1}"#)
        server.respond("/Shows/NextUp", body: #"{"Items":[],"TotalRecordCount":0}"#)
        server.respond("/Items/Latest", body: #"[{"Id":"m2","Name":"28 Years Later","Type":"Movie"}]"#)

        let hubs = try await provider().hubs(in: movies)

        XCTAssertEqual(hubs.map(\.id), ["lib-m.continueWatching", "lib-m.recentlyAdded"])
        XCTAssertEqual(hubs.map(\.title), ["Continue Watching", "Recently Added in Movies"])
        XCTAssertEqual(hubs.map { $0.items.map(\.ref.itemID) }, [["m1"], ["m2"]])
        for index in server.requests.indices {
            XCTAssertTrue(server.query(index).contains(URLQueryItem(name: "parentId", value: "lib-m")),
                          "\(server.requests[index].url!.path) must be scoped to the library")
        }
    }

    func test_hubsInLibrary_dropsEmptyRows() async throws {
        server.respond("/UserItems/Resume", body: #"{"Items":[],"TotalRecordCount":0}"#)
        server.respond("/Shows/NextUp", body: #"{"Items":[],"TotalRecordCount":0}"#)
        server.respond("/Items/Latest", body: #"[{"Id":"m2","Name":"28 Years Later","Type":"Movie"}]"#)

        let hubs = try await provider().hubs(in: movies)

        XCTAssertEqual(hubs.map(\.id), ["lib-m.recentlyAdded"])
    }

    func test_collections_areBoxSetsInTheLibrary() async throws {
        server.respond("/Items", query: ["includeItemTypes": "BoxSet"], body: """
            {"Items":[{"Id":"c1","Name":"Rivulet Probe Collection","Type":"BoxSet"}],"TotalRecordCount":1}
            """)

        let collections = try await provider().collections(in: movies)

        XCTAssertEqual(collections.map(\.kind), [.collection])
        XCTAssertTrue(server.query(0).contains(URLQueryItem(name: "parentId", value: "lib-m")))
        XCTAssertTrue(server.query(0).contains(URLQueryItem(name: "recursive", value: "true")))
    }

    func test_letterCounts_hashFirstThenAtoZ_fromSortNameCounts() async throws {
        server.respond("/Items", query: ["nameLessThan": "A"], body: #"{"Items":[],"TotalRecordCount":2}"#)
        server.respond("/Items", query: ["nameStartsWith": "A"], body: #"{"Items":[],"TotalRecordCount":1}"#)
        server.respond("/Items", query: ["nameStartsWith": "I"], body: #"{"Items":[],"TotalRecordCount":1}"#)
        server.respond("/Items", body: #"{"Items":[],"TotalRecordCount":0}"#)

        let counts = try await provider().letterCounts(in: movies)

        XCTAssertEqual(counts.count, 27)
        XCTAssertEqual(counts.first, PlexFirstCharacter(title: "#", size: 2))
        XCTAssertEqual(counts[1], PlexFirstCharacter(title: "A", size: 1))
        XCTAssertEqual(counts[9], PlexFirstCharacter(title: "I", size: 1))
        XCTAssertEqual(counts.last?.title, "Z")
        XCTAssertTrue(server.requests.indices.allSatisfy {
            server.query($0).contains(URLQueryItem(name: "limit", value: "0"))
        }, "counts only: no item bodies")
    }

    func test_refreshMetadata_postsAFullRefresh() async throws {
        server.respond("/Items/m1/Refresh", status: 204)

        try await provider().refreshMetadata(MediaItemRef(providerID: "jellyfin:srv", itemID: "m1"))

        XCTAssertEqual(server.requests.first?.httpMethod, "POST")
        XCTAssertTrue(server.query(0).contains(URLQueryItem(name: "metadataRefreshMode", value: "FullRefresh")))
    }

    func test_search_asksForTitlesAndEpisodes() async throws {
        server.respond("/Items", query: ["searchTerm": "the"], body: """
        {"Items":[{"Id":"m1","Name":"The Island","Type":"Movie"},
                  {"Id":"e1","Name":"The Deli","Type":"Episode","SeriesId":"show1"}],"TotalRecordCount":2}
        """)

        let items = try await provider().search("the")

        XCTAssertEqual(items.map(\.kind), [.movie, .episode])
        XCTAssertTrue(server.query(0).contains(URLQueryItem(name: "includeItemTypes", value: "Movie,Series,Episode")))
    }

    func test_search_perLibrary_asksOncePerParent_inOrder() async throws {
        server.respond("/Items", query: ["parentId": "lib1"], body: """
        {"Items":[{"Id":"a","Name":"A","Type":"Movie"}],"TotalRecordCount":1}
        """)
        server.respond("/Items", query: ["parentId": "lib2"], body: """
        {"Items":[{"Id":"b","Name":"B","Type":"Movie"}],"TotalRecordCount":1}
        """)

        let items = try await provider().search("x", inLibraries: ["lib1", "lib2"])

        XCTAssertEqual(items.map(\.ref.itemID), ["a", "b"])
        XCTAssertEqual(server.requests.count, 2)
        for i in 0..<2 {
            XCTAssertTrue(server.query(i).contains(URLQueryItem(name: "searchTerm", value: "x")))
        }
        XCTAssertEqual(Set((0..<2).flatMap { i in server.query(i).filter { $0.name == "parentId" }.compactMap(\.value) }),
                       ["lib1", "lib2"])
    }

    func test_playbackExtras_segmentsBecomeMarkers() async throws {
        server.respond("/MediaSegments/ep1", body: """
            {"Items":[{"Type":"Intro","StartTicks":300000000,"EndTicks":900000000},
                      {"Type":"Outro","StartTicks":12000000000,"EndTicks":13000000000},
                      {"Type":"Unknown","StartTicks":0,"EndTicks":10}],"TotalRecordCount":3}
            """)
        let extras = await provider().playbackExtras(for: ref, sourceID: nil)

        XCTAssertEqual(extras.markers, [PlaybackMarker(kind: .intro, start: 30, end: 90),
                                        PlaybackMarker(kind: .credits, start: 1200, end: 1300)])
    }

    func test_playbackExtras_missingRoutes_areEmpty() async {
        let extras = await provider().playbackExtras(for: ref, sourceID: nil)
        XCTAssertTrue(extras.markers.isEmpty)
    }
}
