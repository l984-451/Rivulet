// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchStateRoutingTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class WatchStateRoutingTests: XCTestCase {
    private let plex = StubMediaProvider(id: "plex:a", kind: .plex)
    private let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)

    private func lookup(_ id: String) -> (any MediaProvider)? { [plex, jf].first { $0.id == id } }

    func test_markPlayed_reachesEveryCopyOfAMergedCard() async throws {
        let card = JellyfinFixtures.mediaItem("a", providerID: "plex:a")
        let copy = JellyfinFixtures.mediaItem("b", providerID: "jellyfin:s")

        try await WatchStateRouting.setPlayed(true, item: card, copies: [copy], provider: lookup)

        XCTAssertEqual(plex.markedPlayed.map(\.itemID), ["a"])
        XCTAssertEqual(jf.markedPlayed.map(\.itemID), ["b"])
    }

    func test_markUnplayed_touchesOnlyTheCard() async throws {
        let card = JellyfinFixtures.mediaItem("a", providerID: "plex:a")
        let copy = JellyfinFixtures.mediaItem("b", providerID: "jellyfin:s")

        try await WatchStateRouting.setPlayed(false, item: card, copies: [copy], provider: lookup)

        XCTAssertEqual(plex.markedUnplayed.map(\.itemID), ["a"])
        XCTAssertTrue(jf.markedUnplayed.isEmpty)
    }

    func test_aCopyThatFailsDoesNotFailTheCard() async throws {
        jf.markPlayedError = MediaProviderError.unreachable
        let card = JellyfinFixtures.mediaItem("a", providerID: "plex:a")
        let copy = JellyfinFixtures.mediaItem("b", providerID: "jellyfin:s")
        try await WatchStateRouting.setPlayed(true, item: card, copies: [copy], provider: lookup)
        XCTAssertEqual(plex.markedPlayed.map(\.itemID), ["a"])
    }

    func test_theCardsOwnFailureThrows() async {
        plex.markPlayedError = MediaProviderError.unreachable
        let card = JellyfinFixtures.mediaItem("a", providerID: "plex:a")
        do {
            try await WatchStateRouting.setPlayed(true, item: card, copies: [], provider: lookup)
            XCTFail("expected a throw")
        } catch {}
    }

    func test_aProviderThatIsGoneThrows() async {
        let card = JellyfinFixtures.mediaItem("a", providerID: "emby:gone")
        do {
            try await WatchStateRouting.setPlayed(true, item: card, copies: [], provider: lookup)
            XCTFail("expected a throw")
        } catch {}
    }
}
