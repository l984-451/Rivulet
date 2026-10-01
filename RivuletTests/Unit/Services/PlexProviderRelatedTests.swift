// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProviderRelatedTests.swift
//  RivuletTests
//
//  The detail page's Collection and Related rows come from one
//  /library/metadata/{rk}/related call. The fixtures are the hubs PMS 1.43.4
//  returned on 2026-09-30 for Raiders of the Lost Ark (87157), Diamonds Are
//  Forever (55947) and the show UNTAMED (141852), cut down to ratingKeys.
//

import XCTest
@testable import Rivulet

final class PlexProviderRelatedTests: XCTestCase {

    // MARK: - Split

    func test_movie_takesItsCollectionHubMinusItself_andRelatedDropsBothCollectionHubs() {
        let split = PlexProvider.splitRelated(hubs: raiders, currentRatingKey: "87157", kind: .movie)

        XCTAssertEqual(split.collectionTitle, "IMDb Top 250 Collection")
        XCTAssertEqual(split.members.map(\.ratingKey), [
            "52877", "64440", "95808", "61257", "14720", "63612", "14671", "9299", "95818", "14427", "14621",
        ])
        // All 8 Spielberg titles, then Harrison Ford up to the cap of 12. No
        // IMDb Top 250 movie or show, and not Raiders itself.
        XCTAssertEqual(split.related.map(\.ratingKey), [
            "64357", "231521", "14496", "233284", "13584", "234022", "72863", "234111",
            "232314", "231993", "232732", "14320",
        ])
        XCTAssertEqual(split.tagId, "353397")
        XCTAssertEqual(split.sectionId, "1")
    }

    func test_show_takesTheShowTypedHub_notTheMovieHubListedFirst() {
        let split = PlexProvider.splitRelated(hubs: untamed, currentRatingKey: "141852", kind: .show)

        XCTAssertEqual(split.collectionTitle, "IMDb Popular Collection")
        XCTAssertEqual(split.members.map(\.ratingKey), [
            "1160", "102973", "100408", "119495", "93597", "34356", "137938", "95007", "25088", "100200", "106687",
        ])
        // Rick and Morty (25088) is a collection member and also in a people
        // hub: it stays in the collection row and is gone from Related.
        XCTAssertTrue(split.members.map(\.ratingKey).contains("25088"))
        XCTAssertEqual(split.related.map(\.ratingKey), ["218758", "25711", "221913", "219301", "218452"])
        XCTAssertEqual(split.tagId, "353395")
        XCTAssertEqual(split.sectionId, "2")
    }

    func test_episodeAndSeason_getNoCollectionHub() {
        for kind in [MediaKind.episode, .season] {
            let split = PlexProvider.splitRelated(hubs: untamed, currentRatingKey: "141852", kind: kind)
            XCTAssertNil(split.collectionTitle)
            XCTAssertTrue(split.members.isEmpty)
            XCTAssertNil(split.tagId)
            XCTAssertNil(split.sectionId)
            // Collection hubs stay out of Related even when none is picked.
            XCTAssertEqual(split.related.count, 6)
        }
    }

    func test_collectionOf12OrFewer_parsesNoTagId() {
        let split = PlexProvider.splitRelated(hubs: diamonds, currentRatingKey: "55947", kind: .movie)

        XCTAssertEqual(split.collectionTitle, "James Bond Collection")
        XCTAssertEqual(split.members.map(\.ratingKey), ["55929", "55933", "96003"])
        XCTAssertNil(split.tagId)
        XCTAssertNil(split.sectionId)
        XCTAssertTrue(split.related.isEmpty)
    }

    func test_movie_aCollectionMemberInAPeopleHub_staysOutOfRelated() {
        let hubs = [
            hub("collection.related.1.1", "movie", "Bond Collection", key: "/library/sections/1/all?type=1",
                ["1", "2", "3"]),
            hub("movie.same.actor.0", "movie", "More with Someone", key: "/library/sections/1/all?actor=9",
                ["2", "4"]),
        ]
        let split = PlexProvider.splitRelated(hubs: hubs, currentRatingKey: "1", kind: .movie)

        XCTAssertEqual(split.members.map(\.ratingKey), ["2", "3"])
        XCTAssertEqual(split.related.map(\.ratingKey), ["4"])
    }

    // MARK: - Provider

    func test_moreHub_looksUpTheTrailingTileInTheHubsOwnSection() async throws {
        let network = StubNetwork()
        network.hubs = raiders
        network.collection = PlexMetadata(
            ratingKey: "118562", key: "/library/collections/118562/children",
            type: "collection", title: "IMDb Top 250"
        )

        let content = try await makeProvider(network).related(for: ref("87157"), kind: .movie)

        XCTAssertEqual(network.lookups, ["1/353397"])
        XCTAssertEqual(content.collection?.title, "IMDb Top 250 Collection")
        XCTAssertEqual(content.collection?.members.count, 11)
        XCTAssertEqual(content.collection?.collection?.ref.itemID, "118562")
        XCTAssertEqual(content.collection?.collection?.kind, .collection)
        XCTAssertEqual(content.items.count, 12)
    }

