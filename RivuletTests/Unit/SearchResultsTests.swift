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

        XCTAssertEqual(results.map(\.ref.itemID), ["m1", "s1"])
    }

    func test_search_aFailingServerOnlyLosesItsOwnResults() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.searchError = MediaProviderError.unreachable
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.searchItems = [item("s1", .show, provider: "jellyfin:s")]
        let results = try await SearchResults.search("x", providers: [plex, jf])
        XCTAssertEqual(results.map(\.ref.itemID), ["s1"])
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
        let groups = SearchResults.groups(results, scope: .all, providerOrder: ["plex:a"])
        XCTAssertEqual(groups.map(\.section), [.movies, .shows, .episodes])
        XCTAssertEqual(groups[1].items.map(\.ref.itemID), ["s1", "n1"])
        XCTAssertTrue(groups.allSatisfy { $0.providerID == nil })
    }

    func test_groups_severalServers_areByServerThenKind() {
        let results = [item("j1", .movie, provider: "jellyfin:s"), item("p1", .movie, provider: "plex:a"),
                       item("p2", .episode, provider: "plex:a")]
        let groups = SearchResults.groups(results, scope: .all, providerOrder: ["plex:a", "jellyfin:s"])
        XCTAssertEqual(groups.map { "\($0.providerID ?? "-")/\($0.section)" }, ["plex:a/movies", "plex:a/episodes", "jellyfin:s/movies"])
    }

    func test_scope_filters() {
        let results = [item("m", .movie, provider: "plex:a"), item("s", .show, provider: "plex:a"), item("e", .episode, provider: "plex:a")]
        XCTAssertEqual(SearchResults.groups(results, scope: .movies, providerOrder: ["plex:a"]).flatMap(\.items).map(\.ref.itemID), ["m"])
        XCTAssertEqual(SearchResults.groups(results, scope: .shows, providerOrder: ["plex:a"]).flatMap(\.items).map(\.ref.itemID), ["s", "e"])
    }
}
