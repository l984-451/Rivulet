// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class TitleCopiesTests: XCTestCase {
    private var registry: MediaProviderRegistry!
    /// The selected Plex server.
    private var home: StubMediaProvider!
    /// A Jellyfin server: no guid lookup, only search.
    private var den: StubMediaProvider!

    override func setUp() {
        super.setUp()
        registry = MediaProviderRegistry()
        home = StubMediaProvider(id: "plex:home", displayName: "Home")
        den = StubMediaProvider(id: "jellyfin:den", kind: .jellyfin, displayName: "Den")
        registry.register(home)
        registry.register(den)
    }

    // MARK: - Fixtures

    private func item(_ id: String, on server: StubMediaProvider, kind: MediaKind = .movie,
                      title: String = "Ted Lasso", year: Int? = nil, season: Int? = nil, episode: Int? = nil,
                      show: MediaItemRef? = nil, offset: TimeInterval = 0) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: server.id, itemID: id),
            kind: kind, title: title, sortTitle: nil, overview: nil, year: year, runtime: nil,
            parentRef: nil, grandparentRef: show,
            episodeNumber: episode, seasonNumber: season, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: offset, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    private func source(_ id: String) -> MediaSource {
        MediaSource(id: id, container: "mkv", duration: 100, bitrate: nil, fileSize: nil, fileName: nil,
                    versionName: nil, videoResolution: "1080", videoTracks: [], audioTracks: [], subtitleTracks: [],
                    streamKind: .directPlay, streamURL: nil)
    }

    private func detail(_ item: MediaItem, files: [String] = ["f"], ids: [String: String] = [:],
                        guid: String? = nil, library: String? = nil) -> MediaItemDetail {
        MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
                        chapters: [], mediaSources: files.map(source), trailerURL: nil, contentRating: nil,
                        nextEpisode: nil, collections: [], externalIDs: ids, plexGUID: guid, library: library)
    }

    /// `server` answers `fullDetail` from `details` by itemID; any other item, or one in `failing`, throws.
    private func serve(_ server: StubMediaProvider, _ details: [MediaItemDetail], failing: Set<String> = []) {
        let byID = Dictionary(uniqueKeysWithValues: details.map { ($0.item.ref.itemID, $0) })
        server.detailResultFor = { ref in
            guard !failing.contains(ref.itemID), let detail = byID[ref.itemID] else { throw MediaProviderError.notFound }
            return detail
        }
    }

    /// A guid lookup answering rating keys by server id; a server missing from `keys` is not Plex.
    private func guids(_ keys: [String: [String]], failing: Set<String> = []) -> TitleCopies.GUIDLookup {
        { _, server in
            if failing.contains(server.id) { throw MediaProviderError.notFound }
            return keys[server.id]
        }
    }

    private let movie = TitleQuery(title: "Ted Lasso", year: 2020, ids: ["tmdb": "97546"], plexGUID: "plex://movie/x")

    // MARK: - Servers

    func test_servers_shownServerNeedsASecondLibrary_othersOne() {
        let both: [any MediaProvider] = [home, den]
        XCTAssertEqual(TitleCopies.servers(both, besides: home.id, libraries: [home.id: 1, den.id: 1]).map(\.id), [den.id])
        XCTAssertEqual(TitleCopies.servers(both, besides: home.id, libraries: [home.id: 2, den.id: 0]).map(\.id), [home.id])
        XCTAssertTrue(TitleCopies.servers([home], besides: home.id, libraries: [home.id: 1]).isEmpty)
        XCTAssertEqual(TitleCopies.servers(both, besides: home.id, libraries: [:]).map(\.id), [home.id, den.id],
                       "a server whose libraries are unknown is asked")
    }

    func test_libraryCounts_moviesOrShows_andMixed() {
        let libraries = [
            MediaLibrary(id: "1", providerID: home.id, title: "Movies", kind: .movies),
            MediaLibrary(id: "2", providerID: home.id, title: "Movies 4K", kind: .movies),
            MediaLibrary(id: "3", providerID: home.id, title: "TV", kind: .shows),
            MediaLibrary(id: "4", providerID: den.id, title: "Mixed", kind: .mixed),
            MediaLibrary(id: "5", providerID: den.id, title: "Music", kind: .music)
        ]
        XCTAssertEqual(TitleCopies.libraryCounts(libraries, holding: .movie), [home.id: 2, den.id: 1])
        XCTAssertEqual(TitleCopies.libraryCounts(libraries, holding: .episode), [home.id: 1, den.id: 1])
    }

    func test_servers_inRegistry_selectedPlexFirst() {
        XCTAssertEqual(TitleCopies.servers(in: registry).map(\.id), [home.id, den.id])
    }

    func test_current_mapsAStaleSelectedIDToTheRegistrysOwn() {
        let stale = MediaItemRef(providerID: "plex:old", itemID: "1")
        XCTAssertEqual(TitleCopies.current(stale, in: registry), MediaItemRef(providerID: home.id, itemID: "1"))
        let jellyfin = MediaItemRef(providerID: den.id, itemID: "1")
        XCTAssertEqual(TitleCopies.current(jellyfin, in: registry), jellyfin)
    }

    // MARK: - Query

    func test_query_fromAMovieAndAnEpisode() throws {
        let film = item("1", on: home, year: 2021)
        let query = try XCTUnwrap(TitleQuery(detail(film, ids: ["tmdb": "1"], guid: "plex://movie/a"), show: nil))
        XCTAssertEqual(query, TitleQuery(title: "Ted Lasso", year: 2021, ids: ["tmdb": "1"], plexGUID: "plex://movie/a"))

        let show = detail(item("s", on: home, kind: .show, year: 2020), ids: ["tvdb": "9"], guid: "plex://show/s")
        let ep = detail(item("e", on: home, kind: .episode, title: "Pilot", season: 1, episode: 2))
        let episode = try XCTUnwrap(TitleQuery(ep, show: show))
        XCTAssertEqual(episode.show, .init(title: "Ted Lasso", year: 2020, ids: ["tvdb": "9"], plexGUID: "plex://show/s"))
        XCTAssertEqual(episode.season, 1)
        XCTAssertEqual(episode.episode, 2)
        XCTAssertNil(TitleQuery(ep, show: nil), "an episode needs its show")
    }

    /// A legacy agent's guid is not a plex:// guid, so it is not looked up.
    func test_query_dropsAnAgentGUID() throws {
        let query = try XCTUnwrap(TitleQuery(detail(item("1", on: home), guid: "com.plexapp.agents.imdb://tt1"), show: nil))
        XCTAssertNil(query.plexGUID)
    }

    // MARK: - One server

    /// Movies and Movies 4K on one server both hold the guid: each is a copy, the shown one left out.
    func test_copies_guidMatches_everyLibrary_leavingOutTheShown() async {
        let shown = item("1", on: home)
        let fourK = item("5", on: home)
        serve(home, [detail(fourK, library: "Movies 4K")])
        let found = await TitleCopies.copies(of: movie, on: home, excluding: [shown.ref],
                                             guidLookup: guids([home.id: ["1", "5", "5"]]))
        XCTAssertEqual(found.details.map(\.item.ref), [fourK.ref])
        XCTAssertTrue(found.complete)
        XCTAssertTrue(home.playbackCalls.allSatisfy { $0 != "detail(1)" }, "the shown item is not read")
    }

    /// Ted Lasso: a legacy-agent library stores its own guid, so only the title search finds it,
    /// and the title rule keeps a copy and drops a remake and a spin-off.
    func test_copies_noGuidCopy_searchesAndConfirms() async {
        let shown = item("1", on: home, year: 2020)
        let legacy = item("2", on: home, year: 2020)
        let remake = item("3", on: home, year: 2020)
        let spinOff = item("4", on: home, title: "Ted Lasso: The Return", year: 2020)
        let show = item("6", on: home, kind: .show, year: 2020)
        home.searchItems = [shown, legacy, remake, spinOff, show]
        serve(home, [detail(legacy, ids: ["tmdb": "97546"]), detail(remake, ids: ["tmdb": "1"])])
        let found = await TitleCopies.copies(of: movie, on: home, excluding: [shown.ref],
                                             guidLookup: guids([home.id: ["1"]]))
        XCTAssertEqual(found.details.map(\.item.ref), [legacy.ref])
        XCTAssertTrue(found.complete)
        XCTAssertEqual(Set(home.playbackCalls), ["detail(2)", "detail(3)"], "only same-titled movies are read")
    }

    func test_copies_jellyfin_searches() async {
        let copy = item("j1", on: den, year: 2021)
        den.searchItems = [copy]
        serve(den, [detail(copy, ids: ["imdb": "tt10986410"])])
        let found = await TitleCopies.copies(of: movie, on: den, guidLookup: guids([:]))
        XCTAssertEqual(found.details.map(\.item.ref), [copy.ref])
    }

    func test_copies_searchLooksAtFourCandidatesAtMost() async {
        den.searchItems = (1...6).map { item("\($0)", on: den) }
        serve(den, den.searchItems.map { detail($0) })
        _ = await TitleCopies.copies(of: movie, on: den, guidLookup: guids([:]))
        XCTAssertEqual(den.playbackCalls.count, 4)
    }

    /// A failed request makes the answer incomplete, so it is not cached; what did answer is kept.
    func test_copies_failures_markTheAnswerIncomplete() async {
        let copy = item("2", on: home)
        home.searchItems = [copy]
        serve(home, [detail(copy)])
        let lookupFailed = await TitleCopies.copies(of: movie, on: home, guidLookup: guids([:], failing: [home.id]))
        XCTAssertFalse(lookupFailed.complete)
        XCTAssertEqual(lookupFailed.details.map(\.item.ref), [copy.ref])

        home.searchError = MediaProviderError.notFound
        let searchFailed = await TitleCopies.copies(of: movie, on: home, guidLookup: guids([:]))
        XCTAssertFalse(searchFailed.complete)
    }

    /// An episode is found through its show (by guid here), then by season and episode number.
    func test_copies_episode_walksTheOtherShow() async {
        let showOnDen = item("s9", on: den, kind: .show)
        let season = item("se2", on: den, kind: .season, season: 2)
        let wanted = item("e3", on: den, kind: .episode, season: 2, episode: 3)
        den.childrenByParent = ["s9": [item("se1", on: den, kind: .season, season: 1), season],
                                "se2": [item("e1", on: den, kind: .episode, season: 2, episode: 1), wanted]]
        den.searchItems = [showOnDen]
        serve(den, [detail(wanted)])
        let query = TitleQuery(title: "Pilot", year: nil, ids: [:], plexGUID: nil,
                               show: .init(title: "Ted Lasso", year: nil, ids: [:], plexGUID: "plex://show/s"),
                               season: 2, episode: 3)
        let found = await TitleCopies.copies(of: query, on: den, guidLookup: guids([:]))
        XCTAssertEqual(found.details.map(\.item.ref), [wanted.ref])
        XCTAssertTrue(found.complete)
    }

    func test_copies_episode_missingOnTheOtherShow_isNoCopy() async {
        den.childrenByParent = ["s9": [item("se1", on: den, kind: .season, season: 1)]]
        den.searchItems = [item("s9", on: den, kind: .show)]
        let query = TitleQuery(title: "Pilot", year: nil, ids: [:], plexGUID: nil,
                               show: .init(title: "Ted Lasso", year: nil, ids: [:], plexGUID: nil),
                               season: 2, episode: 3)
        let found = await TitleCopies.copies(of: query, on: den, guidLookup: guids([:]))
        XCTAssertTrue(found.details.isEmpty)
        XCTAssertTrue(found.complete)
    }

    // MARK: - Versions

    func test_versions_namesEachServer_andSkipsCopiesWithoutFiles() async {
        let shown = detail(item("1", on: home), guid: "plex://movie/x")
        let onDen = item("j1", on: den)
        let fileless = item("j2", on: den)
        den.searchItems = [onDen, fileless]
        serve(den, [detail(onDen, library: "Films"), detail(fileless, files: [])])
        let result = await TitleCopies.versions(of: shown, on: [home, den], registry: registry,
                                                cache: TitleCopies.Cache(), guidLookup: guids([home.id: ["1"]]))
        XCTAssertEqual(result.copies.map(\.item.ref), [onDen.ref])
        XCTAssertEqual(result.copies.map(\.server), ["Den"])
        XCTAssertEqual(result.copies.map(\.library), ["Films"])
        XCTAssertTrue(result.complete)
    }

    /// An episode page: the show's own entry is left out, so its server is walked only for another library's copy.
    func test_versions_episode_readsTheShow_andLeavesItOut() async {
        let showRef = MediaItemRef(providerID: home.id, itemID: "s1")
        let shownEpisode = detail(item("e1", on: home, kind: .episode, title: "Pilot", season: 1, episode: 1, show: showRef))
        let show = detail(item("s1", on: home, kind: .show), guid: "plex://show/s")
        serve(home, [show])
        let result = await TitleCopies.versions(of: shownEpisode, on: [home], registry: registry,
                                                cache: TitleCopies.Cache(), guidLookup: guids([home.id: ["s1"]]))
        XCTAssertTrue(result.copies.isEmpty)
        XCTAssertTrue(result.complete)
        XCTAssertFalse(home.playbackCalls.contains("detail(e1)"))
    }

    func test_versions_completeAnswer_isCached() async {
        let shown = detail(item("1", on: home))
        let onDen = item("j1", on: den)
        den.searchItems = [onDen]
        serve(den, [detail(onDen)])
        let cache = TitleCopies.Cache()
        _ = await TitleCopies.versions(of: shown, on: [den], registry: registry, cache: cache, guidLookup: guids([:]))
        let again = await TitleCopies.versions(of: shown, on: [den], registry: registry, cache: cache, guidLookup: guids([:]))
        XCTAssertEqual(again.copies.map(\.item.ref), [onDen.ref])
        XCTAssertEqual(den.playbackCalls, ["detail(j1)"], "the second open asked nothing")
    }

    /// Two views opening the same title at once share one lookup.
    func test_versions_lookupsAtOnce_shareOne() async {
        let shown = detail(item("1", on: home))
        let onDen = item("j1", on: den)
        den.searchItems = [onDen]
        serve(den, [detail(onDen)])
        let cache = TitleCopies.Cache()
        let registry = registry!
        async let first = TitleCopies.versions(of: shown, on: [den], registry: registry, cache: cache, guidLookup: guids([:]))
        async let second = TitleCopies.versions(of: shown, on: [den], registry: registry, cache: cache, guidLookup: guids([:]))
        let (a, b) = await (first, second)
        XCTAssertEqual(a.copies.map(\.item.ref), [onDen.ref])
        XCTAssertEqual(b.copies.map(\.item.ref), [onDen.ref])
        XCTAssertEqual(den.playbackCalls, ["detail(j1)"])
    }

    /// A copy whose detail failed is unknown, not absent: nothing is cached, so the next open asks again.
    func test_versions_failedCopy_isNotCached() async {
        let shown = detail(item("1", on: home))
        let onDen = item("j1", on: den)
        den.searchItems = [onDen]
        serve(den, [detail(onDen)], failing: ["j1"])
        let cache = TitleCopies.Cache()
        let first = await TitleCopies.versions(of: shown, on: [den], registry: registry, cache: cache, guidLookup: guids([:]))
        XCTAssertFalse(first.complete)
        XCTAssertTrue(first.copies.isEmpty)

        serve(den, [detail(onDen)])
        let retry = await TitleCopies.versions(of: shown, on: [den], registry: registry, cache: cache, guidLookup: guids([:]))
        XCTAssertEqual(retry.copies.map(\.item.ref), [onDen.ref])
    }

    func test_cache_expiresAndEmpties() {
        let cache = TitleCopies.Cache()
        let start = Date(timeIntervalSince1970: 0)
        cache.store(TitleCopies.Result(copies: []), for: "k", now: start)
        XCTAssertNotNil(cache.result(for: "k", now: start.addingTimeInterval(60)))
        XCTAssertNil(cache.result(for: "k", now: start.addingTimeInterval(TitleCopies.Cache.lifetime)))

        cache.store(TitleCopies.Result(copies: []), for: "k", now: start)
        cache.removeAll()
        XCTAssertNil(cache.result(for: "k", now: start))
    }

    // MARK: - The title rule

    func test_sameTitle_wordsCloseYearsAndNoConflictingID() {
        XCTAssertTrue(TitleCopies.sameTitle("Spider-Man: Homecoming", year: 2017, ids: [:],
                                            as: "Spider Man Homecoming", year: 2018, ids: [:]))
        XCTAssertFalse(TitleCopies.sameTitle("Dune", year: 1984, ids: [:], as: "Dune", year: 2021, ids: [:]))
        XCTAssertFalse(TitleCopies.sameTitle("Dune", year: 2021, ids: ["tmdb": "438631"],
                                             as: "Dune", year: 2021, ids: ["tmdb": "841"]))
    }
}

