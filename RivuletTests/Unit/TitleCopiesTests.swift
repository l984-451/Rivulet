// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class TitleCopiesTests: XCTestCase {
    private let home = PlexOwnedLookup.Server(id: "plex:home", url: "https://home", token: "th")
    private let office = PlexOwnedLookup.Server(id: "plex:office", url: "https://office", token: "to")

    private var registry: MediaProviderRegistry!
    private var homeProvider: StubMediaProvider!
    private var officeProvider: StubMediaProvider!

    override func setUp() {
        super.setUp()
        registry = MediaProviderRegistry()
        homeProvider = StubMediaProvider(id: home.id, displayName: "Home")
        officeProvider = StubMediaProvider(id: office.id, displayName: "Office")
        registry.register(homeProvider)
        registry.register(officeProvider)
    }

    // MARK: - Fixtures

    private func item(_ id: String, on server: PlexOwnedLookup.Server, kind: MediaKind = .movie,
                      title: String = "Ted Lasso", season: Int? = nil, episode: Int? = nil) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: server.id, itemID: id),
            kind: kind, title: title, sortTitle: nil, overview: nil, year: nil, runtime: nil,
            parentRef: nil, grandparentRef: nil,
            episodeNumber: episode, seasonNumber: season, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    private func source(_ id: String) -> MediaSource {
        MediaSource(id: id, container: "mkv", duration: 100, bitrate: nil, fileSize: nil, fileName: nil,
                    versionName: nil, videoResolution: "1080", videoTracks: [], audioTracks: [], subtitleTracks: [],
                    streamKind: .directPlay, streamURL: nil)
    }

    private func detail(_ item: MediaItem, files: [String] = [], externalIDs: [String: String] = [:],
                        guid: String? = nil, library: String? = nil) -> MediaItemDetail {
        MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
                        chapters: [], mediaSources: files.map(source), trailerURL: nil, contentRating: nil,
                        nextEpisode: nil, collections: [], externalIDs: externalIDs, plexGUID: guid, library: library)
    }

    /// `provider` answers `fullDetail` from `details` by itemID; any other item, or one in `failing`, throws.
    private func serve(_ provider: StubMediaProvider, _ details: [String: MediaItemDetail],
                       failing: Set<String> = []) {
        provider.detailResultFor = { ref in
            guard !failing.contains(ref.itemID), let detail = details[ref.itemID] else {
                throw MediaProviderError.notFound
            }
            return detail
        }
    }

    /// A guid lookup answering with `answers` (server, ratingKey, library); `failed` servers did not answer.
    private func owners(_ answers: [(PlexOwnedLookup.Server, String, String?)],
                        failed: Set<String> = []) -> TitleCopies.Owners {
        { guids, _ in
            let matches = answers.map { server, key, library in
                var meta = PlexMetadata(ratingKey: key, guid: guids[0], type: "movie", title: "Ted Lasso")
                meta.librarySectionTitle = library
                return PlexOwnedLookup.Match(server: server, item: meta)
            }
            return PlexOwnedLookup.Owned(matches: [guids[0]: matches], failed: failed)
        }
    }

    private let noOwners: TitleCopies.Owners = { _, _ in PlexOwnedLookup.Owned() }

    // MARK: - titles

    func test_titles_guidMatches_carryTheirServerAndLibrary() async {
        let shown = item("1", on: home)
        let found = await TitleCopies.titles(guid: "plex://show/x", of: shown, externalIDs: [:],
                                             on: [home, office], registry: registry,
                                             owners: owners([(home, "1", "TV Shows"), (office, "9", "TV")]))
        XCTAssertEqual(found.found.map(\.ref), [shown.ref, MediaItemRef(providerID: office.id, itemID: "9")])
        XCTAssertEqual(found.found.map(\.library), ["TV Shows", "TV"])
        XCTAssertTrue(found.complete)
    }

    /// Ted Lasso: a legacy-agent library on the same server stores its own guid, so only the
    /// title search finds it, confirmed on a shared tvdb id.
    func test_titles_searchFindsALegacyAgentCopy_besideTheShownOne() async {
        let shown = item("1", on: home, kind: .show)
        let legacy = item("2", on: home, kind: .show)
        homeProvider.searchItems = [shown, legacy]
        serve(homeProvider, ["2": detail(legacy, externalIDs: ["tvdb": "383203"])])
        let found = await TitleCopies.titles(guid: "plex://show/x", of: shown, externalIDs: ["tvdb": "383203"],
                                             on: [home], registry: registry, owners: owners([(home, "1", nil)]))
        XCTAssertEqual(found.found.map(\.ref), [shown.ref, legacy.ref])
    }

    /// A server whose guid lookup already found a copy is not searched: no detail calls there.
    func test_titles_serverWithAGuidCopy_isNotSearched() async {
        let shown = item("1", on: home)
        officeProvider.searchItems = [item("9", on: office), item("8", on: office)]
        serve(officeProvider, [:])
        let found = await TitleCopies.titles(guid: "plex://movie/x", of: shown, externalIDs: ["tmdb": "97546"],
                                             on: [office], registry: registry, owners: owners([(office, "9", nil)]))
        XCTAssertEqual(found.found.map(\.ref.itemID), ["9"])
        XCTAssertTrue(officeProvider.playbackCalls.isEmpty)
    }

    func test_titles_searchSkipsOtherKindsOtherTitlesAndUnconfirmedOnes() async {
        let shown = item("1", on: home, kind: .show)
        let movie = item("2", on: office, kind: .movie)
        let remake = item("3", on: office, kind: .show)
        let spinOff = item("4", on: office, kind: .show, title: "Ted Lasso: The Return")
        officeProvider.searchItems = [movie, remake, spinOff]
        serve(officeProvider, ["2": detail(movie, externalIDs: ["tvdb": "383203"]),
                               "3": detail(remake, externalIDs: ["tvdb": "1"]),
                               "4": detail(spinOff, externalIDs: ["tvdb": "383203"])])
        let found = await TitleCopies.titles(guid: nil, of: shown, externalIDs: ["tvdb": "383203"],
                                             on: [office], registry: registry, owners: noOwners)
        XCTAssertTrue(found.found.isEmpty)
        // Only the same-titled show of the same kind was looked at.
        XCTAssertEqual(officeProvider.playbackCalls, ["detail(3)"])
    }

    func test_titles_withoutExternalIDs_doesNotSearch() async {
        let shown = item("1", on: home)
        homeProvider.searchItems = [item("2", on: home)]
        serve(homeProvider, [:])
        _ = await TitleCopies.titles(guid: nil, of: shown, externalIDs: [:], on: [home],
                                     registry: registry, owners: noOwners)
        XCTAssertTrue(homeProvider.playbackCalls.isEmpty)
    }

    func test_titles_searchLooksAtFourCandidatesAtMost() async {
        let shown = item("1", on: home)
        homeProvider.searchItems = (2...7).map { item(String($0), on: home) }
        serve(homeProvider, Dictionary(uniqueKeysWithValues: (2...7).map {
            (String($0), detail(item(String($0), on: home), externalIDs: ["tmdb": "2"]))
        }))
        _ = await TitleCopies.titles(guid: nil, of: shown, externalIDs: ["tmdb": "1"], on: [home],
                                     registry: registry, owners: noOwners)
        XCTAssertEqual(homeProvider.playbackCalls, ["detail(2)", "detail(3)", "detail(4)", "detail(5)"])
    }

    func test_titles_failures_markTheAnswerIncomplete() async {
        let shown = item("1", on: home)
        let guidFailed = await TitleCopies.titles(guid: "plex://movie/x", of: shown, externalIDs: [:],
                                                  on: [home, office], registry: registry,
                                                  owners: owners([], failed: [office.id]))
        XCTAssertFalse(guidFailed.complete)

        officeProvider.searchError = MediaProviderError.notFound
        let searchFailed = await TitleCopies.titles(guid: nil, of: shown, externalIDs: ["tmdb": "1"],
                                                    on: [office], registry: registry, owners: noOwners)
        XCTAssertFalse(searchFailed.complete)
    }

    // MARK: - copy

    func test_copy_namesItsServer_andFallsBackToTheDetailsLibrary() async throws {
        let other = item("9", on: office)
        serve(officeProvider, ["9": detail(other, files: ["a"], library: "Movies 4K")])
        let answer = await TitleCopies.copy(other.ref, library: nil, registry: registry)
        let copy = try XCTUnwrap(answer ?? nil)
        XCTAssertEqual(copy.server, "Office")
        XCTAssertEqual(copy.library, "Movies 4K")
        XCTAssertEqual(copy.sources.map(\.id), ["a"])

        let namedAnswer = await TitleCopies.copy(other.ref, library: "Films", registry: registry)
        let named = try XCTUnwrap(namedAnswer ?? nil)
        XCTAssertEqual(named.library, "Films")
    }

    func test_copy_withoutFiles_isNoCopy_andAFailureIsUnknown() async {
        let other = item("9", on: office)
        serve(officeProvider, ["9": detail(other)])
        let empty = await TitleCopies.copy(other.ref, library: nil, registry: registry)
        XCTAssertNotNil(empty)
        XCTAssertNil(empty ?? nil)

        serve(officeProvider, [:])
        let failed = await TitleCopies.copy(other.ref, library: nil, registry: registry)
        XCTAssertNil(failed)
    }

    // MARK: - movie

    func test_movie_keepsTheShownLibrary_andListsTheOtherCopies() async {
        let shown = item("1", on: home)
        let other = item("9", on: office)
        serve(officeProvider, ["9": detail(other, files: ["b"])])
        let result = await TitleCopies.movie(shown, guid: "plex://movie/x", externalIDs: [:], on: [home, office],
                                             registry: registry, cache: TitleCopies.Cache(),
                                             owners: owners([(home, "1", "Movies"), (office, "9", "Films")]))
        XCTAssertEqual(result.library, "Movies")
        XCTAssertEqual(result.copies.map(\.item.ref), [other.ref])
        XCTAssertEqual(result.copies.map(\.library), ["Films"])
        XCTAssertTrue(result.complete)
    }

    func test_movie_completeAnswer_isCached() async {
        let shown = item("1", on: home)
        let other = item("9", on: office)
        serve(officeProvider, ["9": detail(other, files: ["b"])])
        let cache = TitleCopies.Cache()
        let lookup = owners([(office, "9", nil)])
        _ = await TitleCopies.movie(shown, guid: "g", externalIDs: [:], on: [home, office],
                                    registry: registry, cache: cache, owners: lookup)
        let again = await TitleCopies.movie(shown, guid: "g", externalIDs: [:], on: [home, office],
                                            registry: registry, cache: cache, owners: lookup)
        XCTAssertEqual(again.copies.map(\.item.ref), [other.ref])
        XCTAssertEqual(officeProvider.playbackCalls, ["detail(9)"], "the second open asked nothing")
    }

    /// A copy whose detail failed is unknown, not absent: nothing is cached, so the next open asks again.
    func test_movie_failedCopy_isNotCached() async {
        let shown = item("1", on: home)
        let other = item("9", on: office)
        serve(officeProvider, ["9": detail(other, files: ["b"])], failing: ["9"])
        let cache = TitleCopies.Cache()
        let lookup = owners([(office, "9", nil)])
        let first = await TitleCopies.movie(shown, guid: "g", externalIDs: [:], on: [home, office],
                                            registry: registry, cache: cache, owners: lookup)
        XCTAssertFalse(first.complete)
        XCTAssertTrue(first.copies.isEmpty)

        serve(officeProvider, ["9": detail(other, files: ["b"])])
        let retry = await TitleCopies.movie(shown, guid: "g", externalIDs: [:], on: [home, office],
                                            registry: registry, cache: cache, owners: lookup)
        XCTAssertEqual(retry.copies.map(\.item.ref), [other.ref])
    }

    // MARK: - episode

    func test_episode_walksToTheSameSeasonAndEpisodeOnTheOtherShow() async {
        let show = item("s1", on: home, kind: .show)
        let episode = item("e1", on: home, kind: .episode, season: 2, episode: 3)
        officeProvider.childrenByParent["s9"] = [item("x1", on: office, kind: .season, season: 1),
                                                 item("x2", on: office, kind: .season, season: 2)]
        officeProvider.childrenByParent["x2"] = [item("y2", on: office, kind: .episode, season: 2, episode: 2),
                                                 item("y3", on: office, kind: .episode, season: 2, episode: 3)]
        serve(officeProvider, ["y3": detail(item("y3", on: office, kind: .episode), files: ["4k"])])
        let result = await TitleCopies.episode(episode, of: show, showDetail: detail(show, guid: "plex://show/x"),
                                               on: [home, office], registry: registry, cache: TitleCopies.Cache(),
                                               owners: owners([(home, "s1", "TV Shows"), (office, "s9", nil)]))
        XCTAssertEqual(result.library, "TV Shows")
        XCTAssertEqual(result.copies.map(\.item.ref.itemID), ["y3"])
        XCTAssertEqual(result.copies.first?.server, "Office")
    }

    func test_episode_missingOnTheOtherShow_isNoCopy() async {
        let show = item("s1", on: home, kind: .show)
        let episode = item("e1", on: home, kind: .episode, season: 4, episode: 1)
        officeProvider.childrenByParent["s9"] = [item("x1", on: office, kind: .season, season: 1)]
        let result = await TitleCopies.episode(episode, of: show, showDetail: detail(show, guid: "plex://show/x"),
                                               on: [home, office], registry: registry, cache: TitleCopies.Cache(),
                                               owners: owners([(office, "s9", nil)]))
        XCTAssertTrue(result.copies.isEmpty)
        XCTAssertTrue(result.complete)
    }

    func test_episode_withoutNumbers_looksNothingUp() async {
        let show = item("s1", on: home, kind: .show)
        let special = item("e1", on: home, kind: .episode)
        let asked = Flag()
        let result = await TitleCopies.episode(special, of: show, showDetail: detail(show, guid: "plex://show/x"),
                                               on: [home], registry: registry, cache: TitleCopies.Cache(),
                                               owners: { _, _ in asked.set(); return PlexOwnedLookup.Owned() })
        XCTAssertTrue(result.copies.isEmpty)
        XCTAssertFalse(asked.value)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
