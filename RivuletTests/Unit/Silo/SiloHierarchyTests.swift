// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloHierarchyTests: XCTestCase {
    func test_allEpisodesFlattensEverySeasonAndPreservesOpaqueParents() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/catalog/items/show-a", [.init(body: """
        {"content_id":"show-a","type":"series","title":"A Show"}
        """)])
        await server.respond("GET", "/api/v2/catalog/series/show-a/seasons", [.init(body: """
        {"items":[
          {"content_id":"opaque-season-x","season_number":1,"title":"Season 1"},
          {"content_id":"opaque-season-z","season_number":3,"title":"Season 3"}
        ]}
        """)])
        await server.respond("GET", "/api/v2/catalog/items/opaque-season-x/episodes", [.init(body: """
        {"items":[
          {"content_id":"episode-a","title":"First","season_number":1,"episode_number":1},
          {"content_id":"episode-b","title":"Second","season_number":1,"episode_number":2}
        ]}
        """)])
        await server.respond("GET", "/api/v2/catalog/items/opaque-season-z/episodes", [.init(body: """
        {"items":[{"content_id":"episode-c","title":"Third","season_number":3,"episode_number":1}]}
        """)])
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, transport: server.transport)
        let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
        let show = MediaItemRef(providerID: provider.id, itemID: "show-a")

        let episodes = try await provider.allEpisodes(of: show)

        XCTAssertEqual(episodes.map(\.ref.itemID), ["episode-a", "episode-b", "episode-c"],
                       "Up Next must continue into later seasons, not call the season-only endpoint with a show id")
        XCTAssertEqual(episodes.map(\.parentRef?.itemID), ["opaque-season-x", "opaque-season-x", "opaque-season-z"])
        XCTAssertTrue(episodes.allSatisfy { $0.kind == .episode && $0.grandparentRef == show && $0.seriesTitle == "A Show" })
    }

    func test_episodeDetailResolvesOpaqueSeasonForNextEpisodePlayback() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/catalog/items/episode-a", [.init(body: """
        {"content_id":"episode-a","type":"episode","title":"First",
         "series_id":"show-a","series_title":"A Show","season_number":4,"episode_number":1}
        """)])
        await server.respond("GET", "/api/v2/catalog/series/show-a/seasons/4", [.init(body: """
        {"content_id":"opaque-season-z","season_number":4,"title":"Season 4"}
        """)])
        await server.respond("GET", "/api/v2/catalog/items/opaque-season-z", [.init(body: """
        {"content_id":"opaque-season-z","type":"season","title":"Season 4",
         "series_id":"show-a","series_title":"A Show","season_number":4}
        """)])
        await server.respond("GET", "/api/v2/catalog/series/show-a/seasons/4/episodes", [.init(body: """
        {"items":[
          {"content_id":"episode-a","title":"First","season_number":4,"episode_number":1},
          {"content_id":"episode-b","title":"Second","season_number":4,"episode_number":2}
        ]}
        """)])
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, transport: server.transport)
        let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
        let detail = try await provider.fullDetail(for: MediaItemRef(providerID: provider.id, itemID: "episode-a"))
        let season = try XCTUnwrap(detail.item.parentRef)
        let episodes = try await provider.children(of: season)

        let next = UniversalPlayerViewModel.nextEpisode(after: detail.item, in: episodes, nextSeasonEpisodes: nil)

        XCTAssertEqual(next?.ref, MediaItemRef(providerID: provider.id, itemID: "episode-b"),
                       "A fresh episode detail, not just a season listing, must support the player's Up Next lookup")
    }
}
