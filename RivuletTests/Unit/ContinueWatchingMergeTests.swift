// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The cross-server Continue Watching merge (#87). Guids are the ones measured
/// on the maintainer's PMS and the plex-test server.
final class ContinueWatchingMergeTests: XCTestCase {

    private func item(_ id: String, on server: String, kind: MediaKind = .movie,
                      watched: TimeInterval? = nil, identity: [String]) -> MediaItem {
        var item = JellyfinFixtures.mediaItem(id, kind: kind, providerID: server)
        item.identity = identity
        item.userState.lastViewedAt = watched.map { Date(timeIntervalSince1970: $0) }
        return item
    }

    private func merge(_ rows: [[MediaItem]]) -> [ContinueWatchingMerge.Card<MediaItem>] {
        ContinueWatchingMerge.merge(rows, keys: { $0.identity ?? [] }, watched: \.userState.lastViewedAt)
    }

    // MARK: Keys

    func test_plexKeys_movie_takesAgentGuidAndExternalIDs() {
        let keys = ContinueWatchingMerge.plexKeys(
            type: "movie", guid: "plex://movie/5d77682e6f4521001ea9ac27", showGuid: nil,
            guids: ["imdb://tt0338348", "tmdb://5255", "tvdb://1331"])
        XCTAssertEqual(keys, ["m:plex:5d77682e6f4521001ea9ac27", "m:imdb:tt0338348", "m:tmdb:5255", "m:tvdb:1331"])
    }

    func test_plexKeys_episode_keysOnItsShowOnly() {
        let keys = ContinueWatchingMerge.plexKeys(
            type: "episode", guid: "plex://episode/6a354e4ad628b6d781b765d7",
            showGuid: "plex://show/5e7e3e60a209280042fcecbc", guids: ["tvdb://11982483"])
        XCTAssertEqual(keys, ["s:plex:5e7e3e60a209280042fcecbc"], "an episode's Guid ids are its own, not its show's")
    }

    func test_legacyAgentGuid_parsesTheID() {
        XCTAssertEqual(ContinueWatchingMerge.key(fromPlexGuid: "com.plexapp.agents.thetvdb://80379?lang=en", scope: "s"),
                       "s:tvdb:80379")
        XCTAssertEqual(ContinueWatchingMerge.key(fromPlexGuid: "com.plexapp.agents.imdb://tt0338348?lang=en", scope: "m"),
                       "m:imdb:tt0338348")
        XCTAssertNil(ContinueWatchingMerge.key(fromPlexGuid: "local://123", scope: "m"))
        XCTAssertNil(ContinueWatchingMerge.key(fromPlexGuid: "plex://episode/abc", scope: "s"))
    }

    func test_providerIDKeys_jellyfinNames() {
        XCTAssertEqual(ContinueWatchingMerge.providerIDKeys(["Imdb": "tt14218830", "Tmdb": "125935", "Tvdb": "402910",
                                                             "TvRage": "1"], scope: "s"),
                       ["s:imdb:tt14218830", "s:tmdb:125935", "s:tvdb:402910"])
    }

    // MARK: Merge

    func test_samePlexGuidOnTwoServers_isOneCard_showingTheLaterWatch() {
        let main = item("1", on: "plex:main", watched: 100, identity: ["m:plex:mary"])
        let office = item("9", on: "plex:office", watched: 200, identity: ["m:plex:mary"])

        let cards = merge([[main], [office]])

        XCTAssertEqual(cards.map(\.item.ref.providerID), ["plex:office"])
        XCTAssertEqual(cards.first?.others.map(\.ref.providerID), ["plex:main"])
    }

    func test_syncedTie_keepsTheSelectedServersCopy() {
        let main = item("1", on: "plex:main", watched: 1792634625, identity: ["m:plex:mary"])
        let office = item("9", on: "plex:office", watched: 1792634625, identity: ["m:plex:mary"])
        XCTAssertEqual(merge([[main], [office]]).first?.item.ref.providerID, "plex:main")
    }

    func test_legacyAndModernAgent_matchThroughTheShowsExternalID() {
        // Main server: legacy agent. Test server: modern agent plus the show lookup.
        let main = item("e1", on: "plex:main", kind: .episode, watched: 50, identity: ["s:tvdb:80379"])
        let test = item("e2", on: "plex:test", kind: .episode, watched: 40,
                        identity: ["s:plex:5d9c086c02391c001f5891b3", "s:tvdb:80379", "s:tmdb:1418"])
        XCTAssertEqual(merge([[main], [test]]).count, 1)
    }

