// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProviderStage3aDefaultsTests.swift
//  RivuletTests
//
//  What a provider that adopts none of the stage 3a members answers, and the
//  model defaults that keep existing constructors compiling.
//

import XCTest
@testable import Rivulet

final class MediaProviderStage3aDefaultsTests: XCTestCase {
    private let library = MediaLibrary(id: "1", providerID: "stub", title: "L", kind: .movies)

    func test_hub_defaultsToNoPagingAndNotPromoted() {
        let hub = MediaHub(id: "h", providerID: "stub", title: "H", style: .shelf, items: [])
        XCTAssertNil(hub.pagingKey)
        XCTAssertFalse(hub.isPromoted)
    }

    func test_library_defaultsToPinned() {
        XCTAssertTrue(library.isPinnedToHome)
    }

    func test_item_defaultsToNoGenresOrIDs() {
        let item = JellyfinFixtures.mediaItem("a")
        XCTAssertNil(item.genres)
        XCTAssertNil(item.externalIDs)
    }

    func test_itemKeepsGenresAndIDsThroughLogoSplice() throws {
        let item = MediaItem(
            ref: MediaItemRef(providerID: "stub", itemID: "a"), kind: .movie, title: "a", sortTitle: nil, overview: nil,
            year: nil, runtime: nil, parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil,
            genres: ["Drama"], externalIDs: ["tmdb": "1"])
        let spliced = item.withLogoIfMissing(URL(string: "http://x/logo.png"))
        XCTAssertEqual(spliced.genres, ["Drama"])
        XCTAssertEqual(spliced.externalIDs, ["tmdb": "1"])
    }

    func test_itemDecodesFromBeforeTheNewFields() throws {
        let item = JellyfinFixtures.mediaItem("a")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json["genres"] = nil
        json["externalIDs"] = nil
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.ref, item.ref)
    }

    func test_hubPage_defaultIsTheRowAsOnePage() async throws {
        let stub = StubMediaProvider()
        let row = MediaHub(id: "h", providerID: "stub", title: "H", style: .shelf, items: [JellyfinFixtures.mediaItem("a")])
        let first = try await stub.hubPage(row, page: Page(offset: 0, limit: 24))
        XCTAssertEqual(first.items.map(\.ref.itemID), ["a"])
        XCTAssertNil(first.nextPage)
        let later = try await stub.hubPage(row, page: Page(offset: 24, limit: 24))
        XCTAssertTrue(later.items.isEmpty)
    }

    func test_unwatchedFilter_defaultFallsBackWhenOffAndRefusesWhenOn() async throws {
        let stub = StubMediaProvider()
        let plain = try await stub.items(in: library, sort: .titleAsc, unwatchedOnly: false, page: Page(offset: 0, limit: 10))
        XCTAssertEqual(plain.total, 0)
        do {
            _ = try await stub.items(in: library, sort: .titleAsc, unwatchedOnly: true, page: Page(offset: 0, limit: 10))
            XCTFail("a provider that cannot filter must not pretend")
        } catch is MediaProviderError {}
    }

    func test_ownedItems_defaultIsNone() async throws {
        let owned = try await StubMediaProvider().ownedItems(
            matching: [TitleMatch(kind: .movie, externalIDs: ["tmdb": "1"], plexGUID: nil)], limit: 10)
        XCTAssertTrue(owned.isEmpty)
    }

    func test_imageURL_defaultIsTheUrlAsIs() throws {
        let url = try XCTUnwrap(URL(string: "http://x/a.jpg"))
        XCTAssertEqual(StubMediaProvider().imageURL(url, width: 10, height: 10), url)
    }

    func test_logoURL_defaultReadsTheItemsOwnArtwork() async throws {
        func item(kind: MediaKind, own: String?, parent: String?, grandparent: String?) -> MediaItem {
            func art(_ s: String?) -> MediaArtwork {
                MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: s.flatMap(URL.init(string:)))
            }
            return MediaItem(
                ref: MediaItemRef(providerID: "stub", itemID: "a"), kind: kind, title: "a", sortTitle: nil, overview: nil,
                year: nil, runtime: nil, parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
                childProgress: nil,
                userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                artwork: art(own), parentArtwork: parent.map { art($0) }, grandparentArtwork: grandparent.map { art($0) })
        }
        let stub = StubMediaProvider()
        let movie = await stub.logoURL(for: item(kind: .movie, own: "http://x/own", parent: nil, grandparent: nil))
        XCTAssertEqual(movie?.absoluteString, "http://x/own")
        let episode = await stub.logoURL(for: item(kind: .episode, own: "http://x/own", parent: "http://x/season", grandparent: "http://x/show"))
        XCTAssertEqual(episode?.absoluteString, "http://x/show")
        let season = await stub.logoURL(for: item(kind: .season, own: nil, parent: "http://x/show", grandparent: nil))
        XCTAssertEqual(season?.absoluteString, "http://x/show")
        let bare = await stub.logoURL(for: item(kind: .episode, own: "http://x/own", parent: nil, grandparent: nil))
        XCTAssertEqual(bare?.absoluteString, "http://x/own")
    }

    func test_titleMatch_fromTrendingIsTmdbOnlyWithItsKind() {
        let movie = TMDBListItem(id: 603, title: "", overview: nil, posterPath: nil, backdropPath: nil,
                                 releaseDate: nil, voteAverage: nil, mediaType: .movie)
        let show = TMDBListItem(id: 1396, title: "", overview: nil, posterPath: nil, backdropPath: nil,
                                releaseDate: nil, voteAverage: nil, mediaType: .tv)
        XCTAssertEqual(TitleMatch(movie), TitleMatch(kind: .movie, externalIDs: ["tmdb": "603"], plexGUID: nil))
        XCTAssertEqual(TitleMatch(show), TitleMatch(kind: .show, externalIDs: ["tmdb": "1396"], plexGUID: nil))
    }

    func test_titleMatch_matchesAnySharedIdOnTheSameKind() {
        let title = TitleMatch(kind: .movie, externalIDs: ["tmdb": "1", "imdb": "tt9"], plexGUID: nil)
        XCTAssertTrue(title.matches(kind: .movie, ids: ["imdb": "tt9"]))
        XCTAssertFalse(title.matches(kind: .show, ids: ["tmdb": "1"]))
        XCTAssertFalse(title.matches(kind: .movie, ids: ["tmdb": "2"]))
        XCTAssertFalse(title.matches(kind: .movie, ids: [:]))
    }
}
