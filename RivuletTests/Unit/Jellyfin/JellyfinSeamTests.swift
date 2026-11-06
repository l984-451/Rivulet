// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinSeamTests.swift
//  RivuletTests
//
//  The seam members iOS needed (stage 3a) on Jellyfin: hub paging, the
//  unwatched filter, owned-by-id lookup, sized images, show logos, and the list
//  item's genres and external ids.
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinSeamTests: XCTestCase {
    private let server = FakeJellyfinServer()
    private let movies = MediaLibrary(id: "lib-m", providerID: "jellyfin:srv", title: "Movies", kind: .movies)
    private let shows = MediaLibrary(id: "lib-tv", providerID: "jellyfin:srv", title: "TV", kind: .shows)

    private func provider(now: @escaping @Sendable () -> Date = { Date() }) -> JellyfinProvider {
        JellyfinProvider(
            serverID: "srv", displayName: "NAS", userID: "user-1",
            client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok", transport: server.transport),
            now: now)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    private func dict(_ index: Int) -> [String: String] {
        Dictionary(server.query(index).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    private func queryDict(_ url: URL) -> [String: String] {
        let pairs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Hub paging

    func test_recentlyAddedHub_pagesThroughTheLibrarysItemsNewestFirst() async throws {
        server.respond("/Items/Latest", body: #"[{"Id":"m2","Name":"X","Type":"Movie"}]"#)
        let added = try await provider().recentlyAddedHub(in: movies)
        let hub = try XCTUnwrap(added)
        let key = try XCTUnwrap(hub.pagingKey)

        server.respond("/Items", body: #"{"Items":[{"Id":"m3","Name":"Y","Type":"Movie"}],"TotalRecordCount":60}"#)
        let page = try await provider().hubPage(hub, page: Page(offset: 24, limit: 24))
        XCTAssertEqual(page.items.map(\.ref.itemID), ["m3"])
        XCTAssertEqual(page.total, 60)
        XCTAssertEqual(page.nextPage, Page(offset: 48, limit: 24))
        let q = dict(1)
        XCTAssertEqual(server.requests[1].url?.path, "/Items")
        XCTAssertEqual(q["parentId"], "lib-m")
        XCTAssertEqual(q["recursive"], "true")
        XCTAssertEqual(q["includeItemTypes"], "Movie")
        XCTAssertEqual(q["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(q["sortOrder"], "Descending")
        XCTAssertEqual(q["startIndex"], "24")
        XCTAssertEqual(q["limit"], "24")
        XCTAssertEqual(q["enableTotalRecordCount"], "true")
        XCTAssertFalse(key.contains("startIndex"), "the key is the row's definition, not a page")
    }

    /// Measured on 12.1: a TV library's `Items/Latest` row holds episodes, so its See All pages episodes.
    func test_recentlyAddedHub_tvLibraryPagesEpisodesNewestFirst() async throws {
        server.respond("/Items/Latest", body: #"[{"Id":"s1","Name":"X","Type":"Series"}]"#)
        let added = try await provider().recentlyAddedHub(in: shows)
        let hub = try XCTUnwrap(added)
        server.respond("/Items", body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider().hubPage(hub, page: Page(offset: 0, limit: 24))
        XCTAssertEqual(dict(1)["includeItemTypes"], "Episode")
        XCTAssertEqual(dict(1)["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(dict(1)["sortOrder"], "Descending")
    }

    func test_hubsInLibrary_continueWatchingDoesNotPage_recentlyAddedDoes() async throws {
        server.respond("/UserItems/Resume", body: #"{"Items":[{"Id":"m1","Name":"A","Type":"Movie"}],"TotalRecordCount":1}"#)
        server.respond("/Shows/NextUp", body: #"{"Items":[],"TotalRecordCount":0}"#)
        server.respond("/Items/Latest", body: #"[{"Id":"m2","Name":"B","Type":"Movie"}]"#)
        let hubs = try await provider().hubs(in: movies)
        XCTAssertEqual(hubs.map(\.id), ["lib-m.continueWatching", "lib-m.recentlyAdded"])
        XCTAssertNil(hubs[0].pagingKey)
        XCTAssertNotNil(hubs[1].pagingKey)
    }

    func test_hubPage_aRowWithoutAKeyIsOnePage() async throws {
        let row = MediaHub(id: "h", providerID: "jellyfin:srv", title: "H", style: .shelf,
                           items: [JellyfinFixtures.mediaItem("a")])
        let page = try await provider().hubPage(row, page: Page(offset: 0, limit: 24))
        XCTAssertEqual(page.items.map(\.ref.itemID), ["a"])
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: - Unwatched filter

    func test_items_unwatchedOnlySendsIsUnplayed() async throws {
        server.respond("/Items", body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider().items(in: movies, sort: .titleAsc, unwatchedOnly: true, page: Page(offset: 0, limit: 50))
        XCTAssertEqual(dict(0)["filters"], "IsUnplayed")
        XCTAssertEqual(dict(0)["parentId"], "lib-m")
    }

    func test_items_defaultSendsNoFilter() async throws {
        server.respond("/Items", body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider().items(in: movies, sort: .titleAsc, page: Page(offset: 0, limit: 50))
        XCTAssertNil(dict(0)["filters"])
    }

    // MARK: - Owned by id

    func test_ownedItems_listsProviderIdsThenFetchesTheMatchesInTitleOrder() async throws {
        server.respond("/Items", query: ["fields": "ProviderIds"], body: """
            {"Items":[{"Id":"up","Type":"Movie","ProviderIds":{"Tmdb":"14160"}},
                      {"Id":"abbott","Type":"Series","ProviderIds":{"Tvdb":"9","Imdb":"tt1"}},
                      {"Id":"none","Type":"Movie","ProviderIds":{}}],"TotalRecordCount":3}
            """)
        server.respond("/Items", query: ["ids": "abbott,up"], body: """
            {"Items":[{"Id":"up","Name":"Up","Type":"Movie"},{"Id":"abbott","Name":"Abbott","Type":"Series"}]}
            """)
        let titles = [TitleMatch(kind: .show, externalIDs: ["imdb": "tt1"], plexGUID: nil),
                      TitleMatch(kind: .movie, externalIDs: ["tmdb": "14160"], plexGUID: nil),
                      // A show with a movie's number is another title.
                      TitleMatch(kind: .show, externalIDs: ["tmdb": "14160"], plexGUID: nil)]
        let items = try await provider().ownedItems(matching: titles, limit: 10)
        XCTAssertEqual(items.map(\.ref.itemID), ["abbott", "up"])
        XCTAssertEqual(dict(0)["recursive"], "true")
        XCTAssertEqual(dict(0)["includeItemTypes"], "Movie,Series")
        XCTAssertNil(dict(0)["parentId"], "server-wide")
    }

    private let ownedIndex = """
        {"Items":[{"Id":"up","Type":"Movie","ProviderIds":{"Tmdb":"14160"}}],"TotalRecordCount":1}
        """

    private func idIndexRequests() -> Int {
        server.requests.filter { $0.url?.query?.contains("fields=ProviderIds") == true }.count
    }

    func test_ownedItems_theIdIndexIsKeptForTenMinutes() async throws {
        server.respond("/Items", query: ["fields": "ProviderIds"], body: ownedIndex)
        server.respond("/Items", query: ["ids": "up"], body: #"{"Items":[{"Id":"up","Name":"Up","Type":"Movie"}]}"#)
        let clock = Clock()
        let p = provider(now: { clock.now })
        let titles = [TitleMatch(kind: .movie, externalIDs: ["tmdb": "14160"], plexGUID: nil)]
        _ = try await p.ownedItems(matching: titles, limit: 10)
        clock.advance(599)
        let again = try await p.ownedItems(matching: titles, limit: 10)
        XCTAssertEqual(again.map(\.ref.itemID), ["up"])
        XCTAssertEqual(idIndexRequests(), 1, "the catalog listing is not asked again inside the window")
        // A call whose titles match nothing makes no request at all.
        let before = server.requests.count
        _ = try await p.ownedItems(matching: [TitleMatch(kind: .movie, externalIDs: ["tmdb": "2"], plexGUID: nil)], limit: 10)
        XCTAssertEqual(server.requests.count, before)
        clock.advance(2)
        _ = try await p.ownedItems(matching: titles, limit: 10)
        XCTAssertEqual(idIndexRequests(), 2, "listed again after ten minutes")
    }

    func test_ownedItems_aFailedListingIsNotKept() async throws {
        let p = provider()
        let titles = [TitleMatch(kind: .movie, externalIDs: ["tmdb": "14160"], plexGUID: nil)]
        do { _ = try await p.ownedItems(matching: titles, limit: 10); XCTFail("expected a throw") } catch {}
        server.respond("/Items", query: ["fields": "ProviderIds"], body: ownedIndex)
        server.respond("/Items", query: ["ids": "up"], body: #"{"Items":[{"Id":"up","Name":"Up","Type":"Movie"}]}"#)
        let items = try await p.ownedItems(matching: titles, limit: 10)
        XCTAssertEqual(items.map(\.ref.itemID), ["up"])
    }

    func test_ownedItems_concurrentCallsShareOneListing() async throws {
        server.respond("/Items", query: ["fields": "ProviderIds"], body: ownedIndex)
        server.respond("/Items", query: ["ids": "up"], body: #"{"Items":[{"Id":"up","Name":"Up","Type":"Movie"}]}"#)
        let p = provider()
        let titles = [TitleMatch(kind: .movie, externalIDs: ["tmdb": "14160"], plexGUID: nil)]
        async let a = p.ownedItems(matching: titles, limit: 10)
        async let b = p.ownedItems(matching: titles, limit: 10)
        _ = try await (a, b)
        XCTAssertEqual(idIndexRequests(), 1)
    }

    func test_ownedItems_nothingMatchedSkipsTheSecondRequest() async throws {
        server.respond("/Items", body: #"{"Items":[{"Id":"up","Type":"Movie","ProviderIds":{"Tmdb":"1"}}]}"#)
        let items = try await provider().ownedItems(
            matching: [TitleMatch(kind: .movie, externalIDs: ["tmdb": "2"], plexGUID: nil)], limit: 10)
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(server.requests.count, 1)
    }

    // MARK: - Image sizing

    func test_imageURL_fillsTheBoxOnThisServersImages() throws {
        let art = try XCTUnwrap(JellyfinMediaMapper.imageURL(JellyfinFixtures.baseURL, itemID: "m1", type: "Primary", tag: "abc"))
        let sized = provider().imageURL(art, width: 180, height: 270)
        XCTAssertEqual(sized.path, "/Items/m1/Images/Primary")
        XCTAssertEqual(queryDict(sized), ["tag": "abc", "fillWidth": "180", "fillHeight": "270"])
        XCTAssertNil(queryDict(sized)["api_key"], "images stay anonymous")
    }

    func test_imageURL_leavesAForeignUrlAlone() throws {
        let foreign = try XCTUnwrap(URL(string: "https://image.tmdb.org/t/p/w500/a.jpg"))
        XCTAssertEqual(provider().imageURL(foreign, width: 180, height: 270), foreign)
    }

    // MARK: - Show logos

    func test_episodeCarriesItsShowsLogo() {
        let dto: JFItem = JellyfinFixtures.decode(JellyfinFixtures.episode)
        let item = JellyfinMediaMapper.item(dto, providerID: "jellyfin:srv", baseURL: JellyfinFixtures.baseURL)
        XCTAssertEqual(item.grandparentArtwork?.logo?.path, "/Items/show1/Images/Logo")
    }

    func test_logoURL_episodeAndSeasonUseTheShowsLogo() async throws {
        let dto: JFItem = JellyfinFixtures.decode(JellyfinFixtures.episode)
        let episode = JellyfinMediaMapper.item(dto, providerID: "jellyfin:srv", baseURL: JellyfinFixtures.baseURL)
        let url = await provider().logoURL(for: episode)
        XCTAssertEqual(url?.path, "/Items/show1/Images/Logo")
        let season: JFItem = JellyfinFixtures.decode(
            #"{"Id":"season1","Name":"Season 1","Type":"Season","SeriesId":"show1","IndexNumber":1,"ParentLogoItemId":"show1","ParentLogoImageTag":"showLogo","ParentPrimaryImageItemId":"show1","ParentPrimaryImageTag":"showPrim"}"#)
        let seasonItem = JellyfinMediaMapper.item(season, providerID: "jellyfin:srv", baseURL: JellyfinFixtures.baseURL)
        let seasonLogo = await provider().logoURL(for: seasonItem)
        XCTAssertEqual(seasonLogo?.path, "/Items/show1/Images/Logo")
        XCTAssertTrue(server.requests.isEmpty, "the list response already says")
    }

    // MARK: - Library pin, genres and ids

    func test_library_isPinnedToHome() throws {
        let view: JFItem = JellyfinFixtures.decode(#"{"Id":"a","Name":"Movies","CollectionType":"movies"}"#)
        XCTAssertEqual(JellyfinMediaMapper.library(view, providerID: "jellyfin:srv")?.isPinnedToHome, true)
    }

    func test_item_carriesGenresAndExternalIDs() {
        let dto: JFItem = JellyfinFixtures.decode(JellyfinFixtures.series)
        let item = JellyfinMediaMapper.item(dto, providerID: "jellyfin:srv", baseURL: JellyfinFixtures.baseURL)
        XCTAssertEqual(item.genres, ["Drama"])
        XCTAssertEqual(item.externalIDs, ["tmdb": "1396", "imdb": "tt0903747"])
    }

    func test_item_withoutThemHasNone() {
        let dto: JFItem = JellyfinFixtures.decode(JellyfinFixtures.movie)
        let item = JellyfinMediaMapper.item(dto, providerID: "jellyfin:srv", baseURL: JellyfinFixtures.baseURL)
        XCTAssertNil(item.genres)
        XCTAssertNil(item.externalIDs)
    }

    func test_listCalls_askForGenresAndProviderIds() async throws {
        server.respond("/Items", body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider().items(in: movies, sort: .titleAsc, page: Page(offset: 0, limit: 50))
        let fields = Set((dict(0)["fields"] ?? "").split(separator: ",").map(String.init))
        XCTAssertTrue(fields.isSuperset(of: ["Genres", "ProviderIds"]), "\(fields)")
    }
}
