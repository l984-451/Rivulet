// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FavoritesTests.swift
//  RivuletTests
//
//  Marking a movie or show a favorite on each server, and the Favorites page's list.
//

import XCTest
@testable import Rivulet

@MainActor
final class FavoritesTests: XCTestCase {

    private func item(_ id: String, _ title: String, sort: String? = nil, kind: MediaKind = .movie,
                      provider: String = "p") -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: provider, itemID: id), kind: kind, title: title, sortTitle: sort,
                  overview: nil, year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
                  episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: true, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil)
    }

    // MARK: - setFavorite per server

    private final class RatingNetwork: PlexNetworkManager {
        var ratings: [(key: String, rating: Int?)] = []
        override func setRating(serverURL: String, authToken: String, ratingKey: String, rating: Int?) async throws {
            ratings.append((ratingKey, rating))
        }
    }

    func test_plex_favoriteIsFiveStars_andUnfavoriteClearsTheRating() async throws {
        let network = RatingNetwork()
        let plex = PlexProvider(machineIdentifier: "t", displayName: "T", serverURL: "http://plex.test",
                                authToken: "t", networkManager: network)
        let ref = MediaItemRef(providerID: "plex:t", itemID: "42")
        try await plex.setFavorite(true, for: ref)
        try await plex.setFavorite(false, for: ref)
        XCTAssertEqual(network.ratings.map(\.key), ["42", "42"])
        XCTAssertEqual(network.ratings.map(\.rating), [10, nil])
        XCTAssertTrue(PlexUserRating.isFavorite(10), "what setFavorite writes reads back as a favorite")
        XCTAssertFalse(PlexUserRating.isFavorite(6), "three stars is not")
    }

    func test_jellyfin_postsAndDeletesUserFavoriteItems() async throws {
        let server = FakeJellyfinServer()
        server.respond("/UserFavoriteItems/m1", body: "{}")
        let jellyfin = JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "user-1",
                                        client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok",
                                                               transport: server.transport))
        let ref = MediaItemRef(providerID: "jellyfin:srv", itemID: "m1")
        try await jellyfin.setFavorite(true, for: ref)
        try await jellyfin.setFavorite(false, for: ref)
        XCTAssertEqual(server.requests.map(\.httpMethod), ["POST", "DELETE"])
        XCTAssertEqual(server.requests.map { $0.url!.path }, ["/UserFavoriteItems/m1", "/UserFavoriteItems/m1"])
    }

    func test_emby_postsAndDeletesTheUsersRoute() async throws {
        let server = FakeEmbyServer()
        let uid = EmbyLiveFixtures.userID
        server.respond("/Users/\(uid)/FavoriteItems/1076", method: "POST", body: "{}")
        server.respond("/Users/\(uid)/FavoriteItems/1076", method: "DELETE", body: "{}")
        let emby = EmbyProvider(serverID: "srv", displayName: "Emby", userID: uid, policy: EmbySession.Policy(),
                                client: EmbyClient(baseURL: EmbyBrowseFixtures.baseURL, token: "tok",
                                                   transport: server.transport))
        let ref = MediaItemRef(providerID: "emby:srv", itemID: "1076")
        try await emby.setFavorite(true, for: ref)
        try await emby.setFavorite(false, for: ref)
        XCTAssertEqual(server.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" },
                       ["POST /Users/\(uid)/FavoriteItems/1076", "DELETE /Users/\(uid)/FavoriteItems/1076"])
    }

    func test_aServerWithoutFavorites_refusesTheWrite() async {
        do {
            try await StubMediaProvider().setFavorite(true, for: MediaItemRef(providerID: "stub", itemID: "1"))
            XCTFail("the default must throw")
        } catch {}
    }

    // MARK: - The page's list

    func test_order_isTitleOrder_acrossServers() {
        let ordered = FavoritesOrder.byTitle([item("1", "Zodiac"), item("2", "The Abyss", sort: "Abyss"),
                                              item("3", "Alien 10"), item("4", "Alien 2")])
        XCTAssertEqual(ordered.map(\.ref.itemID), ["2", "4", "3", "1"])
    }

    func test_load_composesEachServersMovieAndShowLibraries_andSkipsServersWithoutFavorites() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.favoritesSupported = true
        plex.libraryList = [MediaLibrary(id: "m", providerID: "plex:a", title: "Movies", kind: .movies),
                            MediaLibrary(id: "s", providerID: "plex:a", title: "TV", kind: .shows),
                            MediaLibrary(id: "mu", providerID: "plex:a", title: "Music", kind: .music)]
        plex.favoritesByLibrary = ["m": [item("1", "Heat", provider: "plex:a")],
                                   "s": [item("2", "Andor", kind: .show, provider: "plex:a")],
                                   "mu": [item("9", "Not video", provider: "plex:a")]]
        let jellyfin = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jellyfin.favoritesSupported = true
        jellyfin.libraryList = [MediaLibrary(id: "m", providerID: "jellyfin:s", title: "Films", kind: .movies)]
        jellyfin.favoritesByLibrary = ["m": [item("3", "Heat", provider: "jellyfin:s")]]
        let none = StubMediaProvider(id: "emby:x", kind: .emby)
        none.libraryList = [MediaLibrary(id: "m", providerID: "emby:x", title: "Films", kind: .movies)]
        none.favoritesByLibrary = ["m": [item("4", "Hidden", provider: "emby:x")]]

        let items = await FavoritesFeed.load(from: [plex, jellyfin, none])
        XCTAssertEqual(items.map(\.title), ["Andor", "Heat", "Heat"], "the same title on two servers shows twice")
        XCTAssertEqual(Set(items.map(\.ref.providerID)), ["plex:a", "jellyfin:s"])
        XCTAssertTrue(FavoritesFeed.isAvailable([plex]))
        XCTAssertFalse(FavoritesFeed.isAvailable([none]))
    }
}
