// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryFilterTests.swift
//  RivuletTests
//
//  Library filters (#326): the query each server is sent for Genre, Decade and
//  Unwatched, and how each server's genre and year lists become options.
//

import XCTest
@testable import Rivulet

@MainActor
final class LibraryFilterTests: XCTestCase {

    private let filter = LibraryFilter(genre: LibraryGenre(id: "g1", name: "Action"), decade: 1990, unwatchedOnly: true)

    private func library(_ kind: MediaLibrary.LibraryKind, id: String, providerID: String) -> MediaLibrary {
        MediaLibrary(id: id, providerID: providerID, title: "L", kind: kind)
    }

    private func queryDict(_ url: URL?) -> [String: String] {
        let pairs = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    private func dict(_ items: [URLQueryItem]) -> [String: String] {
        Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Value

    func test_filterIsActiveOnlyWithAChoice() {
        XCTAssertFalse(LibraryFilter.none.isActive)
        XCTAssertTrue(LibraryFilter(unwatchedOnly: true).isActive)
        XCTAssertTrue(LibraryFilter(decade: 2000).isActive)
    }

    func test_decadeYearsSpanTenYears() {
        XCTAssertEqual(LibraryFilter(decade: 1990).decadeYears, Array(1990...1999))
        XCTAssertEqual(LibraryFilter.none.decadeYears, [])
    }

    func test_decadesFromYearsAreNewestFirstAndUnique() {
        XCTAssertEqual(LibraryFilterOptions.decades(fromYears: [1991, 1997, 2005, 2025, 0]), [2020, 2000, 1990])
    }

    // MARK: - Plex

    func test_plex_filterQuery() {
        XCTAssertEqual(dict(PlexProvider.filterQuery(filter)), ["unwatched": "1", "genre": "g1", "decade": "1990"])
        XCTAssertEqual(PlexProvider.filterQuery(.none), [])
    }

    func test_plex_filterValuesDecodeStringOrNumericKeys() throws {
        let json = #"{"MediaContainer":{"Directory":[{"key":"28","title":"Action"},{"key":1990,"title":"1990s"}]}}"#
        let values = try JSONDecoder().decode(PlexFilterValueContainer.self, from: Data(json.utf8)).MediaContainer.Directory
        XCTAssertEqual(values, [PlexFilterValue(key: "28", title: "Action"), PlexFilterValue(key: "1990", title: "1990s")])
    }

    func test_plex_optionsSortDecadesNewestFirst() {
        let options = LibraryFilterOptions(
            plexGenres: [PlexFilterValue(key: "28", title: "Action")],
            decades: [PlexFilterValue(key: "1990", title: "1990s"), PlexFilterValue(key: "2010", title: "2010s")])
        XCTAssertEqual(options.genres, [LibraryGenre(id: "28", name: "Action")])
        XCTAssertEqual(options.decades, [2010, 1990])
    }

    private final class StubNetwork: PlexNetworkManager, @unchecked Sendable {
        var filters: [URLQueryItem] = []
        var size = 0
        var start = -1

        override func getLibraryItemsWithTotal(
            serverURL: String, authToken: String, sectionId: String, start: Int, size: Int, sort: String?,
            type: Int?, includeGuids: Bool, followCollectionMode: Bool, filters: [URLQueryItem]
        ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
            self.filters = filters
            self.start = start
            self.size = size
            return ([], 0)
        }
    }

    func test_plex_itemsSendsTheFilterWithStartAndSize() async throws {
        let network = StubNetwork()
        let provider = PlexProvider(machineIdentifier: "test", displayName: "Test", serverURL: "http://plex.test",
                                    authToken: "t", networkManager: network)
        _ = try await provider.items(in: library(.movies, id: "1", providerID: "plex:test"), sort: .titleAsc,
                                     filter: filter, page: Page(offset: 90, limit: 90))
        XCTAssertEqual(dict(network.filters), ["unwatched": "1", "genre": "g1", "decade": "1990"])
        XCTAssertEqual(network.start, 90, "Plex ignores the size without a start")
        XCTAssertEqual(network.size, 90)
    }

    func test_plex_pageURLCarriesGenreAndDecade() {
        let url = PlexNetworkManager.libraryItemsURL(
            serverURL: "http://plex.test", sectionId: "1", start: 0, size: 90, filters: PlexProvider.filterQuery(filter))
        let q = queryDict(url)
        XCTAssertEqual(url?.path, "/library/sections/1/all")
        XCTAssertEqual(q["genre"], "g1")
        XCTAssertEqual(q["decade"], "1990")
        XCTAssertEqual(q["X-Plex-Container-Start"], "0")
    }

    // MARK: - Jellyfin

    private let jellyfinServer = FakeJellyfinServer()

    private func jellyfin() -> JellyfinProvider {
        JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "user-1",
                         client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok",
                                                transport: jellyfinServer.transport))
    }