    func test_tmdbMovieAndShowWithOneNumber_doNotMerge() {
        let movie = item("1", on: "plex:main", identity: ["m:tmdb:5255"])
        let show = item("2", on: "jellyfin:srv", kind: .episode, identity: ["s:tmdb:5255"])
        XCTAssertEqual(merge([[movie], [show]]).count, 2)
    }

    func test_itemsWithoutIDs_neverMerge_evenWithOneTitle() {
        let a = item("Home Video", on: "plex:main", identity: [])
        let b = item("Home Video", on: "plex:office", identity: [])
        XCTAssertEqual(merge([[a], [b]]).count, 2)
    }

    func test_oneShowAtDifferentEpisodes_isOneCard_fromTheServerWatchedLast() {
        let plex = item("s2e5", on: "plex:main", kind: .episode, watched: 300, identity: ["s:tvdb:402910"])
        let jellyfin = item("s1e3", on: "jellyfin:srv", kind: .episode, watched: 100, identity: ["s:tvdb:402910"])
        let cards = merge([[plex], [jellyfin]])
        XCTAssertEqual(cards.map(\.item.ref.itemID), ["s2e5"])
    }

    func test_cardsSortByLatestWatch_undatedLast_inServerOrder() {
        let old = item("a", on: "plex:main", watched: 10, identity: ["m:imdb:a"])
        let undatedPlex = item("b", on: "plex:main", identity: ["m:imdb:b"])
        let new = item("c", on: "jellyfin:srv", watched: 99, identity: ["m:imdb:c"])
        let undatedJellyfin = item("d", on: "jellyfin:srv", identity: ["m:imdb:d"])

        let cards = merge([[old, undatedPlex], [new, undatedJellyfin]])

        XCTAssertEqual(cards.map(\.item.ref.itemID), ["c", "a", "b", "d"])
    }

    func test_oneContributingRow_keepsItsOwnOrder() {
        let a = item("a", on: "plex:main", watched: 10, identity: ["m:imdb:a"])
        let b = item("b", on: "plex:main", watched: 99, identity: ["m:imdb:b"])
        XCTAssertEqual(merge([[a, b], []]).map(\.item.ref.itemID), ["a", "b"])
    }

    /// #470: one title in two libraries of one server, keeping the row's order.
    func test_oneServer_twoLibraries_isOneCard_inTheRowsOwnOrder() {
        let older = item("a", on: "plex:main", watched: 10, identity: ["m:imdb:same"])
        let other = item("b", on: "plex:main", watched: 5, identity: ["m:imdb:b"])
        let newer = item("c", on: "plex:main", watched: 20, identity: ["m:imdb:same"])
        let cards = merge([[older, other, newer]])
        XCTAssertEqual(cards.map(\.item.ref.itemID), ["c", "b"], "the copy watched last shows, where the first copy sat")
        XCTAssertEqual(cards[0].others.map(\.ref.itemID), ["a"])
    }

    /// One server needs no show lookup: episodes without keys stay and stay apart.
    @MainActor
    func test_rowCards_oneRow_mergesOnCarriedKeysWithoutWaitingForShows() {
        let a = item("a", on: "jellyfin:x", kind: .episode, identity: [])
        let b = item("b", on: "jellyfin:x", kind: .episode, identity: [])
        let cards = ContinueWatchingRow.shared.cards([[a, b]], identity: { $0.identity ?? [] },
                                                     showKey: { _ in "jellyfin:x|show" }, watched: \.userState.lastViewedAt)
        XCTAssertEqual(cards.map(\.item.ref.itemID), ["a", "b"])
    }

    func test_anItemBridgingTwoGroups_foldsThemIntoOne() {
        let imdbOnly = item("1", on: "plex:main", identity: ["m:imdb:tt1"])
        let tmdbOnly = item("2", on: "plex:office", identity: ["m:tmdb:7"])
        let both = item("3", on: "jellyfin:srv", identity: ["m:imdb:tt1", "m:tmdb:7"])
        let cards = merge([[imdbOnly], [tmdbOnly], [both]])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.copies.count, 3)
    }
}

/// Items from two Plex servers can share a ratingKey (#87, iOS keys them on `serverID`).
final class PlexMetadataServerIdentityTests: XCTestCase {
    func test_sameRatingKeyOnTwoServers_isTwoItems() {
        var office = PlexMetadata(ratingKey: "2", title: "Mary Poppins")
        office.serverID = "27061058f07a814981a2deb3ac3a3f96f89c7d08"
        let selected = PlexMetadata(ratingKey: "2", title: "Mary Poppins")

        XCTAssertNotEqual(office, selected)
        XCTAssertNotEqual(office.id, selected.id)
        XCTAssertEqual(selected.id, "2", "the selected server's ids are unchanged")
        XCTAssertEqual(Set([office, selected]).count, 2)
    }
}
