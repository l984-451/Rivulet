// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProviderSeasonOrderTests.swift
//  RivuletTests
//
//  Issue #534: Plex lists a show's Specials before Season 1; the provider
//  lists them after the last season, and the flat episode list follows.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlexProviderSeasonOrderTests: XCTestCase {

    private final class StubNetwork: PlexNetworkManager, @unchecked Sendable {
        var children: [String: [PlexMetadata]] = [:]
        var leaves: [String: [PlexMetadata]] = [:]

        override func getChildren(serverURL: String, authToken: String, ratingKey: String) async throws -> [PlexMetadata] {
            children[ratingKey] ?? []
        }

        override func getAllLeaves(serverURL: String, authToken: String, ratingKey: String) async throws -> [PlexMetadata] {
            leaves[ratingKey] ?? []
        }
    }

    private func makeProvider(_ network: StubNetwork) -> PlexProvider {
        PlexProvider(
            machineIdentifier: "test", displayName: "Test",
            serverURL: "http://plex.test", authToken: "t",
            networkManager: network
        )
    }

    private func ref(_ id: String) -> MediaItemRef {
        MediaItemRef(providerID: "plex:test", itemID: id)
    }

    private func season(_ key: String, index: Int) -> PlexMetadata {
        var meta = PlexMetadata()
        meta.ratingKey = key
        meta.type = "season"
        meta.index = index
        meta.parentRatingKey = "show"
        return meta
    }

    private func episode(_ key: String, season: Int, index: Int) -> PlexMetadata {
        var meta = PlexMetadata()
        meta.ratingKey = key
        meta.type = "episode"
        meta.index = index
        meta.parentIndex = season
        meta.parentRatingKey = "s\(season)"
        meta.grandparentRatingKey = "show"
        return meta
    }

    func testShowSeasonsListSpecialsLast() async throws {
        let network = StubNetwork()
        network.children["show"] = [season("s0", index: 0), season("s1", index: 1), season("s2", index: 2)]

        let seasons = try await makeProvider(network).children(of: ref("show"))

        XCTAssertEqual(seasons.map(\.ref.itemID), ["s1", "s2", "s0"])
    }

    func testAllEpisodesListSpecialsLast() async throws {
        let network = StubNetwork()
        network.leaves["show"] = [
            episode("sp1", season: 0, index: 1),
            episode("e1", season: 1, index: 1), episode("e2", season: 1, index: 2),
            episode("e3", season: 2, index: 1),
        ]

        let episodes = try await makeProvider(network).allEpisodes(of: ref("show"))

        XCTAssertEqual(episodes.map(\.ref.itemID), ["e1", "e2", "e3", "sp1"])
    }

    func testSeasonEpisodesKeepTheirOrder() async throws {
        // A season's own episodes are never reordered, the Specials season's included.
        let network = StubNetwork()
        network.children["s0"] = [episode("sp1", season: 0, index: 1), episode("sp2", season: 0, index: 2)]

        let episodes = try await makeProvider(network).children(of: ref("s0"))

        XCTAssertEqual(episodes.map(\.ref.itemID), ["sp1", "sp2"])
    }
}
