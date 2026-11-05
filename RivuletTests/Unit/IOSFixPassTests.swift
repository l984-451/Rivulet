// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IOSFixPassTests.swift
//  RivuletTests
//
//  The review fixes after stages 3b to 3d: the watched rule, library sorts, More Like This,
//  hero dedupe, Plex routing, extras order, a failing selected server, and the show guid.
//

import Synchronization
import XCTest
@testable import Rivulet

final class IOSFixPassTests: XCTestCase {
    private func item(_ id: String, kind: MediaKind = .movie, provider: String = "plex:a", title: String? = nil, year: Int? = nil,
                      ids: [String: String]? = nil, played: Bool = false, offset: TimeInterval = 0, runtime: TimeInterval = 6000) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: provider, itemID: id), kind: kind, title: title ?? id, sortTitle: nil, overview: nil,
            year: year, runtime: runtime, parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: played, viewOffset: offset, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil, externalIDs: ids)
    }

    // MARK: - Watched rule (#270)

    func test_countsAsWatched_aResumePointOutranksTheWatchedFlag() {
        XCTAssertTrue(item("a", played: true).countsAsWatched)
        XCTAssertFalse(item("b", played: true, offset: 1800).countsAsWatched, "a rewatch in progress is not watched yet")
        XCTAssertFalse(item("c", played: false).countsAsWatched)
        XCTAssertFalse(item("d", played: true, offset: 10).countsAsWatched, "any partial progress counts, as tvOS's menu does")
        XCTAssertTrue(item("e", played: true, offset: 0).countsAsWatched)
    }

    func test_nextUp_skipsAWatchedEpisodeOnlyWithoutAResumePoint() {
        let rewatch = item("a", kind: .episode, played: true, offset: 1800)
        let unwatched = item("b", kind: .episode)
        XCTAssertEqual(MediaItem.nextUp(in: [rewatch, unwatched])?.ref.itemID, "a")
    }

    // MARK: - Sorts

    func test_librarySorts_plexOffersAllFourEvenOnATVLibrary() {
        let showSorts = LibrarySortOption.expressible(for: .shows)
        XCTAssertFalse(showSorts.contains(.releaseDateDesc), "the premise: the seam's TV list lacks Release Date")
        XCTAssertEqual(IOSLibrarySorts.menu(offered: showSorts, isPlex: true),
                       [.titleAsc, .addedAtDesc, .releaseDateDesc, .ratingDesc])
    }

    func test_librarySorts_anotherServerOffersWhatItCanApply() {
        XCTAssertEqual(IOSLibrarySorts.menu(offered: [.titleAsc, .addedAtDesc], isPlex: false), [.titleAsc, .addedAtDesc])
    }

    // MARK: - More Like This

    private func hub(_ identifier: String, _ type: String, _ keys: [String]) -> PlexHub {
        PlexHub(hubIdentifier: identifier, title: identifier, type: type, key: "/hubs/\(identifier)", more: false,
                Metadata: keys.map { PlexMetadata(ratingKey: $0, type: type) })
    }

    func test_similarItems_onlySimilarHubs_dedupedWithoutTheItem_uncapped() {
        let similar = (1...14).map(String.init)
        let hubs = [
            hub("collection.related.1.1", "movie", ["c1", "c2"]),
            hub("movie.similar", "movie", ["99"] + similar),
            hub("movie.same.actor.0", "movie", ["a1", "a2"]),
            hub("movie.similar.more", "movie", ["3", "x1"]),
        ]
        let found = PlexProvider.similarItems(hubs: hubs, currentRatingKey: "99")
        XCTAssertEqual(found.compactMap(\.ratingKey), similar + ["x1"], "14 similar titles, not cut at 12; no actor or collection rows")
    }

    func test_moreLikeThis_defaultIsTheRelatedRow() async throws {
        let stub = StubMediaProvider()
        stub.relatedContent = RelatedContent(items: [item("r1")], collection: nil)
        let items = try await stub.moreLikeThis(for: MediaItemRef(providerID: "stub", itemID: "1"), kind: .movie)
        XCTAssertEqual(items.map(\.ref.itemID), ["r1"])
    }

    // MARK: - Extras

    func test_orderedExtras_trailersFirst_thenByKind() {
        func extra(_ id: String, _ subtype: ExtraSubtype) -> MediaItemDetail.Extra {
            MediaItemDetail.Extra(id: id, title: id, thumbnailURL: nil, duration: nil, playbackKey: id, providerID: "plex:a", subtype: subtype)
        }
        let detail = MediaItemDetail(
            item: item("m"), tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [], chapters: [],
            mediaSources: [], trailerURL: nil, contentRating: nil, nextEpisode: nil, collections: [],
            extras: [extra("f", .featurette), extra("u", .unknown), extra("t1", .trailer), extra("b", .behindTheScenes), extra("t2", .trailer)])
        XCTAssertEqual(detail.orderedExtras.map(\.id), ["t1", "t2", "f", "b", "u"])
    }

    // MARK: - Hero dedupe

    func test_hero_deduplicated_sameTitleOnTwoServersIsOneSlide_theFirstCopy() {
        let selected = item("p1", provider: "plex:a", title: "Dune", year: 2021, ids: ["tmdb": "438631", "plex": "plex://movie/x"])
        let other = item("j1", provider: "jellyfin:s", title: "Dune", year: 2021, ids: ["tmdb": "438631"])
        let different = item("j2", provider: "jellyfin:s", title: "Heat", year: 1995, ids: ["tmdb": "949"])
        XCTAssertEqual(HomeHero.deduplicated([selected, other, different]).map(\.ref.itemID), ["p1", "j2"])
    }

    func test_hero_deduplicated_withoutSharedIds_matchesOnKindTitleAndYear() {
        let a = item("p1", title: "The  Dune", year: 2021)
        let b = item("j1", provider: "jellyfin:s", title: "the dune", year: 2021)
        let otherYear = item("j2", provider: "jellyfin:s", title: "The Dune", year: 1984)
        XCTAssertEqual(HomeHero.deduplicated([a, b, otherYear]).map(\.ref.itemID), ["p1", "j2"])
    }

    func test_hero_deduplicated_aMovieAndAShowSharingANumberAreDifferentTitles() {
        let movie = item("m", kind: .movie, ids: ["tmdb": "1"])
        let show = item("s", kind: .show, provider: "jellyfin:s", ids: ["tmdb": "1"])
        XCTAssertEqual(HomeHero.deduplicated([movie, show]).count, 2)
    }

    @MainActor
    func test_heroSource_dedupesAcrossServers() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        func withArt(_ base: MediaItem) -> MediaItem {
            MediaItem(ref: base.ref, kind: base.kind, title: base.title, sortTitle: nil, overview: nil, year: base.year, runtime: nil,
                      parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                      userState: base.userState,
                      artwork: MediaArtwork(poster: nil, backdrop: URL(string: "http://x/a.jpg"), thumbnail: nil, logo: nil),
                      parentArtwork: nil, grandparentArtwork: nil, externalIDs: base.externalIDs)
        }
        plex.ownedItemsResult = [withArt(item("p1", title: "Dune", ids: ["tmdb": "5"]))]
        jf.ownedItemsResult = [withArt(item("j1", provider: "jellyfin:s", title: "Dune", ids: ["tmdb": "5"])),
                               withArt(item("j2", provider: "jellyfin:s", title: "Heat", ids: ["tmdb": "6"]))]
        let sources = HomeHeroSources()
        sources.trendingTitles = { (1...5).map { TitleMatch(kind: .movie, externalIDs: ["tmdb": "\($0)"], plexGUID: nil) } }
        let items = await sources.trending(providers: [plex, jf])
        XCTAssertEqual(items.map(\.ref.itemID), ["p1", "j2"])
    }

    // MARK: - Plex routing

    func test_plexRoute_selectedExtraUnknownAndNotPlex() {
        MediaItemRef.selectedPlexIDs.withLock { $0 = ["plex:sel", "plex:old"] }
        MediaItemRef.extraPlexIDs.withLock { $0 = ["plex:extra"] }
        defer {
            MediaItemRef.selectedPlexIDs.withLock { $0 = [] }
            MediaItemRef.extraPlexIDs.withLock { $0 = [] }
        }
        func route(_ id: String) -> PlexRoute? { MediaItemRef(providerID: id, itemID: "1").plexRoute }
        XCTAssertEqual(route("plex:sel"), .selected)
        XCTAssertEqual(route("plex:old"), .selected, "an id the selected server had before a URL change still routes to it")
        XCTAssertEqual(route("plex:extra"), .extra("extra"))
        XCTAssertEqual(route("plex:gone"), .unknown, "an extra server that left must not fall back to the selected one")
        XCTAssertNil(route("jellyfin:s"))
    }

    @MainActor
    func test_registry_publishesTheSelectedAndExtraPlexIds() {
        let registry = MediaProviderRegistry.shared
        defer { registry.populate(plexServerURL: nil, plexToken: nil, plexMachineID: nil, plexName: "Plex") }
        registry.populate(plexServerURL: "http://plex.test", plexToken: "t", plexMachineID: "m1", plexName: "P")
        XCTAssertEqual(MediaItemRef(providerID: "plex:m1", itemID: "1").plexRoute, .selected)
        registry.populate(plexServerURL: "http://plex.test2", plexToken: "t", plexMachineID: "m2", plexName: "P")
        XCTAssertEqual(MediaItemRef(providerID: "plex:m1", itemID: "1").plexRoute, .selected, "the earlier id stays valid")
        XCTAssertEqual(MediaItemRef(providerID: "plex:m2", itemID: "1").plexRoute, .selected)
        registry.populate(plexServerURL: nil, plexToken: nil, plexMachineID: nil, plexName: "Plex")
        XCTAssertEqual(MediaItemRef(providerID: "plex:m1", itemID: "1").plexRoute, .unknown, "signed out: nothing routes")
    }

    // MARK: - A failing selected server

    private func library(_ id: String, provider: String) -> MediaLibrary {
        MediaLibrary(id: id, providerID: provider, title: "Lib \(id)", kind: .movies)
    }

    @MainActor
    func test_loader_aFailingSelectedServerDoesNotBlankTheOthers() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.librariesError = MediaProviderError.unreachable
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.libraryList = [library("m", provider: "jellyfin:s")]
        jf.hubsByLibrary = ["m": [MediaHub(id: "m.recentlyAdded", providerID: "jellyfin:s", title: "R", style: .shelf, items: [item("j1", provider: "jellyfin:s")])]]
        let loader = HomeFeedLoader()
        var latest: HomeFeed.Assembled?
        loader.onChange = { latest = $0 }

        try await loader.load(selected: plex, secondary: [jf])
        await loader.finishSecondary()

        XCTAssertEqual(latest?.shelves.map(\.id), ["jellyfin:s|m.recentlyAdded"])
        XCTAssertEqual(latest?.libraries.map(\.id), ["m"])
        XCTAssertEqual(latest?.failures.keys.sorted(), ["plex:a"], "the selected server's error is for its part only")
    }

    @MainActor
    func test_loader_aFailureClearsWhenTheServerAnswersAgain() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.librariesError = MediaProviderError.unreachable
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        let loader = HomeFeedLoader()
        var latest: HomeFeed.Assembled?
        loader.onChange = { latest = $0 }
        try await loader.load(selected: plex, secondary: [jf])
        await loader.finishSecondary()
        XCTAssertFalse(latest?.failures.isEmpty ?? true)

        plex.librariesError = nil
        plex.libraryList = [library("1", provider: "plex:a")]
        try await loader.load(selected: plex, secondary: [jf])
        await loader.finishSecondary()
        XCTAssertEqual(latest?.failures.count, 0)
        XCTAssertEqual(latest?.libraries.map(\.id), ["1"])
    }

    @MainActor
    func test_loader_aFailingSecondaryIsReportedToo() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.libraryList = [library("1", provider: "plex:a")]
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.librariesError = MediaProviderError.unauthorized
        let loader = HomeFeedLoader()
        var latest: HomeFeed.Assembled?
        loader.onChange = { latest = $0 }
        try await loader.load(selected: plex, secondary: [jf])
        await loader.finishSecondary()
        XCTAssertEqual(latest?.failures.keys.sorted(), ["jellyfin:s"])
    }

    // MARK: - Watchlist for an episode or season

    func test_watchlistMembership_anEpisodeAndSeasonStandForTheirShow() {
        let episode = item("e", kind: .episode, ids: ["showPlex": "plex://show/abc"])
        let season = item("s", kind: .season, ids: ["showPlex": "plex://show/abc"])
        XCTAssertTrue(WatchlistMembership.canAnswer(episode))
        XCTAssertTrue(WatchlistMembership.isListed(episode, plexGUIDs: ["plex://show/abc"], contains: { _ in false }))
        XCTAssertTrue(WatchlistMembership.isListed(season, plexGUIDs: ["plex://show/abc"], contains: { _ in false }))
        XCTAssertFalse(WatchlistMembership.isListed(episode, plexGUIDs: ["plex://show/zzz"], contains: { _ in true }),
                       "only the show's plex guid counts, never the episode's own ids")
        XCTAssertFalse(WatchlistMembership.canAnswer(item("e2", kind: .episode)), "no show guid, no answer")
    }
}
