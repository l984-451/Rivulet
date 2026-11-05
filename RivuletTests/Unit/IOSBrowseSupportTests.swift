// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IOSBrowseSupportTests.swift
//  RivuletTests
//
//  The small rules the iOS browse screens lean on: the playback gate, Plex bridging, show and
//  season stubs, hub families, sort mapping, episode order and watchlist membership.
//

import Synchronization
import XCTest
@testable import Rivulet

final class IOSBrowseSupportTests: XCTestCase {
    private func episode(_ id: String, provider: String = "plex:a", number: Int? = nil, season: Int? = nil) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: provider, itemID: id), kind: .episode, title: "Ep \(id)", sortTitle: nil,
            overview: nil, year: 2020, runtime: 1800,
            parentRef: MediaItemRef(providerID: provider, itemID: "season1"),
            grandparentRef: MediaItemRef(providerID: provider, itemID: "show1"),
            seriesTitle: "The Show", episodeNumber: number, seasonNumber: season, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: URL(string: "http://x/still.jpg"), logo: nil),
            parentArtwork: MediaArtwork(poster: URL(string: "http://x/season.jpg"), backdrop: nil, thumbnail: nil, logo: nil),
            grandparentArtwork: MediaArtwork(poster: URL(string: "http://x/show.jpg"), backdrop: URL(string: "http://x/art.jpg"),
                                             thumbnail: nil, logo: nil))
    }

    // MARK: - Gate

    func test_playbackGate_plexJellyfinAndEmbyPlay() {
        XCTAssertTrue(IOSPlaybackGate.canPlay(MediaItemRef(providerID: "plex:a", itemID: "1")))
        XCTAssertTrue(IOSPlaybackGate.canPlay(MediaItemRef(providerID: "jellyfin:s", itemID: "1")))
        XCTAssertTrue(IOSPlaybackGate.canPlay(MediaItemRef(providerID: "emby:e", itemID: "1")))
        XCTAssertFalse(IOSPlaybackGate.canPlay(MediaItemRef(providerID: "iptv:x", itemID: "1")))
    }

    func test_playlistQueue_keepsOrderAndPosition_andNamesRepeatsApart() {
        let a = episode("a", provider: "jellyfin:s"), b = episode("b", provider: "jellyfin:s")
        let queue = PlayQueue(entries: [a, b, a], startingAt: 2)!.playlistQueue
        XCTAssertEqual(queue.entries.map(\.item.ref.itemID), ["a", "b", "a"])
        XCTAssertEqual(Set(queue.entries.map(\.entryID)).count, 3)
        XCTAssertEqual(queue.index, 2)
        XCTAssertEqual(queue.current.item.ref.itemID, "a")
    }

    // MARK: - Plex bridge

    func test_plexServerID_nilForTheSelectedServer_machineIDForAnExtra() {
        MediaItemRef.extraPlexIDs.withLock { $0 = ["plex:extra"] }
        defer { MediaItemRef.extraPlexIDs.withLock { $0 = [] } }
        XCTAssertNil(MediaItemRef(providerID: "plex:sel", itemID: "1").plexServerID)
        XCTAssertEqual(MediaItemRef(providerID: "plex:extra", itemID: "1").plexServerID, "extra")
    }

    func test_plexStub_carriesTheKeyTypeAndServer() {
        MediaItemRef.extraPlexIDs.withLock { $0 = ["plex:extra"] }
        defer { MediaItemRef.extraPlexIDs.withLock { $0 = [] } }
        let stub = episode("77", provider: "plex:extra", number: 3, season: 2).plexStub
        XCTAssertEqual(stub.ratingKey, "77")
        XCTAssertEqual(stub.type, "episode")
        XCTAssertEqual(stub.serverID, "extra")
        XCTAssertEqual(stub.title, "Ep 77")
    }

    func test_plexStub_carriesWhatListsDraw() {
        var item = episode("77", number: 3, season: 2)
        item = MediaItem(
            ref: item.ref, kind: .episode, title: "Ep", sortTitle: nil, overview: "Plot", year: 2020, runtime: 1800,
            parentRef: item.parentRef, grandparentRef: item.grandparentRef, seriesTitle: "The Show", episodeNumber: 3,
            seasonNumber: 2, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 600, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil,
                                  thumbnail: URL(string: "http://srv:32400/library/metadata/77/thumb/9?X-Plex-Token=secret"), logo: nil),
            parentArtwork: nil,
            grandparentArtwork: MediaArtwork(poster: URL(string: "https://metadata-static.plex.tv/x.jpg"), backdrop: nil, thumbnail: nil, logo: nil))
        let stub = item.plexStub
        XCTAssertEqual(stub.thumb, "/library/metadata/77/thumb/9", "no host, no token")
        XCTAssertEqual(stub.grandparentThumb, "https://metadata-static.plex.tv/x.jpg", "the CDN keeps its host")
        XCTAssertEqual(stub.index, 3)
        XCTAssertEqual(stub.parentIndex, 2)
        XCTAssertEqual(stub.grandparentTitle, "The Show")
        XCTAssertEqual(stub.grandparentRatingKey, "show1")
        XCTAssertEqual(stub.viewOffset, 600_000)
        XCTAssertEqual(stub.duration, 1_800_000)
        XCTAssertEqual(stub.summary, "Plot")
    }

    func test_plexType_roundTripsTheKinds() {
        XCTAssertEqual(MediaKind.movie.plexType, "movie")
        XCTAssertEqual(MediaKind.show.plexType, "show")
        XCTAssertEqual(MediaKind.season.plexType, "season")
        XCTAssertEqual(MediaKind.episode.plexType, "episode")
    }

    // MARK: - Stubs

    func test_showAndSeasonStubs_openTheirOwnDetail() {
        let ep = episode("e1", number: 1, season: 2)
        let show = ep.showStub
        XCTAssertEqual(show?.ref, MediaItemRef(providerID: "plex:a", itemID: "show1"))
        XCTAssertEqual(show?.kind, .show)
        XCTAssertEqual(show?.title, "The Show")
        XCTAssertEqual(show?.artwork.poster?.lastPathComponent, "show.jpg")
        let season = ep.seasonStub
        XCTAssertEqual(season?.ref.itemID, "season1")
        XCTAssertEqual(season?.kind, .season)
        XCTAssertEqual(season?.seasonNumber, 2)
        XCTAssertEqual(season?.parentRef?.itemID, "show1")
    }

    func test_showStub_ofASeasonIsItsParent_andMoviesHaveNone() {
        let season = episode("e1", season: 1).seasonStub!
        XCTAssertEqual(season.showStub?.ref.itemID, "show1")
        XCTAssertNil(JellyfinFixtures.mediaItem("m").showStub)
        XCTAssertNil(JellyfinFixtures.mediaItem("m").seasonStub)
    }

    func test_logoOwner_andActionKey() {
        MediaItemRef.extraPlexIDs.withLock { $0 = ["plex:extra"] }
        defer { MediaItemRef.extraPlexIDs.withLock { $0 = [] } }
        let ep = episode("e1", provider: "plex:extra")
        XCTAssertEqual(ep.logoOwner.itemID, "show1")
        XCTAssertEqual(ep.seasonStub?.logoOwner.itemID, "show1")
        XCTAssertEqual(JellyfinFixtures.mediaItem("m").logoOwner.itemID, "m")
        XCTAssertEqual(ep.ref.actionKey, "extra/e1")
        XCTAssertEqual(MediaItemRef(providerID: "plex:sel", itemID: "9").actionKey, "9")
        XCTAssertEqual(MediaItemRef(providerID: "jellyfin:s", itemID: "abc").actionKey, "abc")
    }

    // MARK: - Hubs, sorts, order

    func test_hubFamily_isMatchedOnTheIdentifier() {
        func hub(_ id: String) -> MediaHub { MediaHub(id: id, providerID: "p", title: "t", style: .shelf, items: []) }
        XCTAssertTrue(hub("home.continue").isContinueWatchingFamily)
        XCTAssertTrue(hub("m.continueWatching").isContinueWatchingFamily)
        XCTAssertTrue(hub("home.ondeck").isContinueWatchingFamily)
        XCTAssertTrue(hub("movie.inprogress.1").isContinueWatchingFamily)
        XCTAssertFalse(hub("movie.recentlyadded.1").isContinueWatchingFamily)
    }

    func test_librarySort_mapsToTheSeamsSort() {
        XCTAssertEqual(LibrarySortOption.titleAsc.seamSort, .titleAsc)
        XCTAssertEqual(LibrarySortOption.addedAtDesc.seamSort, .addedAtDesc)
        XCTAssertEqual(LibrarySortOption.releaseDateDesc.seamSort, .releaseDateDesc)
        XCTAssertEqual(LibrarySortOption.ratingDesc.seamSort, .ratingDesc)
        XCTAssertEqual(LibrarySortOption.lastEpisodeAddedDesc.seamSort, .lastContentAddedDesc)
    }

    func test_children_orderByNumber_keepingServerOrderWithoutOne() {
        let items = [episode("c", number: 3), episode("a", number: 1), episode("b", number: 2)]
        XCTAssertEqual(items.sortedByNumber().map(\.ref.itemID), ["a", "b", "c"])
        let seasons = [episode("s2", season: 2), episode("s0", season: 0), episode("s1", season: 1)]
        XCTAssertEqual(seasons.sortedByNumber().map(\.ref.itemID), ["s0", "s1", "s2"])
        let unnumbered = [episode("x"), episode("y")]
        XCTAssertEqual(unnumbered.sortedByNumber().map(\.ref.itemID), ["x", "y"])
    }

    func test_nextUp_resumePointFirst_thenFirstUnwatched_thenFirst() {
        func ep(_ id: String, played: Bool = false, offset: TimeInterval = 0) -> MediaItem {
            var item = episode(id)
            item.userState = MediaUserState(isPlayed: played, viewOffset: offset, isFavorite: false, lastViewedAt: nil)
            return item
        }
        XCTAssertEqual(MediaItem.nextUp(in: [ep("a", played: true), ep("b"), ep("c", offset: 600)])?.ref.itemID, "c")
        XCTAssertEqual(MediaItem.nextUp(in: [ep("a", played: true), ep("b"), ep("c")])?.ref.itemID, "b")
        XCTAssertEqual(MediaItem.nextUp(in: [ep("a", played: true), ep("b", played: true)])?.ref.itemID, "a")
        XCTAssertNil(MediaItem.nextUp(in: []))
    }

    func test_sidebarOrder_serversThenMoviesThenTitle() {
        func lib(_ id: String, _ title: String, _ kind: MediaLibrary.LibraryKind, _ provider: String) -> MediaLibrary {
            MediaLibrary(id: id, providerID: provider, title: title, kind: kind)
        }
        let all = [lib("1", "Zeta", .shows, "jellyfin:s"), lib("2", "TV", .shows, "plex:a"), lib("3", "Movies 10", .movies, "plex:a"),
                   lib("4", "Movies 2", .movies, "plex:a"), lib("5", "Films", .mixed, "emby:e")]
        let ordered = all.sidebarOrder(servers: ["plex:a", "jellyfin:s", "emby:e"])
        XCTAssertEqual(ordered.map(\.id), ["4", "3", "2", "1", "5"], "Movies 2 before Movies 10 (standard compare)")
    }

    func test_languageLabel_namesACode_andLeavesANameAlone() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(LanguageLabel.display("eng", locale: english), "English")
        XCTAssertEqual(LanguageLabel.display("fr", locale: english), "French")
        XCTAssertEqual(LanguageLabel.display("English", locale: english), "English")
        XCTAssertEqual(LanguageLabel.display("Portuguese (Brazil)", locale: english), "Portuguese (Brazil)")
    }

    // MARK: - Watchlist

    func test_watchlistMembership_movieAndShowOnly_byPlexGuidOrExternalId() {
        var movie = JellyfinFixtures.mediaItem("m")
        movie = MediaItem(ref: movie.ref, kind: .movie, title: "M", sortTitle: nil, overview: nil, year: nil, runtime: nil,
                          parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                          userState: movie.userState, artwork: movie.artwork, parentArtwork: nil, grandparentArtwork: nil,
                          externalIDs: ["plex": "plex://movie/abc", "tmdb": "603"])
        XCTAssertEqual(WatchlistMembership.guids(for: movie), ["tmdb://603"])
        XCTAssertTrue(WatchlistMembership.isListed(movie, plexGUIDs: ["plex://movie/abc"], contains: { _ in false }))
        XCTAssertTrue(WatchlistMembership.isListed(movie, plexGUIDs: [], contains: { $0 == "tmdb://603" }))
        XCTAssertFalse(WatchlistMembership.isListed(movie, plexGUIDs: [], contains: { _ in false }))
        XCTAssertTrue(WatchlistMembership.canAnswer(movie))
        XCTAssertFalse(WatchlistMembership.canAnswer(episode("e")), "an episode with no show guid cannot answer")
    }
}
