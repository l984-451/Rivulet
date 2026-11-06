// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyProviderTests.swift
//  RivuletTests
//
//  EmbyProvider against FakeEmbyServer replaying real captured responses. Replies
//  marked "hand-built" have no capture (the route was never observed on a real server).
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyProviderTests: XCTestCase {
    private let server = FakeEmbyServer()
    private let uid = EmbyLiveFixtures.userID
    private var items: String { "/Users/\(uid)/Items" }

    private func provider(policy: EmbySession.Policy = EmbySession.Policy()) -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: uid, policy: policy,
                     client: EmbyClient(baseURL: EmbyBrowseFixtures.baseURL, token: "tok", transport: server.transport))
    }

    private func ref(_ id: String) -> MediaItemRef { MediaItemRef(providerID: "emby:srv", itemID: id) }

    private func query(_ request: URLRequest) -> [String: String] {
        let pairs = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func paths() -> [String] { server.requests.map { $0.url!.path } }

    override func tearDown() async throws {
        XCTAssertEqual(server.headerProblems, [])
        try await super.tearDown()
    }

    func test_identity() {
        let p = provider()
        XCTAssertEqual(p.id, "emby:srv")
        XCTAssertEqual(p.kind, .emby)
        XCTAssertEqual(p.accountID, uid)
        XCTAssertFalse(p.supportsWatchlist)
    }

    func test_deepLink_embyServerResolvesAsAProvider() {
        let link = RivuletLink(.detail, ratingKey: "166", server: "emby:srv")
        XCTAssertEqual(DeepLinkHandler().providerID(of: link), "emby:srv")
        XCTAssertFalse(ref("166").isPlex)
    }

    // MARK: - Libraries

    func test_libraries_probesHomeVideosForPhotos() async throws {
        server.respond("/Users/\(uid)/Views", body: EmbyBrowseFixtures.views)
        server.respond(items, query: ["ParentId": "9"], body: #"{"Items":[],"TotalRecordCount":4}"#)
        let libraries = try await provider().libraries()
        XCTAssertEqual(libraries.map(\.kind), [.mixed, .movies, .music, .photos, .shows])
        let probe = try XCTUnwrap(server.requests.first { $0.url!.path == items })
        XCTAssertEqual(query(probe)["IncludeItemTypes"], "Photo")
        XCTAssertEqual(query(probe)["Limit"], "0")
        XCTAssertEqual(query(probe)["Recursive"], "true")
    }

    func test_libraries_homeVideosWithoutPhotos_isAVideoLibrary() async throws {
        server.respond("/Users/\(uid)/Views", body: EmbyBrowseFixtures.views)
        server.respond(items, body: #"{"Items":[],"TotalRecordCount":0}"#)
        let photos = try await provider().libraries().first { $0.id == "9" }
        XCTAssertEqual(photos?.kind, .mixed)
        XCTAssertEqual(photos?.browsesByFolder, true)
    }

    func test_libraries_dropsBoxSetsAndPlaylists() async throws {
        server.respond("/Users/\(uid)/Views", body: EmbyBrowseFixtures.viewsWithBoxSetsAndPlaylists)
        server.respond(items, body: #"{"Items":[],"TotalRecordCount":0}"#)
        let ids = try await provider().libraries().map(\.id)
        XCTAssertEqual(ids, ["11", "3", "7", "9", "5"])
    }

    func test_libraries_failedProbeFailsTheCall() async {
        server.respond("/Users/\(uid)/Views", body: EmbyBrowseFixtures.views)
        server.respond(items, status: 500, body: "boom", contentType: "text/plain")
        do {
            _ = try await provider().libraries()
            XCTFail("a failed probe must not look like a video library")
        } catch {}
    }

    // MARK: - Listings

    /// Measured: a list leaves these out unless named, and PlayCount reads 0 without UserDataPlayCount.
    private func assertMeasuredListFields(_ sent: String?, file: StaticString = #filePath, line: UInt = #line) {
        let required: Set<String> = ["ProductionYear", "PremiereDate", "OfficialRating", "CommunityRating", "UserDataPlayCount",
                                     "UserDataLastPlayedDate", "ChildCount", "RecursiveItemCount", "ParentId", "SortName"]
        XCTAssertTrue(required.isSubset(of: Set((sent ?? "").split(separator: ",").map(String.init))), sent ?? "nil", file: file, line: line)
    }

    func test_items_asksRecursiveWithTypesAndTheListFields() async throws {
        server.respond(items, body: EmbyBrowseFixtures.moviesPage)
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let page = try await provider().items(in: library, sort: .titleAsc, page: Page(offset: 0, limit: 3))
        let q = query(try XCTUnwrap(server.requests.first))
        XCTAssertEqual(q["ParentId"], "3")
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["IncludeItemTypes"], "Movie")
        XCTAssertEqual(q["StartIndex"], "0")
        XCTAssertEqual(q["Limit"], "3")
        assertMeasuredListFields(q["Fields"])
        XCTAssertNil(q["GroupItemsIntoCollections"])
        XCTAssertNil(q["EnableTotalRecordCount"], "the total is on by default")
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.total, 476)
        XCTAssertEqual(page.nextPage, Page(offset: 3, limit: 3))
    }

    func test_items_lastPage_hasNoNext() async throws {
        server.respond(items, body: EmbyBrowseFixtures.moviesPage.replacingOccurrences(of: #""TotalRecordCount":476"#, with: #""TotalRecordCount":5"#))
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let page = try await provider().items(in: library, sort: .titleAsc, page: Page(offset: 3, limit: 3))
        XCTAssertNil(page.nextPage)
    }

    func test_items_typesFollowTheLibraryKind() async throws {
        server.respond(items, body: #"{"Items":[],"TotalRecordCount":0}"#)
        let p = provider()
        for (kind, types) in [(MediaLibrary.LibraryKind.shows, "Series"), (.mixed, "Movie,Series,Video")] {
            let library = MediaLibrary(id: "1", providerID: "emby:srv", title: "L", kind: kind)
            _ = try await p.items(in: library, sort: .titleAsc, page: Page(offset: 0, limit: 10))
            XCTAssertEqual(query(try XCTUnwrap(server.requests.last))["IncludeItemTypes"], types)
        }
    }

    func test_sortMapping_allKeysAcceptedAndSortNameBreaksTies() {
        let expected: [SortOption: (String, String)] = [
            .titleAsc: ("SortName", "Ascending"),
            .titleDesc: ("SortName", "Descending"),
            .releaseDateDesc: ("PremiereDate,SortName", "Descending,Ascending"),
            .releaseDateAsc: ("PremiereDate,SortName", "Ascending,Ascending"),
            .addedAtDesc: ("DateCreated,SortName", "Descending,Ascending"),
            .addedAtAsc: ("DateCreated,SortName", "Ascending,Ascending"),
            .lastContentAddedDesc: ("DateLastContentAdded,SortName", "Descending,Ascending"),
            .ratingDesc: ("CommunityRating,SortName", "Descending,Ascending")
        ]
        let allowed: Set<String> = ["SortName", "PremiereDate", "DateCreated", "DateLastContentAdded", "CommunityRating"]
        XCTAssertEqual(expected.count, 8)
        for sort in expected.keys {
            let (by, order) = EmbyProvider.sortParameters(sort)
            XCTAssertEqual(by, expected[sort]?.0, "\(sort)")
            XCTAssertEqual(order, expected[sort]?.1, "\(sort)")
            let keys = by.split(separator: ",").map(String.init)
            XCTAssertTrue(keys.allSatisfy(allowed.contains), "an unknown SortBy key is a 500")
            XCTAssertEqual(keys.last, "SortName")
            XCTAssertEqual(order.split(separator: ",").count, keys.count, "one order per key")
        }
    }

    func test_sortOptions_defaultDropsResolution() {
        let options = provider().sortOptions(for: .movies)
        XCTAssertFalse(options.contains(.resolutionAsc))
        XCTAssertFalse(options.contains(.resolutionDesc))
        XCTAssertFalse(options.isEmpty)
    }

    // MARK: - Children

    func test_children_ofASeries_areItsSeasons() async throws {
        server.respond("\(items)/1661", body: EmbyBrowseFixtures.seriesDetail)
        server.respond("/Shows/1661/Seasons", body: EmbyBrowseFixtures.seasonsAbbott)
        let seasons = try await provider().children(of: ref("1661"))
        XCTAssertEqual(seasons.count, 6)
        XCTAssertEqual(seasons.map(\.kind), Array(repeating: .season, count: 6))
        let seasonRequest = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(query(seasonRequest)["UserId"], uid)
        assertMeasuredListFields(query(seasonRequest)["Fields"])
    }

    func test_children_ofASeason_areItsEpisodesFromTheShowRoute() async throws {
        server.respond("\(items)/1665", body: EmbyTestJSON.item(EmbyBrowseFixtures.seasonsAbbott))
        server.respond("/Shows/1661/Episodes", body: EmbyBrowseFixtures.episodesAbbott)
        let episodes = try await provider().children(of: ref("1665"))
        XCTAssertEqual(episodes.count, 3)
        let request = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(query(request)["SeasonId"], "1665")
        XCTAssertEqual(query(request)["UserId"], uid)
    }

    func test_children_ofABoxSet_areItsMembers() async throws {
        server.respond("\(items)/1778", body: EmbyTestJSON.item(EmbyBrowseFixtures.boxSets))
        server.respond(items, query: ["ParentId": "1778"], body: EmbyBrowseFixtures.boxSetMembers)
        let members = try await provider().children(of: ref("1778"))
        XCTAssertEqual(members.map(\.title), ["12 Years a Slave", "28 Years Later"])
    }

    func test_allEpisodes_putSeasonZeroLast() async throws {
        server.respond("/Shows/13/Episodes", body: EmbyTestJSON.merged([EmbyBrowseFixtures.specialsEpisodes, EmbyBrowseFixtures.episodesAbbott]))
        let episodes = try await provider().allEpisodes(of: ref("13"))
        XCTAssertEqual(episodes.map(\.seasonNumber), [1, 1, 1, 0])
        XCTAssertNil(query(try XCTUnwrap(server.requests.first))["SeasonId"])
    }

    /// Hand-built: a `Virtual` LocationType never appeared on the test server.
    func test_allEpisodes_dropVirtualUnairedEpisodes_unverified() async throws {
        let withVirtual = EmbyBrowseFixtures.episodesAbbott.replacingOccurrences(of: #""Id":"1716","#, with: #""Id":"1716","LocationType":"Virtual","#)
        server.respond("/Shows/1661/Episodes", body: withVirtual)
        let episodes = try await provider().allEpisodes(of: ref("1661"))
        XCTAssertEqual(episodes.map(\.ref.itemID), ["1717", "1718"])
    }

    // MARK: - Related

    func test_related_similarNeedsUserId() async throws {
        server.respond("/Items/166/Similar", body: EmbyBrowseFixtures.similar)
        let related = try await provider().related(for: ref("166"), kind: .episode)
        XCTAssertEqual(related.items.map(\.ref.itemID), ["166"])
        XCTAssertNil(related.collection)
        XCTAssertEqual(query(try XCTUnwrap(server.requests.first))["UserId"], uid)
    }

    func test_related_movieCollectionRow_excludesItselfAndItsMembersFromRelated() async throws {
        server.respond("/Items/856/Similar", body: EmbyBrowseFixtures.similar.replacingOccurrences(of: #""Id":"166""#, with: #""Id":"857""#))
        server.respond("\(items)/856", body: EmbyTestJSON.item(EmbyBrowseFixtures.moviesWithCollections))
        server.respond(items, query: ["ParentId": "1778"], body: EmbyBrowseFixtures.boxSetMembers)
        let related = try await provider().related(for: ref("856"), kind: .movie)
        XCTAssertEqual(related.collection?.title, "zz-version-matrix-box")
        XCTAssertEqual(related.collection?.members.map(\.ref.itemID), ["857"])
        XCTAssertNil(related.collection?.collection)
        XCTAssertEqual(related.items, [], "28 Years Later is a member, so it is not Related too")
        let detail = try XCTUnwrap(server.requests.first { $0.url!.path == "\(items)/856" })
        XCTAssertEqual(query(detail)["Fields"], "Collections")
    }

    func test_related_failedCollectionLookup_keepsRelated() async throws {
        server.respond("/Items/166/Similar", body: EmbyBrowseFixtures.similar)
        let related = try await provider().related(for: ref("166"), kind: .movie)
        XCTAssertEqual(related.items.count, 1)
        XCTAssertNil(related.collection)
    }

    // MARK: - Search

    func test_search_setsExplicitItemTypes() async throws {
        server.respond(items, body: EmbyBrowseFixtures.searchAllTypes)
        let results = try await provider().search("zz")
        let q = query(try XCTUnwrap(server.requests.first))
        XCTAssertEqual(q["SearchTerm"], "zz")
        XCTAssertEqual(q["IncludeItemTypes"], "Movie,Series,Episode")
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertNil(q["ParentId"])
        XCTAssertFalse(results.isEmpty)
    }

    func test_search_inLibraries_oneRequestEachInLibraryOrder() async throws {
        server.respond(items, query: ["ParentId": "3"], body: EmbyBrowseFixtures.moviesPage)
        server.respond(items, query: ["ParentId": "5"], body: EmbyBrowseFixtures.seriesPage)
        let results = try await provider().search("x", inLibraries: ["3", "5"])
        XCTAssertEqual(results.map(\.kind), [.movie, .movie, .movie, .show, .show, .show])
        XCTAssertEqual(server.requests.count, 2)
    }

    // MARK: - Detail

    func test_fullDetail_movie_asksTheThreeExtraFields() async throws {
        server.respond("\(items)/166", body: EmbyBrowseFixtures.movieDetail)
        let detail = try await provider().fullDetail(for: ref("166"))
        XCTAssertEqual(detail.item.title, "01 Sample Clip")
        XCTAssertEqual(query(try XCTUnwrap(server.requests.first))["Fields"], "ChildCount,RecursiveItemCount,Collections,RemoteTrailers")
        XCTAssertEqual(detail.chapters.count, 4)
        XCTAssertEqual(paths(), ["\(items)/166"], "no trailers counted, so no extras request")
    }

    func test_fullDetail_show_sumsSeasonsAndFindsTheNextEpisode() async throws {
        server.respond("\(items)/1661", body: EmbyBrowseFixtures.seriesDetail)
        server.respond("/Shows/1661/Seasons", body: EmbyBrowseFixtures.seasonsAbbott)
        server.respond("/Shows/NextUp", body: EmbyBrowseFixtures.episodesAbbott)
        let detail = try await provider().fullDetail(for: ref("1661"))
        XCTAssertEqual(detail.item.childProgress, ChildProgress(played: 0, total: 97))
        XCTAssertEqual(detail.nextEpisode?.ref.itemID, "1716")
        let nextUp = try XCTUnwrap(server.requests.first { $0.url!.path == "/Shows/NextUp" })
        XCTAssertEqual(query(nextUp)["SeriesId"], "1661")
        XCTAssertEqual(query(nextUp)["Limit"], "1")
    }

    /// Spec only: the trailer and special feature routes were never called.
    func test_fullDetail_extrasAreAskedOnlyWhenCounted_unverified() async throws {
        let counted = EmbyBrowseFixtures.movieDetail.replacingOccurrences(of: #""LocalTrailerCount":0"#, with: #""LocalTrailerCount":1"#)
        server.respond("\(items)/166", body: counted)
        server.respond("\(items)/166/LocalTrailers", body: #"[{"Id":"900","Name":"Trailer","Type":"Trailer"}]"#)
        let detail = try await provider().fullDetail(for: ref("166"))
        XCTAssertEqual(detail.extras.map(\.id), ["900"])
        XCTAssertFalse(paths().contains("\(items)/166/SpecialFeatures"))
    }

    // MARK: - Continue Watching

    func test_continueWatching_isResumeAloneWithMediaTypesVideo() async throws {
        server.respond("\(items)/Resume", body: EmbyBrowseFixtures.resume)
        let rows = try await provider().continueWatching(limit: 12)
        let resume = try XCTUnwrap(server.requests.first { $0.url!.path == "\(items)/Resume" })
        XCTAssertEqual(query(resume)["MediaTypes"], "Video")
        XCTAssertEqual(query(resume)["Limit"], "12")
        XCTAssertTrue(query(resume)["Fields"]?.contains("ProviderIds") == true)
        XCTAssertFalse(paths().contains("/Shows/NextUp"), "Next Up repeats the same episode")
        XCTAssertEqual(rows.map(\.kind), [.episode, .movie])
    }

    func test_continueWatching_nextUpEntryAtPositionZero_andTheHalfWatchedMovie() async throws {
        server.respond("\(items)/Resume", body: EmbyBrowseFixtures.resume)
        let rows = try await provider().continueWatching(limit: 12)
        XCTAssertEqual(rows[0].userState.viewOffset, 0)
        XCTAssertFalse(rows[0].userState.isPlayed)
        XCTAssertEqual(rows[0].grandparentRef?.itemID, "14")
        XCTAssertEqual(rows[1].userState.viewOffset, 300)
    }

    func test_continueWatching_movieIdentity_readsProviderIDsInAnyCase() async throws {
        let upper = EmbyBrowseFixtures.resume.replacingOccurrences(of: #""Imdb":"tt9990001""#, with: #""IMDB":"tt9990001""#)
        server.respond("\(items)/Resume", body: upper)
        let rows = try await provider().continueWatching(limit: 12)
        XCTAssertEqual(rows[1].identity, ["m:imdb:tt9990001", "m:tmdb:999001"])
        XCTAssertNil(rows[0].identity)
    }

    /// Hand-built reply for a played-episodes route that was only measured for audio.
    func test_continueWatching_nextUpEntryTakesItsShowsLastWatch_unverified() async throws {
        server.respond("\(items)/Resume", body: EmbyBrowseFixtures.resume)
        server.respond(items, query: ["Filters": "IsPlayed"], body: """
            {"Items":[{"Id":"50","Name":"E","Type":"Episode","SeriesId":"14",
             "UserData":{"LastPlayedDate":"2026-10-30T20:15:00.0000000Z","Played":true}}],"TotalRecordCount":1}
            """)
        let rows = try await provider().continueWatching(limit: 12)
        XCTAssertEqual(rows[0].userState.lastViewedAt, EmbyJSON.date("2026-10-30T20:15:00.0000000Z"))
    }

    // MARK: - Recently added

    private func routeLibraries() {
        server.respond("/Users/\(uid)/Views", body: EmbyBrowseFixtures.views)
        // Photos probe (ParentId 9) first: no photos, so a mixed video library.
        server.respond(items, query: ["IncludeItemTypes": "Photo"], body: #"{"Items":[],"TotalRecordCount":0}"#)
    }

    func test_recentlyAdded_mergesPerLibraryLatestByDateCreated() async throws {
        routeLibraries()
        let latest = "\(items)/Latest"
        server.respond(latest, query: ["ParentId": "3"], body: """
            [{"Id":"m1","Name":"Old Movie","Type":"Movie","DateCreated":"2026-01-02T00:00:00.0000000Z"},
             {"Id":"m2","Name":"New Movie","Type":"Movie","DateCreated":"2026-09-02T00:00:00.0000000Z"}]
            """)
        server.respond(latest, query: ["ParentId": "5"], body: """
            [{"Id":"s1","Name":"Show","Type":"Series","DateCreated":"2026-10-01T13:03:08.4938149Z"}]
            """)
        server.respond(latest, query: ["ParentId": "11"], body: "[]")
        server.respond(latest, query: ["ParentId": "9"], body: "[]")
        let rows = try await provider().recentlyAdded(limit: 3)
        XCTAssertEqual(rows.map(\.ref.itemID), ["s1", "m2", "m1"])
        let requested = server.requests.filter { $0.url!.path == latest }
        XCTAssertEqual(Set(requested.compactMap { query($0)["ParentId"] }), ["3", "5", "9", "11"], "the music library is skipped")
        XCTAssertEqual(query(try XCTUnwrap(requested.first { query($0)["ParentId"] == "3" }))["IncludeItemTypes"], "Movie")
        XCTAssertEqual(query(try XCTUnwrap(requested.first { query($0)["ParentId"] == "5" }))["IncludeItemTypes"], "Series")
    }

    func test_recentlyAdded_limitCutsTheMergedList() async throws {
        routeLibraries()
        let latest = "\(items)/Latest"
        server.respond(latest, query: ["ParentId": "3"], body: """
            [{"Id":"m1","Name":"A","Type":"Movie","DateCreated":"2026-01-02T00:00:00.0000000Z"},
             {"Id":"m2","Name":"B","Type":"Movie","DateCreated":"2026-09-02T00:00:00.0000000Z"}]
            """)
        server.respond(latest, body: "[]")
        let rows = try await provider().recentlyAdded(limit: 1)
        XCTAssertEqual(rows.map(\.ref.itemID), ["m2"])
    }

    func test_hubs_isEmpty_andLibraryHubIsTheLatestRow() async throws {
        let p = provider()
        let global = try await p.hubs()
        XCTAssertEqual(global, [])
        server.respond("\(items)/Latest", body: EmbyBrowseFixtures.latestGrouped)
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let hubs = try await p.hubs(in: library)
        XCTAssertEqual(hubs.map(\.id), ["3.recentlyAdded"], "no Resume answer costs only that row")
        XCTAssertEqual(hubs.first?.items.count, 6)
        let one = try await p.recentlyAddedHub(in: library)
        XCTAssertEqual(one?.id, "3.recentlyAdded")
        let latest = try XCTUnwrap(server.requests.first { $0.url!.path == "\(items)/Latest" })
        XCTAssertEqual(query(latest)["Limit"], "24")
    }

    func test_libraryHubs_putsTheLibrarysResumeRowFirst() async throws {
        server.respond("\(items)/Resume", body: EmbyBrowseFixtures.resume)
        server.respond("\(items)/Latest", body: EmbyBrowseFixtures.latestGrouped)
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let hubs = try await provider().hubs(in: library)
        XCTAssertEqual(hubs.map(\.id), ["3.continueWatching", "3.recentlyAdded"])
        let resume = try XCTUnwrap(server.requests.first { $0.url!.path == "\(items)/Resume" })
        XCTAssertEqual(query(resume)["ParentId"], "3")
        XCTAssertEqual(query(resume)["MediaTypes"], "Video")
    }

    func test_recentlyAddedHub_emptyLibraryHasNoHub() async throws {
        server.respond("\(items)/Latest", body: "[]")
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let hub = try await provider().recentlyAddedHub(in: library)
        XCTAssertNil(hub)
    }

    // MARK: - Trending

    private func trendingItem(_ id: Int, _ type: TMDBMediaType) -> TMDBListItem {
        TMDBListItem(id: id, title: "T\(id)", overview: nil, posterPath: nil, backdropPath: nil,
                     releaseDate: nil, voteAverage: nil, mediaType: type)
    }

    func test_trending_matchesOnIdAndTypeThenFollowsTrendingOrder() async throws {
        let owned = EmbyBrowseFixtures.moviesPage.replacingOccurrences(of: #""ProviderIds":{},"IsFolder":false,"ParentId":"522""#,
                                                                       with: #""ProviderIds":{"tmdb":"42"},"IsFolder":false,"ParentId":"522""#)
        server.respond(items, body: owned)
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        // 999001 is trending as a show, so the movie holding that number must not match it.
        let list = [trendingItem(42, .movie), trendingItem(999001, .tv), trendingItem(999001, .movie)]
        let rows = try await provider().trending(in: library, from: list, limit: 10)
        XCTAssertEqual(rows.map(\.ref.itemID), ["530", "166"], "trending order, not the server's")
        let q = query(try XCTUnwrap(server.requests.first))
        XCTAssertEqual(q["AnyProviderIdEquals"], "tmdb.42,tmdb.999001,tmdb.999001")
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["ParentId"], "3")
        XCTAssertTrue(q["Fields"]?.contains("ProviderIds") == true)
    }

    func test_trending_batchesTheIdListUnderTheUrlLimit() async throws {
        server.respond(items, body: #"{"Items":[],"TotalRecordCount":0}"#)
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let list = (1...450).map { trendingItem($0, .movie) }
        _ = try await provider().trending(in: library, from: list, limit: 10)
        let sizes = server.requests.map { query($0)["AnyProviderIdEquals"]!.split(separator: ",").count }
        XCTAssertEqual(sizes, [200, 200, 50])
    }

    func test_trending_limitCutsTheResult() async throws {
        server.respond(items, body: EmbyBrowseFixtures.moviesPage)
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let rows = try await provider().trending(in: library, from: [trendingItem(999001, .movie)], limit: 0)
        XCTAssertEqual(rows, [])
    }

    // MARK: - Favorites

    func test_favorites_askForTheLibrarysFavoritesByName() async throws {
        server.respond(items, body: EmbyBrowseFixtures.moviesPage)
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let p = provider()
        XCTAssertTrue(p.supportsFavorites)
        _ = try await p.favorites(in: library, limit: 25)
        let q = query(try XCTUnwrap(server.requests.first))
        XCTAssertEqual(q["Filters"], "IsFavorite")
        XCTAssertEqual(q["ParentId"], "3")
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["SortBy"], "SortName")
        XCTAssertEqual(q["Limit"], "25")
    }

    // MARK: - Collections

    func test_collections_areTheLibrarysBoxSets() async throws {
        server.respond(items, body: EmbyBrowseFixtures.boxSets)
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let boxes = try await provider().collections(in: library)
        XCTAssertEqual(boxes.map(\.title), ["zz-browse-box", "zz-version-matrix-box"])
        let q = query(try XCTUnwrap(server.requests.first))
        XCTAssertEqual(q["IncludeItemTypes"], "BoxSet")
        XCTAssertEqual(q["ParentId"], "3")
        XCTAssertEqual(q["Recursive"], "true")
    }

    // MARK: - A to Z

    func test_letterCounts_prefixesThenOneCountEachWithHashFirst() async throws {
        server.respond("/Items/Prefixes", body: EmbyBrowseFixtures.prefixes)
        let counts: [(String, String, Int)] = [("#", "NameLessThan", 5), ("A", "NameStartsWith", 3), ("B", "NameStartsWith", 2),
                                               ("H", "NameStartsWith", 1), ("I", "NameStartsWith", 4), ("L", "NameStartsWith", 6),
                                               ("S", "NameStartsWith", 7), ("U", "NameStartsWith", 8)]
        for (letter, name, total) in counts {
            server.respond(items, query: [name: name == "NameLessThan" ? "A" : letter], body: #"{"Items":[],"TotalRecordCount":\#(total)}"#)
        }
        let library = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
        let result = try await provider().letterCounts(in: library)
        XCTAssertEqual(result, counts.map { PlexFirstCharacter(title: $0.0, size: $0.2) })
        let prefixRequest = try XCTUnwrap(server.requests.first { $0.url!.path == "/Items/Prefixes" })
        XCTAssertEqual(query(prefixRequest)["UserId"], uid)
        XCTAssertEqual(query(prefixRequest)["ParentId"], "3")
        XCTAssertEqual(query(prefixRequest)["IncludeItemTypes"], "Movie")
        let countRequests = server.requests.filter { $0.url!.path == items }
        XCTAssertEqual(countRequests.count, 8)
        XCTAssertTrue(countRequests.allSatisfy { query($0)["Limit"] == "0" && query($0)["Recursive"] == "true" })
        XCTAssertNil(countRequests.first { query($0)["NameStartsWith"] == "#" }, "NameStartsWith=# finds nothing")
    }

    // MARK: - Identity

    func test_showIdentityKeys_readsProviderIDsInAnyCase() async {
        server.respond(items, body: EmbyBrowseFixtures.seriesList4_8_11)
        let keys = await provider().showIdentityKeys(for: ["113"])
        XCTAssertEqual(keys["113"], ["s:imdb:tt14218830", "s:tmdb:125935", "s:tvdb:402910"])
        let q = query(server.requests[0])
        XCTAssertEqual(q["Ids"], "113")
        XCTAssertEqual(q["IncludeItemTypes"], "Series")
        XCTAssertEqual(q["Fields"], "ProviderIds")
    }

    func test_showIdentityKeys_batchesAtFourHundredIds() async {
        server.respond(items, body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = await provider().showIdentityKeys(for: (1...950).map(String.init))
        let sizes = server.requests.map { query($0)["Ids"]!.split(separator: ",").count }
        XCTAssertEqual(sizes, [400, 400, 150])
    }

    func test_showIdentityKeys_failureIsEmptyNotAThrow() async {
        let keys = await provider().showIdentityKeys(for: ["1"])
        XCTAssertEqual(keys, [:])
    }

    // MARK: - Watch state

    func test_markPlayed_andUnplayed() async throws {
        server.respond("/Users/\(uid)/PlayedItems/166", method: "POST", body: #"{"Played":true}"#)
        server.respond("/Users/\(uid)/PlayedItems/166", method: "DELETE", body: #"{"Played":false}"#)
        let p = provider()
        try await p.markPlayed(ref("166"))
        try await p.markUnplayed(ref("166"))
        XCTAssertEqual(server.requests.map { $0.httpMethod }, ["POST", "DELETE"])
    }

    private func routeMovieRuntime() {
        server.respond("\(items)/166", body: EmbyBrowseFixtures.movieDetail)
        server.respond("\(items)/166/UserData", method: "POST", status: 204)
    }

    func test_updateProgress_writesPositionAndPlayedTogether() async throws {
        routeMovieRuntime()
        try await provider().updateProgress(ref("166"), position: 300)
        let post = try XCTUnwrap(server.requests.firstIndex { $0.httpMethod == "POST" })
        let body = server.jsonBody(post)
        XCTAssertEqual(body["PlaybackPositionTicks"] as? Int64, 3_000_000_000)
        XCTAssertEqual(body["Played"] as? Bool, false, "a position-only body would wipe Played")
        XCTAssertEqual(Set(body.keys), ["PlaybackPositionTicks", "Played"])
    }

    func test_updateProgress_pastNinetyPercent_isPlayedWithNoResumePoint() async throws {
        routeMovieRuntime()
        try await provider().updateProgress(ref("166"), position: 1100)
        let body = server.jsonBody(try XCTUnwrap(server.requests.firstIndex { $0.httpMethod == "POST" }))
        XCTAssertEqual(body["Played"] as? Bool, true)
        XCTAssertEqual(body["PlaybackPositionTicks"] as? Int64, 0)
    }

    func test_updateProgress_underTheFloor_andZero_writeNothing() async throws {
        routeMovieRuntime()
        let p = provider()
        try await p.updateProgress(ref("166"), position: 5)
        try await p.updateProgress(ref("166"), position: 0)
        XCTAssertTrue(server.requests.filter { $0.httpMethod == "POST" }.isEmpty)
    }

    func test_progressUpdate_withoutARuntime_keepsThePosition() {
        let update = EmbyProvider.progressUpdate(position: 12, runtime: nil)
        XCTAssertEqual(update?.playbackPositionTicks, 120_000_000)
        XCTAssertEqual(update?.played, false)
        XCTAssertNil(EmbyProvider.progressUpdate(position: .nan, runtime: 100), "a NaN position is not a position")
    }

    func test_removeFromContinueWatching_hidesTheResumeEntry_notAPositionOfZero() async throws {
        server.respond("\(items)/54/HideFromResume", method: "POST", body: #"{"Played":false}"#)
        let episode = try XCTUnwrap(try EmbyTestJSON.items(EmbyBrowseFixtures.resume).first)
        let item = EmbyMediaMapper.item(episode, providerID: "emby:srv", baseURL: EmbyBrowseFixtures.baseURL)
        let p = provider()
        XCTAssertTrue(p.canRemoveFromContinueWatching(item), "an episode is a next-up entry, still removable")
        try await p.removeFromContinueWatching(item)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url?.path, "\(items)/54/HideFromResume")
        XCTAssertEqual(query(request)["Hide"], "true")
        XCTAssertEqual(server.requests.count, 1, "no UserData write")
    }

    // MARK: - Admin

    func test_canRefreshMetadata_followsTheAdminPolicy() async {
        var admin = EmbySession.Policy()
        admin.isAdministrator = true
        let isAdmin = await provider(policy: admin).canRefreshMetadata()
        let isUser = await provider().canRefreshMetadata()
        XCTAssertTrue(isAdmin)
        XCTAssertFalse(isUser)
    }

    func test_policy_liveReadWinsAndIsReadOnce() async throws {
        server.respond("/Users/\(uid)", body: EmbyLiveFixtures.userAdmin4_10_2)
        let p = provider()
        let first = await p.canRefreshMetadata()
        let second = await p.canDeleteMedia()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(server.requests.count, 1)
    }

    func test_policy_nonAdminLiveRead() async {
        server.respond("/Users/\(uid)", body: EmbyLiveFixtures.userNonAdmin4_10_2)
        var stored = EmbySession.Policy()
        stored.isAdministrator = true
        let p = provider(policy: stored)
        let canRefresh = await p.canRefreshMetadata()
        XCTAssertFalse(canRefresh, "the server's answer outranks the sign-in policy")
    }

    func test_refreshMetadata_adminPostsTheMeasuredQuery() async throws {
        var admin = EmbySession.Policy()
        admin.isAdministrator = true
        server.respond("/Items/166/Refresh", method: "POST", status: 204)
        try await provider(policy: admin).refreshMetadata(ref("166"))
        let refresh = try XCTUnwrap(server.requests.first { $0.url!.path == "/Items/166/Refresh" })
        let q = query(refresh)
        XCTAssertEqual(q["MetadataRefreshMode"], "FullRefresh")
        XCTAssertEqual(q["ImageRefreshMode"], "FullRefresh")
        XCTAssertEqual(q["Recursive"], "false")
        XCTAssertEqual(q["ReplaceAllMetadata"], "false")
    }

    func test_refreshMetadata_nonAdminIsRefusedBeforeAnyRefresh() async {
        server.respond("/Items/166/Refresh", method: "POST", status: 204)
        do {
            try await provider().refreshMetadata(ref("166"))
            XCTFail("the server accepts a non-admin refresh silently, so the client must refuse")
        } catch {
            XCTAssertFalse(paths().contains("/Items/166/Refresh"))
        }
    }

    func test_canDeleteMedia_policyMatrix() async {
        var admin = EmbySession.Policy(); admin.isAdministrator = true
        var deleter = EmbySession.Policy(); deleter.enableContentDeletion = true
        var folders = EmbySession.Policy(); folders.enableContentDeletionFromFolders = ["3"]
        let results = [await provider(policy: admin).canDeleteMedia(), await provider(policy: deleter).canDeleteMedia(),
                       await provider(policy: folders).canDeleteMedia(), await provider().canDeleteMedia()]
        XCTAssertEqual(results, [true, true, true, false])
    }

    /// The DELETE itself was never run against real media.
    func test_deleteMedia_needsThePerItemCanDelete_unverified() async throws {
        server.respond("\(items)/166", body: EmbyBrowseFixtures.movieDetail)
        server.respond("/Items/166", method: "DELETE", status: 204)
        try await provider().deleteMedia(ref("166"))
        XCTAssertEqual(server.requests.last?.httpMethod, "DELETE")

        server.reset()
        server.respond("\(items)/166", body: EmbyBrowseFixtures.movieDetail.replacingOccurrences(of: #""CanDelete":true"#, with: #""CanDelete":false"#))
        server.respond("/Items/166", method: "DELETE", status: 204)
        do {
            try await provider().deleteMedia(ref("166"))
            XCTFail("CanDelete is false for this item")
        } catch {
            XCTAssertNil(server.requests.first { $0.httpMethod == "DELETE" })
        }
    }

    func test_unauthorizedToken_surfacesAsUnauthorized() async {
        server.respond("/Users/\(uid)/Views", status: 401, body: EmbyLiveFixtures.invalidTokenBody, contentType: "text/plain")
        do {
            _ = try await provider().libraries()
            XCTFail()
        } catch MediaProviderError.unauthorized {
        } catch {
            XCTFail("\(error)")
        }
    }
}
