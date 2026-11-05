// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbySeamTests.swift
//  RivuletTests
//
//  The seam members iOS needed (stage 3a) on Emby: hub paging, the unwatched
//  filter, owned-by-id lookup, sized images, show logos, and the list item's
//  genres and external ids. Replies are hand-built from the shapes in EmbyBrowseFixtures.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbySeamTests: XCTestCase {
    private let server = FakeEmbyServer()
    private let uid = EmbyLiveFixtures.userID
    private var items: String { "/Users/\(uid)/Items" }
    private let movies = MediaLibrary(id: "3", providerID: "emby:srv", title: "Movies", kind: .movies)
    private let shows = MediaLibrary(id: "5", providerID: "emby:srv", title: "TV", kind: .shows)

    private func provider() -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: uid, policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: EmbyBrowseFixtures.baseURL, token: "tok", transport: server.transport))
    }

    private func query(_ request: URLRequest) -> [String: String] {
        queryDict(request.url!)
    }

    private func queryDict(_ url: URL) -> [String: String] {
        let pairs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    override func tearDown() async throws {
        XCTAssertEqual(server.headerProblems, [])
        try await super.tearDown()
    }

    // MARK: - Hub paging

    func test_recentlyAddedHub_pagesThroughTheLibrarysItemsNewestFirst() async throws {
        server.respond("\(items)/Latest", body: #"[{"Id":"9","Name":"X","Type":"Movie"}]"#)
        let added = try await provider().recentlyAddedHub(in: movies)
        let hub = try XCTUnwrap(added)
        XCTAssertNotNil(hub.pagingKey)

        server.respond(items, body: #"{"Items":[{"Id":"10","Name":"Y","Type":"Movie"}],"TotalRecordCount":60}"#)
        let page = try await provider().hubPage(hub, page: Page(offset: 24, limit: 24))
        XCTAssertEqual(page.items.map(\.ref.itemID), ["10"])
        XCTAssertEqual(page.total, 60)
        XCTAssertEqual(page.nextPage, Page(offset: 48, limit: 24))
        let request = try XCTUnwrap(server.requests.last)
        let q = query(request)
        XCTAssertEqual(request.url?.path, items)
        XCTAssertEqual(q["ParentId"], "3")
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["IncludeItemTypes"], "Movie")
        XCTAssertEqual(q["SortBy"], "DateCreated,SortName")
        XCTAssertEqual(q["SortOrder"], "Descending,Ascending")
        XCTAssertEqual(q["StartIndex"], "24")
        XCTAssertEqual(q["Limit"], "24")
        XCTAssertNil(q["GroupItemsIntoCollections"])
    }

    func test_showsPageAsSeries() async throws {
        server.respond("\(items)/Latest", body: #"[{"Id":"9","Name":"X","Type":"Series"}]"#)
        let added = try await provider().recentlyAddedHub(in: shows)
        let hub = try XCTUnwrap(added)
        server.respond(items, body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider().hubPage(hub, page: Page(offset: 0, limit: 24))
        XCTAssertEqual(query(try XCTUnwrap(server.requests.last))["IncludeItemTypes"], "Series")
    }

    func test_hubPage_aRowWithoutAKeyIsOnePage() async throws {
        let row = MediaHub(id: "h", providerID: "emby:srv", title: "H", style: .shelf, items: [JellyfinFixtures.mediaItem("a")])
        let page = try await provider().hubPage(row, page: Page(offset: 0, limit: 24))
        XCTAssertEqual(page.items.map(\.ref.itemID), ["a"])
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: - Unwatched filter

    func test_items_unwatchedOnlySendsIsUnplayed() async throws {
        server.respond(items, body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider().items(in: movies, sort: .titleAsc, unwatchedOnly: true, page: Page(offset: 0, limit: 50))
        XCTAssertEqual(query(server.requests[0])["Filters"], "IsUnplayed")
        XCTAssertEqual(query(server.requests[0])["ParentId"], "3")
    }

    func test_items_defaultSendsNoFilter() async throws {
        server.respond(items, body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider().items(in: movies, sort: .titleAsc, page: Page(offset: 0, limit: 50))
        XCTAssertNil(query(server.requests[0])["Filters"])
    }

    // MARK: - Owned by id

    func test_ownedItems_asksEachVideoLibraryForTheIdsAndKeepsTitleOrder() async throws {
        server.respond("/Users/\(uid)/Views", body: """
            {"Items":[{"Id":"3","Name":"Movies","Type":"CollectionFolder","CollectionType":"movies"},
                      {"Id":"5","Name":"TV","Type":"CollectionFolder","CollectionType":"tvshows"},
                      {"Id":"7","Name":"Music","Type":"CollectionFolder","CollectionType":"music"}]}
            """)
        server.respond(items, query: ["ParentId": "3"], body: """
            {"Items":[{"Id":"100","Name":"Up","Type":"Movie","ProviderIds":{"Tmdb":"14160"}}],"TotalRecordCount":1}
            """)
        server.respond(items, query: ["ParentId": "5"], body: """
            {"Items":[{"Id":"200","Name":"Abbott","Type":"Series","ProviderIds":{"IMDB":"tt1"}}],"TotalRecordCount":1}
            """)
        let titles = [TitleMatch(kind: .show, externalIDs: ["imdb": "tt1", "tmdb": "5"], plexGUID: nil),
                      TitleMatch(kind: .movie, externalIDs: ["tmdb": "14160"], plexGUID: nil)]
        let owned = try await provider().ownedItems(matching: titles, limit: 10)
        XCTAssertEqual(owned.map(\.ref.itemID), ["200", "100"], "title order, case-insensitive provider ids")
        let asked = server.requests.filter { $0.url?.path == items }
        XCTAssertEqual(asked.count, 2, "no request for the music library")
        let q = query(asked[0])
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["IncludeItemTypes"], "Movie,Series")
        XCTAssertEqual(q["AnyProviderIdEquals"], "imdb.tt1,tmdb.5,tmdb.14160")
        XCTAssertTrue(q["Fields"]?.contains("ProviderIds") == true)
    }

    // MARK: - Image sizing

    func test_imageURL_fitsTheBoxWithMaxWidthAndHeight() throws {
        let art = try XCTUnwrap(EmbyMediaMapper.imageURL(EmbyBrowseFixtures.baseURL, itemID: EmbyID("166"), type: "Primary", tag: "abc"))
        let sized = provider().imageURL(art, width: 180, height: 270)
        XCTAssertEqual(sized.path, "/Items/166/Images/Primary")
        XCTAssertEqual(queryDict(sized), ["Tag": "abc", "MaxWidth": "180", "MaxHeight": "270"])
    }

    func test_imageURL_leavesAForeignUrlAlone() throws {
        let foreign = try XCTUnwrap(URL(string: "https://image.tmdb.org/t/p/w500/a.jpg"))
        XCTAssertEqual(provider().imageURL(foreign, width: 180, height: 270), foreign)
    }

    // MARK: - Show logos

    private func decode(_ json: String) -> EmbyItem {
        try! EmbyJSON.decoder().decode(EmbyItem.self, from: Data(json.utf8))
    }

    private var episodeJSON: String {
        #"{"Id":"ep1","Name":"Pilot","Type":"Episode","SeriesId":"show1","SeasonId":"season1","ParentLogoItemId":"show1","ParentLogoImageTag":"logoTag","SeriesPrimaryImageTag":"showPrim"}"#
    }

    func test_episodeCarriesItsShowsLogo() {
        let item = EmbyMediaMapper.item(decode(episodeJSON), providerID: "emby:srv", baseURL: EmbyBrowseFixtures.baseURL)
        XCTAssertEqual(item.grandparentArtwork?.logo?.path, "/Items/show1/Images/Logo")
    }

    func test_logoURL_usesTheShowsLogoWithoutARequest() async {
        let episode = EmbyMediaMapper.item(decode(episodeJSON), providerID: "emby:srv", baseURL: EmbyBrowseFixtures.baseURL)
        let url = await provider().logoURL(for: episode)
        XCTAssertEqual(url?.path, "/Items/show1/Images/Logo")
        let season = EmbyMediaMapper.item(
            decode(#"{"Id":"season1","Name":"S1","Type":"Season","SeriesId":"show1","ParentLogoItemId":"show1","ParentLogoImageTag":"logoTag","SeriesPrimaryImageTag":"showPrim"}"#),
            providerID: "emby:srv", baseURL: EmbyBrowseFixtures.baseURL)
        let seasonLogo = await provider().logoURL(for: season)
        XCTAssertEqual(seasonLogo?.path, "/Items/show1/Images/Logo")
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: - Library pin, genres and ids

    func test_library_isPinnedToHome() {
        let view = decode(#"{"Id":"3","Name":"Movies","Type":"CollectionFolder","CollectionType":"movies"}"#)
        XCTAssertEqual(EmbyMediaMapper.library(view, providerID: "emby:srv")?.isPinnedToHome, true)
    }

    func test_item_carriesGenresAndExternalIDsWhateverTheirCase() {
        let dto = decode(#"{"Id":"1","Name":"X","Type":"Movie","Genres":["Drama","Crime"],"ProviderIds":{"Tmdb":"603","IMDB":"tt1"}}"#)
        let item = EmbyMediaMapper.item(dto, providerID: "emby:srv", baseURL: EmbyBrowseFixtures.baseURL)
        XCTAssertEqual(item.genres, ["Drama", "Crime"])
        XCTAssertEqual(item.externalIDs, ["tmdb": "603", "imdb": "tt1"])
    }

    func test_item_withoutThemHasNone() {
        let item = EmbyMediaMapper.item(decode(#"{"Id":"1","Name":"X","Type":"Movie","ProviderIds":{}}"#),
                                        providerID: "emby:srv", baseURL: EmbyBrowseFixtures.baseURL)
        XCTAssertNil(item.genres)
        XCTAssertNil(item.externalIDs)
    }

    func test_listCalls_askForGenresAndProviderIds() async throws {
        server.respond(items, body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider().items(in: movies, sort: .titleAsc, page: Page(offset: 0, limit: 50))
        let fields = Set((query(server.requests[0])["Fields"] ?? "").split(separator: ",").map(String.init))
        XCTAssertTrue(fields.isSuperset(of: ["Genres", "ProviderIds"]), "\(fields)")
    }
}