    func test_noMore_makesNoLookup() async throws {
        let network = StubNetwork()
        network.hubs = diamonds

        let content = try await makeProvider(network).related(for: ref("55947"), kind: .movie)

        XCTAssertTrue(network.lookups.isEmpty)
        XCTAssertEqual(content.collection?.members.map(\.ref.itemID), ["55929", "55933", "96003"])
        XCTAssertNil(content.collection?.collection)
    }

    func test_failedLookup_keepsTheRowWithoutATile() async throws {
        let network = StubNetwork()
        network.hubs = raiders
        network.lookupFails = true

        let content = try await makeProvider(network).related(for: ref("87157"), kind: .movie)

        XCTAssertEqual(network.lookups, ["1/353397"])
        XCTAssertEqual(content.collection?.members.count, 11)
        XCTAssertNil(content.collection?.collection)
    }

    // MARK: - Fixtures

    private final class StubNetwork: PlexNetworkManager {
        var hubs: [PlexHub] = []
        var collection: PlexMetadata?
        var lookupFails = false
        var lookups: [String] = []

        override func getRelatedItems(
            serverURL: String, authToken: String, ratingKey: String, limit: Int
        ) async throws -> [PlexHub] {
            hubs
        }

        override func getCollection(
            serverURL: String, authToken: String, sectionId: String, tagId: String
        ) async throws -> PlexMetadata? {
            lookups.append("\(sectionId)/\(tagId)")
            if lookupFails { throw PlexAPIError.invalidURL }
            return collection
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

    private func hub(
        _ identifier: String, _ type: String, _ title: String, more: Bool = false, key: String, _ keys: [String]
    ) -> PlexHub {
        PlexHub(
            hubIdentifier: identifier, title: title, type: type, key: key, more: more,
            Metadata: keys.map { PlexMetadata(ratingKey: $0, type: type) }
        )
    }

    /// Raiders of the Lost Ark: IMDb Top 250 is its collection (more than 12
    /// members, so `more`), then that tag's TV twin and two people hubs.
    private var raiders: [PlexHub] {
        [
            hub("collection.related.1.1", "movie", "IMDb Top 250 Collection", more: true,
                key: "/library/sections/1/all?type=1&tagId=353397&sort=taggingIndex:nullsLast,titleSort",
                ["52877", "64440", "95808", "61257", "14720", "63612", "14671", "9299", "87157", "95818", "14427", "14621"]),
            hub("collection.related.2.2", "show", "TV Shows in IMDb Top 250 Collection", more: true,
                key: "/library/sections/2/all?type=2&tagId=353397&sort=taggingIndex:nullsLast,titleSort",
                ["10794", "27090", "30672", "1160", "10821", "25088", "1503", "126789", "73002", "10807", "86479", "140411"]),
            hub("movie.same.director", "movie", "More by Steven Spielberg",
                key: "/library/sections/1/all?director=158774&id!=87157",
                ["64357", "231521", "14496", "233284", "13584", "234022", "72863", "234111"]),
            hub("movie.same.actor.0", "movie", "More with Harrison Ford",
                key: "/library/sections/1/all?actor=141025&id!=87157",
                ["232314", "231993", "232732", "14320", "234255", "234251", "234244", "232525"]),
        ]
    }

    /// Diamonds Are Forever: the four Bond films in release order, itself
    /// included, and nothing else. Four members, so no `more`.
    private var diamonds: [PlexHub] {
        [
            hub("collection.related.1.1", "movie", "James Bond Collection",
                key: "/library/sections/1/all?type=1&tagId=61303&sort=originallyAvailableAt,year:nullsLast",
                ["55929", "55947", "55933", "96003"]),
        ]
    }

    /// UNTAMED: the first collection hub is movie-typed; the show's own
    /// collection comes second. Rick and Morty (25088) sits in both the
    /// collection and a people hub.
    private var untamed: [PlexHub] {
        [
            hub("collection.related.1.1", "movie", "Movies in IMDb Popular Collection",
                key: "/library/sections/1/all?type=1&tagId=353395&sort=taggingIndex:nullsLast,titleSort",
                ["140994", "141836", "141869", "14736", "127330", "139385", "61247", "61257", "129666"]),
            hub("collection.related.2.2", "show", "IMDb Popular Collection", more: true,
                key: "/library/sections/2/all?type=2&tagId=353395&sort=taggingIndex:nullsLast,titleSort",
                ["141852", "1160", "102973", "100408", "119495", "93597", "34356", "137938", "95007", "25088", "100200", "106687"]),
            hub("tv.same.actor.1", "show", "More with Sam Neill",
                key: "/library/sections/2/all?actor=162153&id!=141852",
                ["218758", "25711", "25088"]),
            hub("tv.same.actor.2", "show", "More with Rosemarie DeWitt",
                key: "/library/sections/2/all?actor=176790&id!=141852",
                ["221913", "219301", "218452"]),
        ]
    }
}
