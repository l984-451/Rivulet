// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ContinueWatchingRowTests: XCTestCase {
    func test_catalogMovieWithoutIDsMergesAfterIdentityResolution() async throws {
        let suite = "ContinueWatchingRowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let row = ContinueWatchingRow(defaults: defaults)
        let resolved = expectation(description: "Catalog identity resolved")
        row.fetchIdentityKeys = { _, ids in
            Dictionary(uniqueKeysWithValues: ids.map { ($0, ["m:tmdb:42"]) })
        }
        row.onResolved = { resolved.fulfill() }

        var plex = JellyfinFixtures.mediaItem("plex-copy", providerID: "plex:primary")
        plex.identity = ["m:tmdb:42"]
        plex.userState.lastViewedAt = Date(timeIntervalSince1970: 100)
        let dto = try SiloJSON.decoder().decode(SiloItem.self, from: Data(
            #"{"content_id":"movie:localized","type":"movie","title":"Un titre traduit"}"#.utf8))
        var silo = SiloMediaMapper.item(dto, providerID: "silo:server:profile", baseURL: URL(string: "https://silo.invalid")!)
        silo.userState.lastViewedAt = Date(timeIntervalSince1970: 200)
        let rows = [[plex], [silo]]

        let pending = row.cards(rows, identity: { $0.identity ?? [] }, lookupKey: \.lookupKey,
                                watched: \.userState.lastViewedAt)
        XCTAssertEqual(pending.map(\.item.ref), [plex.ref], "Do not flash a duplicate while the native movie lacks ids")
        await row.resolveIdentities(in: rows, lookupKey: \.lookupKey)
        await fulfillment(of: [resolved], timeout: 2)
        let cards = row.cards(rows, identity: { $0.identity ?? [] }, lookupKey: \.lookupKey,
                              watched: \.userState.lastViewedAt)
        XCTAssertEqual(cards.map(\.item.ref), [silo.ref])
        XCTAssertEqual(cards.first?.others.map(\.ref), [plex.ref])
    }

    func test_episodeOwnTMDBIDCannotMergeWithMovieUsingSameNumber() async throws {
        let suite = "ContinueWatchingRowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let row = ContinueWatchingRow(defaults: defaults)
        let resolved = expectation(description: "Owning series identity resolved")
        row.fetchIdentityKeys = { _, ids in
            Dictionary(uniqueKeysWithValues: ids.map { ($0, ["s:tmdb:999"]) })
        }
        row.onResolved = { resolved.fulfill() }
        var movie = JellyfinFixtures.mediaItem("movie", providerID: "plex:primary")
        movie.identity = ["m:tmdb:42"]
        let dto = try SiloJSON.decoder().decode(SiloItem.self, from: Data(
            #"{"content_id":"episode:one","type":"episode","title":"Episode","tmdb_id":"42","series_id":"series:one","season_number":1,"episode_number":1}"#.utf8))
        let episode = SiloMediaMapper.item(dto, providerID: "silo:server:profile", baseURL: URL(string: "https://silo.invalid")!)
        let rows = [[movie], [episode]]
        _ = row.cards(rows, identity: { $0.identity ?? [] }, lookupKey: \.lookupKey,
                      watched: \.userState.lastViewedAt)
        await fulfillment(of: [resolved], timeout: 2)
        let cards = row.cards(rows, identity: { $0.identity ?? [] }, lookupKey: \.lookupKey,
                              watched: \.userState.lastViewedAt)
        XCTAssertEqual(Set(cards.map(\.item.ref)), Set([movie.ref, episode.ref]))
        XCTAssertTrue(cards.allSatisfy { $0.others.isEmpty })
    }

    func test_missingResolverKeepsUnidentifiedMoviesVisibleWithoutMerging() throws {
        let suite = "ContinueWatchingRowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let row = ContinueWatchingRow(defaults: defaults)
        var first = JellyfinFixtures.mediaItem("first", providerID: "plex:first")
        var second = JellyfinFixtures.mediaItem("second", providerID: "silo:server:profile")
        first.identity = nil
        second.identity = nil
        let cards = row.cards([[first], [second]], identity: { $0.identity ?? [] }, lookupKey: \.lookupKey,
                              watched: \.userState.lastViewedAt)
        XCTAssertEqual(Set(cards.map(\.item.ref)), Set([first.ref, second.ref]))
        XCTAssertTrue(cards.allSatisfy { $0.others.isEmpty })
    }
}
