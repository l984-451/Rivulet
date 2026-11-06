// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeHeroTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class HomeHeroTests: XCTestCase {
    private func item(_ id: String, provider: String = "plex:a", art: Bool = true, show: String? = nil) -> MediaItem {
        var base = JellyfinFixtures.mediaItem(id, providerID: provider, grandparent: show)
        if art {
            base = MediaItem(ref: base.ref, kind: base.kind, title: base.title, sortTitle: nil, overview: nil, year: nil,
                             runtime: nil, parentRef: nil, grandparentRef: base.grandparentRef, episodeNumber: nil,
                             seasonNumber: nil, childProgress: nil, userState: base.userState,
                             artwork: MediaArtwork(poster: nil, backdrop: URL(string: "http://x/\(id).jpg"), thumbnail: nil, logo: nil),
                             parentArtwork: nil, grandparentArtwork: nil)
        }
        return base
    }

    private func shelf(_ id: String, _ items: [MediaItem]) -> MediaHub {
        MediaHub(id: id, providerID: "plex:a", title: id, style: .shelf, items: items)
    }

    private func items(_ sources: Set<HeroSources.Source>, continueWatching: [MediaItem] = [], shelves: [MediaHub] = [],
                       watchlist: [MediaItem] = [], trending: [MediaItem] = [], personal: [PersonalRow] = [],
                       heroPins: [HomePlaylistPins.Pin] = []) -> [MediaItem] {
        HomeHero.items(sources: sources, continueWatching: continueWatching, shelves: shelves, watchlist: watchlist,
                       trending: trending, personal: personal, heroPins: heroPins)
    }

    func test_libraryItems_skipContinueWatchingRows() {
        let rows = [shelf("m.continueWatching", [item("c")]), shelf("movie.inprogress", [item("p")]),
                    shelf("m.recentlyAdded", [item("r1"), item("r2"), item("r3")])]
        XCTAssertEqual(HomeHero.libraryItems(rows).map(\.ref.itemID), ["r1", "r2"])
    }

    func test_trendingFillsWhenNothingElseIsChosen() {
        let result = items([.trending], continueWatching: [item("c")], shelves: [shelf("recentlyadded", [item("r")])],
                           trending: [item("t1"), item("t2")])
        XCTAssertEqual(result.map(\.ref.itemID), ["t1", "t2"])
    }

    func test_continueWatchingChoice_dropsItemsWithoutArt_andCapsAtTen() {
        let cw = (0..<14).map { item("c\($0)", art: $0 != 0) }
        let result = items([.continueWatching], continueWatching: cw)
        XCTAssertEqual(result.count, 10)
        XCTAssertFalse(result.contains { $0.ref.itemID == "c0" })
    }

    func test_recentlyAdded_takesOneFromEachRowInTurn() {
        let a = shelf("plex:a|movie.recentlyadded.1", [item("a1"), item("a2")])
        let b = shelf("jellyfin:s|m.recentlyAdded", [item("b1", provider: "jellyfin:s"), item("b2", provider: "jellyfin:s")])
        let other = shelf("plex:a|genre", [item("g1")])
        let result = items([.recentlyAdded], shelves: [a, other, b])
        XCTAssertEqual(result.map(\.ref.itemID), ["a1", "b1", "a2", "b2"])
    }

    func test_anEmptyChoiceFallsBackToTrending_thenToRows() {
        let rows = [shelf("a", [item("r1"), item("r2")])]
        XCTAssertEqual(items([.watchlist], shelves: rows, trending: [item("t")]).map(\.ref.itemID), ["t"])
        XCTAssertEqual(items([.watchlist], shelves: rows).map(\.ref.itemID), ["r1", "r2"])
    }

    func test_rowItems_twoPerRow_onePerShow_upToSix() {
        let rows = (0..<5).map { shelf("row\($0)", [item("r\($0)a", show: $0 == 1 ? "s0" : "s\($0)"), item("r\($0)b"), item("r\($0)c")]) }
        let result = items([.trending], shelves: rows)
        XCTAssertEqual(result.map(\.ref.itemID), ["r0a", "r0b", "r1b", "r2a", "r2b", "r3a"],
                       "two per row; row 1's first is a second episode of row 0's show")
    }

    func test_mix_takesTurnsAcrossSources_showsATitleOnce_andCapsAtTen() {
        let shared = item("shared")
        let lists = [[shared] + (0..<8).map { item("t\($0)") }, [shared] + (0..<8).map { item("w\($0)") }]
        let result = HomeHero.mix(lists)
        XCTAssertEqual(result.map(\.ref.itemID).prefix(5), ["shared", "t0", "w0", "t1", "w1"])
        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(Set(result.map(\.ref)).count, 10, "the shared title shows once")
    }

    func test_items_mixSourcesFavoritesAndHeroPlaylists() {
        let fav = PersonalRow(id: "plex:a|fav", providerID: "plex:a", title: "Favorite Movies",
                              identifier: PersonalRows.favoritesIdentifier(.movies), libraryKey: "1", items: [item("f1"), item("f2")])
        let pin = HomePlaylistPins.Pin(providerID: "jellyfin:s", playlistID: "p1", title: "Classics")
        let list = PersonalRow(id: PersonalRows.playlistRowID(providerID: "jellyfin:s", playlistID: "p1"), providerID: "jellyfin:s",
                               title: "Classics", identifier: "x", libraryKey: nil, items: [item("l1", provider: "jellyfin:s")])
        let result = items([.trending, .favoriteMovies], trending: [item("t1"), item("t2")], personal: [fav, list], heroPins: [pin])
        XCTAssertEqual(result.map(\.ref.itemID), ["t1", "f1", "l1", "t2", "f2"])
    }

    func test_roundRobin_interleavesProviders() {
        XCTAssertEqual(HomeHero.roundRobin([[1, 2, 3], [10], [20, 21]]), [1, 10, 20, 2, 21, 3])
    }

    @MainActor
    func test_trendingSource_asksEveryProvider_filtersArt_andCaps() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = (0..<8).map { item("p\($0)", art: $0 != 0) }
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.ownedItemsResult = (0..<8).map { item("j\($0)", provider: "jellyfin:s") }
        let sources = HomeHeroSources()
        sources.trendingTitles = { (1...8).map { TitleMatch(kind: .movie, externalIDs: ["tmdb": "\($0)"], plexGUID: nil) } }

        let items = await sources.trending(providers: [plex, jf])

        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items.prefix(4).map(\.ref.itemID), ["p1", "j0", "p2", "j1"], "providers take turns; no art, no slide")
        XCTAssertEqual(plex.ownedRequests.count, 1)
    }

    @MainActor
    func test_trendingSource_isKeptForAnHourPerProviderSet() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [item("p0")]
        let sources = HomeHeroSources()
        var asked = 0
        sources.trendingTitles = { asked += 1; return [TitleMatch(kind: .movie, externalIDs: ["tmdb": "1"], plexGUID: nil)] }

        _ = await sources.trending(providers: [plex])
        _ = await sources.trending(providers: [plex])
        XCTAssertEqual(asked, 1)

        let other = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        _ = await sources.trending(providers: [plex, other])
        XCTAssertEqual(asked, 2, "a different set of servers is a different answer")
    }

    @MainActor
    func test_watchlistSource_matchesEntriesOnEachProvider() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [item("w1"), item("w2", art: false)]
        let sources = HomeHeroSources()
        let entry = TitleMatch(kind: .movie, externalIDs: ["tmdb": "5"], plexGUID: nil)
        let other = TitleMatch(kind: .show, externalIDs: ["tmdb": "6"], plexGUID: nil)

        let items = await sources.watchlist(titles: [entry, other], key: ["5", "6"], providers: [plex])

        XCTAssertEqual(items.map(\.ref.itemID), ["w1"])
        XCTAssertEqual(plex.ownedRequests.first?.first, entry)
    }
}
