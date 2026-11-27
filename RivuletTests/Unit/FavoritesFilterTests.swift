// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest
@testable import Rivulet

/// The Favorites page's filter (`FavoritesWatchFilter`) and hero (`HomeHero.favoriteItems`).
final class FavoritesFilterTests: XCTestCase {

    private func item(_ id: String, played: Bool, backdrop: Bool = true, kind: MediaKind = .movie) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "emby:test", itemID: id), kind: kind, title: id, sortTitle: nil,
            overview: nil, year: 2020, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: played, viewOffset: 0, isFavorite: true, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: backdrop ? URL(string: "https://example.com/\(id).jpg") : nil,
                                  thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    func test_filterKeepsWhatItNames() {
        let items = [item("a", played: true), item("b", played: false), item("c", played: true)]
        XCTAssertEqual(FavoritesWatchFilter.all.apply(items).map(\.title), ["a", "b", "c"])
        XCTAssertEqual(FavoritesWatchFilter.unwatched.apply(items).map(\.title), ["b"])
        XCTAssertEqual(FavoritesWatchFilter.watched.apply(items).map(\.title), ["a", "c"])
    }

    func test_heroTakesBackdropsOnly_atMostTen() {
        let items = (0..<14).map { item("t\($0)", played: false) } + [item("bare", played: false, backdrop: false)]
        let hero = HomeHero.favoriteItems(items)
        XCTAssertEqual(hero.count, 10)
        XCTAssertFalse(hero.contains { $0.title == "bare" })
    }

    func test_heroOrderIsStableWithinALaunch() {
        let items = (0..<8).map { item("t\($0)", played: false) }
        XCTAssertEqual(HomeHero.favoriteItems(items).map(\.title), HomeHero.favoriteItems(items.reversed()).map(\.title))
    }
}
