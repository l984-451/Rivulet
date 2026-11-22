// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexWatchlistServiceTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class PlexWatchlistServiceTests: XCTestCase {

    func testOptimisticAddRevertsOnFailure() async {
        let api = StubWatchlistAPI()
        api.shouldFailWrites = true

        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.add(guid: "tmdb://1", item: makeItem(id: "1"))

        // After failure, the GUID should not be in the set.
        XCTAssertFalse(service.watchlistGUIDs.contains("tmdb://1"))
    }

    func testOptimisticAddPersistsOnSuccess() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())

        await service.add(guid: "tmdb://1", item: makeItem(id: "1"))

        XCTAssertTrue(service.watchlistGUIDs.contains("tmdb://1"))
        XCTAssertEqual(service.watchlistItems.count, 1)
    }

    func testOptimisticRemovePutsItBackOnFailure() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.add(guid: "tmdb://1", item: makeItem(id: "1"))

        api.shouldFailWrites = true
        await service.remove(guid: "tmdb://1")

        XCTAssertTrue(service.watchlistGUIDs.contains("tmdb://1"))
        XCTAssertEqual(service.watchlistItems.count, 1)
    }

    func testFetchWatchlistPopulatesState() async {
        let api = StubWatchlistAPI()
        api.fetchResult = [makeItem(id: "9", guid: "tmdb://9")]

        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.fetchWatchlist()

        XCTAssertEqual(service.watchlistItems.count, 1)
        XCTAssertTrue(service.watchlistGUIDs.contains("tmdb://9"))
    }

    func testConcurrentFetchesShareOneRequest() async {
        let api = StubWatchlistAPI()
        api.fetchResult = [makeItem(id: "9", guid: "tmdb://9")]
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())

        async let first: Void = service.fetchWatchlist()
        async let second: Void = service.fetchWatchlist()
        _ = await (first, second)

        XCTAssertEqual(api.fetchAllCalls, 1)
    }

    func testUnchangedHeadSkipsTheFullList() async {
        let api = StubWatchlistAPI()
        api.fetchResult = [makeItem(id: "9", guid: "tmdb://9")]
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache(), staleAfter: 0)
        await service.fetchWatchlist()

        api.headResult = (1, "9")
        await service.fetchWatchlist()
        XCTAssertEqual(api.fetchAllCalls, 1, "same count and newest entry: no full fetch")

        api.headResult = (2, "10")
        await service.fetchWatchlist()
        XCTAssertEqual(api.fetchAllCalls, 2, "a new entry: full fetch")
    }

    func testContainsTmdbIdMatchesGuid() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.add(guid: "tmdb://42", item: makeItem(id: "42", guid: "tmdb://42"))

        XCTAssertTrue(service.contains(tmdbId: 42))
        XCTAssertFalse(service.contains(tmdbId: 43))
    }

    /// The Watchlist is the account's: a Home profile with no account token
    /// must not see the cached copy or fetch a fresh one.
    func testNoAccountToken_paintsNoCacheAndFetchesNothing() async {
        final class StoredCache: WatchlistCacheProtocol {
            let items: [PlexWatchlistItem]
            init(_ items: [PlexWatchlistItem]) { self.items = items }
            func load() -> [PlexWatchlistItem]? { items }
            func save(_ items: [PlexWatchlistItem]) {}
            func clear() {}
        }
        let api = StubWatchlistAPI()
        api.fetchResult = [makeItem(id: "9", guid: "tmdb://9")]

        let service = PlexWatchlistService(
            api: api, cache: StoredCache([makeItem(id: "1")]), tokenProvider: { nil })
        XCTAssertTrue(service.watchlistItems.isEmpty)

        await service.fetchWatchlist(force: true)
        XCTAssertTrue(service.watchlistItems.isEmpty)
        XCTAssertTrue(service.watchlistGUIDs.isEmpty)
    }

    func testResetClearsState() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        await service.add(guid: "tmdb://1", item: makeItem(id: "1"))

        service.reset()

        XCTAssertTrue(service.watchlistItems.isEmpty)
        XCTAssertTrue(service.watchlistGUIDs.isEmpty)
    }

    func testRemoveClearsAllGuidsForItem() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())

        let multiGuidItem = PlexWatchlistItem(
            id: "1",
            title: "Multi",
            year: 2024,
            type: .movie,
            posterURL: nil,
            guids: ["tmdb://42", "imdb://tt123", "tvdb://999"]
        )
        await service.add(guid: "tmdb://42", item: multiGuidItem)
        XCTAssertTrue(service.watchlistGUIDs.contains("imdb://tt123"))

        await service.remove(guid: "tmdb://42")

        XCTAssertFalse(service.watchlistGUIDs.contains("tmdb://42"))
        XCTAssertFalse(service.watchlistGUIDs.contains("imdb://tt123"))
        XCTAssertFalse(service.watchlistGUIDs.contains("tvdb://999"))
        XCTAssertTrue(service.watchlistItems.isEmpty)
    }

    /// A show's tmdb id is also a valid tmdb MOVIE id, so the write has to say
    /// which one it means or Discover can match an unrelated film (issue #269).
    func testWriteCarriesTheItemType() async {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        let show = PlexWatchlistItem(
            id: "s", title: "Married at First Sight", year: 2014,
            type: .show, posterURL: nil, guids: ["tmdb://61888"]
        )

        await service.add(guid: "tmdb://61888", item: show)
        XCTAssertEqual(api.lastAddType, .show)

        await service.remove(guid: "tmdb://61888")
        XCTAssertEqual(api.lastRemoveType, .show)
    }

    // MARK: - TMDB titles (Discover on iOS and Mac)

    func testTMDBEntryCarriesTitleYearTypePosterAndGuid() throws {
        let title = tmdbTitle(603, .movie, date: "1999-03-31", poster: "/p.jpg")
        let movie = try XCTUnwrap(PlexWatchlistItem(tmdb: title))
        XCTAssertNotNil(title.artwork.poster)
        XCTAssertEqual(movie, PlexWatchlistItem(id: "tmdb://603", title: "Title 603", year: 1999, type: .movie,
                                                posterURL: title.artwork.poster, guids: ["tmdb://603"]))

        let show = try XCTUnwrap(PlexWatchlistItem(tmdb: tmdbTitle(1399, .tv)))
        XCTAssertEqual(show.type, .show)
        XCTAssertEqual(show.guids, ["tmdb://1399"])
        XCTAssertNil(show.year)
        XCTAssertNil(show.posterURL)
    }

    func testSetListedAddsAndRemovesATMDBTitle() async throws {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        let show = tmdbTitle(1399, .tv)

        try await service.setListed(true, tmdb: show)
        XCTAssertTrue(service.contains(tmdbId: 1399))
        XCTAssertEqual(api.lastAddType, .show, "a show's tmdb id is also a movie's (#269)")

        try await service.setListed(false, tmdb: show)
        XCTAssertFalse(service.contains(tmdbId: 1399))
        XCTAssertEqual(api.lastRemoveType, .show)
    }

    /// Show 1399 on the list says nothing about movie 1399: adding the movie still writes.
    func testSetListedTellsAMovieFromAShowWithTheSameTMDBNumber() async throws {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        try await service.setListed(true, tmdb: tmdbTitle(1399, .tv))
        XCTAssertFalse(service.isListed(tmdb: tmdbTitle(1399, .movie)))

        try await service.setListed(true, tmdb: tmdbTitle(1399, .movie))
        XCTAssertEqual(api.lastAddType, .movie)
        XCTAssertTrue(service.isListed(tmdb: tmdbTitle(1399, .movie)))
    }

    func testSetListedAlreadyInThatStateWritesNothing() async throws {
        let api = StubWatchlistAPI()
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())
        try await service.setListed(false, tmdb: tmdbTitle(550, .movie))
        XCTAssertNil(api.lastRemoveType)
        XCTAssertNil(api.lastAddType)
    }

    /// The service reverts a refused write without throwing; the caller still has to hear about it.
    func testSetListedThrowsWhenPlexRefuses() async {
        let api = StubWatchlistAPI()
        api.shouldFailWrites = true
        let service = PlexWatchlistService(api: api, cache: NullWatchlistCache())

        do {
            try await service.setListed(true, tmdb: tmdbTitle(603, .movie))
            XCTFail("a refused add must throw")
        } catch {}
        XCTAssertFalse(service.contains(tmdbId: 603))
    }

    private func tmdbTitle(_ id: Int, _ type: TMDBMediaType, date: String? = nil, poster: String? = nil) -> MediaItem {
        TMDBMediaMapper.item(TMDBListItem(id: id, title: "Title \(id)", overview: nil, posterPath: poster, backdropPath: nil,
                                          releaseDate: date, voteAverage: nil, mediaType: type))
    }

    private func makeItem(id: String, guid: String = "tmdb://1") -> PlexWatchlistItem {
        PlexWatchlistItem(
            id: id,
            title: "Test",
            year: 2024,
            type: .movie,
            posterURL: nil,
            guids: [guid]
        )
    }
}