    func test_jellyfin_filterQuery() {
        XCTAssertEqual(dict(JellyfinProvider.filterQuery(filter)),
                       ["filters": "IsUnplayed", "genreIds": "g1",
                        "years": "1990,1991,1992,1993,1994,1995,1996,1997,1998,1999"])
        XCTAssertEqual(JellyfinProvider.filterQuery(.none), [])
    }

    func test_jellyfin_itemsSendsTheFilter() async throws {
        jellyfinServer.respond("/Items", body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await jellyfin().items(in: library(.movies, id: "lib-m", providerID: "jellyfin:srv"), sort: .titleAsc,
                                       filter: filter, page: Page(offset: 0, limit: 90))
        let q = queryDict(jellyfinServer.requests.first?.url)
        XCTAssertEqual(q["parentId"], "lib-m")
        XCTAssertEqual(q["genreIds"], "g1")
        XCTAssertEqual(q["years"]?.hasPrefix("1990,"), true)
        XCTAssertEqual(q["filters"], "IsUnplayed")
    }

    func test_jellyfin_optionsReadGenresAndYears() async throws {
        jellyfinServer.respond("/Genres", body: #"{"Items":[{"Id":"g1","Name":"Action"},{"Id":"g2","Name":"Comedy"}],"TotalRecordCount":2}"#)
        jellyfinServer.respond("/Items/Filters", body: #"{"Genres":["Action"],"Years":[1991,1997,2005,2025]}"#)
        let options = try await jellyfin().filterOptions(in: library(.movies, id: "lib-m", providerID: "jellyfin:srv"))
        XCTAssertEqual(options.genres, [LibraryGenre(id: "g1", name: "Action"), LibraryGenre(id: "g2", name: "Comedy")])
        XCTAssertEqual(options.decades, [2020, 2000, 1990])
        for request in jellyfinServer.requests {
            let q = queryDict(request.url)
            XCTAssertEqual(q["parentId"], "lib-m")
            XCTAssertEqual(q["includeItemTypes"], "Movie")
        }
    }

    // MARK: - Emby

    private let embyServer = FakeEmbyServer()
    private var embyItems: String { "/Users/\(EmbyLiveFixtures.userID)/Items" }

    private func emby() -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: EmbyLiveFixtures.userID, policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: EmbyBrowseFixtures.baseURL, token: "tok", transport: embyServer.transport))
    }

    override func tearDown() async throws {
        XCTAssertEqual(embyServer.headerProblems, [])
        try await super.tearDown()
    }

    func test_emby_filterQuery() {
        XCTAssertEqual(dict(EmbyProvider.filterQuery(filter)),
                       ["Filters": "IsUnplayed", "GenreIds": "g1",
                        "Years": "1990,1991,1992,1993,1994,1995,1996,1997,1998,1999"])
        XCTAssertEqual(EmbyProvider.filterQuery(.none), [])
    }

    func test_emby_itemsSendsTheFilter() async throws {
        embyServer.respond(embyItems, body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await emby().items(in: library(.shows, id: "5", providerID: "emby:srv"), sort: .titleAsc,
                                   filter: filter, page: Page(offset: 0, limit: 90))
        let q = queryDict(embyServer.requests.first?.url)
        XCTAssertEqual(q["ParentId"], "5")
        XCTAssertEqual(q["IncludeItemTypes"], "Series")
        XCTAssertEqual(q["GenreIds"], "g1")
        XCTAssertEqual(q["Filters"], "IsUnplayed")
    }

    /// Emby answers `Years` with `{"Name":"1991"}` rows alone and has no `Items/Filters` (404 on 4.10).
    func test_emby_optionsReadGenresAndYears() async throws {
        embyServer.respond("/Genres", body: #"{"Items":[{"Id":"12","Name":"Action","Type":"Genre"}],"TotalRecordCount":1}"#)
        embyServer.respond("/Years", body: #"{"Items":[{"Name":"1991"},{"Name":"2013"}],"TotalRecordCount":2}"#)
        let options = try await emby().filterOptions(in: library(.movies, id: "3", providerID: "emby:srv"))
        XCTAssertEqual(options.genres, [LibraryGenre(id: "12", name: "Action")])
        XCTAssertEqual(options.decades, [2010, 1990])
        XCTAssertEqual(Set(embyServer.requests.map { $0.url?.path ?? "" }), ["/Genres", "/Years"])
    }

    // MARK: - Default

    func test_providerWithoutFilterSupportRefusesAFilterButNotNone() async throws {
        let stub = StubMediaProvider()
        let lib = library(.movies, id: "1", providerID: "stub")
        _ = try await stub.items(in: lib, sort: .titleAsc, filter: .none, page: Page(offset: 0, limit: 10))
        do {
            _ = try await stub.items(in: lib, sort: .titleAsc, filter: filter, page: Page(offset: 0, limit: 10))
            XCTFail("a provider that cannot filter must not pretend to")
        } catch {}
        let options = try await stub.filterOptions(in: lib)
        XCTAssertEqual(options, LibraryFilterOptions())
    }
}
