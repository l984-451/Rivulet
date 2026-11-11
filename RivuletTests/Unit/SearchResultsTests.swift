// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SearchResultsTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class SearchResultsTests: XCTestCase {
    private func item(_ id: String, _ kind: MediaKind, provider: String) -> MediaItem {
        JellyfinFixtures.mediaItem(id, kind: kind, providerID: provider)
    }

    func test_search_asksEveryProvider_inOrder_titlesOnly_eachOnce() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.searchItems = [item("m1", .movie, provider: "plex:a"), item("c1", .collection, provider: "plex:a"),
                            item("m1", .movie, provider: "plex:a")]
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.searchItems = [item("s1", .show, provider: "jellyfin:s")]

        let results = try await SearchResults.search("x", providers: [plex, jf])

        XCTAssertEqual(results.titles.map(\.ref.itemID), ["m1", "s1"])
    }

    func test_search_aFailingServerOnlyLosesItsOwnResults() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.searchError = MediaProviderError.unreachable
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.searchItems = [item("s1", .show, provider: "jellyfin:s")]
        let results = try await SearchResults.search("x", providers: [plex, jf])
        XCTAssertEqual(results.titles.map(\.ref.itemID), ["s1"])
    }

    func test_search_throwsOnlyWhenEveryServerFails() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.searchError = MediaProviderError.unreachable
        do {
            _ = try await SearchResults.search("x", providers: [plex])
            XCTFail("expected a throw")
        } catch {}
    }

    func test_groups_oneServer_isByKind() {
        let results = [item("e1", .episode, provider: "plex:a"), item("m1", .movie, provider: "plex:a"),
                       item("s1", .show, provider: "plex:a"), item("n1", .season, provider: "plex:a")]
        let groups = SearchResults.groups(SearchHits(titles: results), scope: .all, providerOrder: ["plex:a"])
        XCTAssertEqual(groups.map(\.section), [.movies, .shows, .episodes])
        XCTAssertEqual(groups[1].items.map(\.ref.itemID), ["s1", "n1"])
        XCTAssertTrue(groups.allSatisfy { $0.providerID == nil })
    }

    func test_groups_severalServers_areByServerThenKind() {
        let results = [item("j1", .movie, provider: "jellyfin:s"), item("p1", .movie, provider: "plex:a"),
                       item("p2", .episode, provider: "plex:a")]
        let groups = SearchResults.groups(SearchHits(titles: results), scope: .all, providerOrder: ["plex:a", "jellyfin:s"])
        XCTAssertEqual(groups.map { "\($0.providerID ?? "-")/\($0.section)" }, ["plex:a/movies", "plex:a/episodes", "jellyfin:s/movies"])
    }

    func test_scope_filters() {
        let results = [item("m", .movie, provider: "plex:a"), item("s", .show, provider: "plex:a"), item("e", .episode, provider: "plex:a")]
        let hits = SearchHits(titles: results)
        XCTAssertEqual(SearchResults.groups(hits, scope: .movies, providerOrder: ["plex:a"]).flatMap(\.items).map(\.ref.itemID), ["m"])
        XCTAssertEqual(SearchResults.groups(hits, scope: .shows, providerOrder: ["plex:a"]).flatMap(\.items).map(\.ref.itemID), ["s", "e"])
    }

    // MARK: - Shelves and people

    private func person(_ name: String, provider: String) -> MediaPerson {
        MediaPerson(id: name, name: name, role: nil, imageURL: nil, providerID: provider)
    }

    func test_groups_order_titlesThenShelvesThenPeopleThenEpisodes() {
        let hits = SearchHits(
            titles: [item("e", .episode, provider: "plex:a"), item("m", .movie, provider: "plex:a")],
            people: [person("Al", provider: "plex:a")],
            shelves: [SearchShelf(kind: .collection, name: "Christmas", items: [item("c", .movie, provider: "plex:a")]),
                      SearchShelf(kind: .genre, name: "Holiday", items: [item("g", .movie, provider: "plex:a")])])
        let groups = SearchResults.groups(hits, scope: .all, providerOrder: ["plex:a"])
        XCTAssertEqual(groups.map(\.section), [.movies, .collection("Christmas"), .genre("Holiday"), .people, .episodes])
        XCTAssertEqual(groups[3].people.map(\.name), ["Al"])
    }

    func test_shelves_dropTitlesShownAbove_andEmptiedShelves() {
        let shared = item("m", .movie, provider: "plex:a")
        let hits = SearchHits(
            titles: [shared],
            shelves: [SearchShelf(kind: .collection, name: "A", items: [shared, item("x", .movie, provider: "plex:a")]),
                      SearchShelf(kind: .genre, name: "B", items: [item("x", .movie, provider: "plex:a")])])
        let groups = SearchResults.groups(hits, scope: .all, providerOrder: ["plex:a"])
        XCTAssertEqual(groups.map(\.section), [.movies, .collection("A")])
        XCTAssertEqual(groups[1].items.map(\.ref.itemID), ["x"])
    }

    func test_people_onlyUnderAll_andShelvesFollowScope() {
        let hits = SearchHits(
            people: [person("Al", provider: "plex:a")],
            shelves: [SearchShelf(kind: .genre, name: "G", items: [item("s", .show, provider: "plex:a")])])
        XCTAssertEqual(SearchResults.groups(hits, scope: .movies, providerOrder: ["plex:a"]).map(\.section), [])
        XCTAssertEqual(SearchResults.groups(hits, scope: .shows, providerOrder: ["plex:a"]).map(\.section), [.genre("G")])
    }

    func test_people_groupPerServer_withSeveralServers() {
        let hits = SearchHits(people: [person("A", provider: "plex:a"), person("B", provider: "jellyfin:s")])
        let groups = SearchResults.groups(hits, scope: .all, providerOrder: ["plex:a", "jellyfin:s"])
        XCTAssertEqual(groups.map { "\($0.providerID ?? "-")/\($0.people.map(\.name))" },
                       ["plex:a/[\"A\"]", "jellyfin:s/[\"B\"]"])
    }
}