// MARK: - Stubs

final class StubWatchlistAPI: PlexWatchlistAPIProtocol, @unchecked Sendable {
    var shouldFailWrites = false
    var fetchResult: [PlexWatchlistItem] = []
    var headResult: (totalSize: Int, newestID: String?)?
    var fetchAllCalls = 0

    func fetchAll(token: String) async throws -> [PlexWatchlistItem] {
        fetchAllCalls += 1
        try? await Task.sleep(for: .milliseconds(20))
        return fetchResult
    }

    func head(token: String) async throws -> (totalSize: Int, newestID: String?) {
        guard let headResult else { throw URLError(.badServerResponse) }
        return headResult
    }

    /// Types the service passed through on the last write — the Discover match
    /// is wrong without them (see PlexWatchlistAPI.resolveDiscoverRatingKey).
    var lastAddType: PlexWatchlistItem.WatchlistType?
    var lastRemoveType: PlexWatchlistItem.WatchlistType?

    func add(guids: [String], type: PlexWatchlistItem.WatchlistType?, token: String) async throws {
        lastAddType = type
        if shouldFailWrites { throw URLError(.notConnectedToInternet) }
    }

    func remove(guid: String, type: PlexWatchlistItem.WatchlistType?, token: String) async throws {
        lastRemoveType = type
        if shouldFailWrites { throw URLError(.notConnectedToInternet) }
    }
}

final class NullWatchlistCache: WatchlistCacheProtocol {
    func load() -> [PlexWatchlistItem]? { nil }
    func save(_ items: [PlexWatchlistItem]) {}
    func clear() {}
}
