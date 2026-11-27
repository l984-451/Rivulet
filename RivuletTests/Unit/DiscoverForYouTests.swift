// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class DiscoverForYouTests: XCTestCase {
    private func library(_ id: String, _ kind: MediaLibrary.LibraryKind, on provider: String = "plex:a") -> MediaLibrary {
        MediaLibrary(id: id, providerID: provider, title: id, kind: kind)
    }

    private func tmdb(_ id: Int) -> TMDBListItem {
        TMDBListItem(id: id, title: "T\(id)", overview: nil, posterPath: nil, backdropPath: nil, releaseDate: nil,
                     voteAverage: nil, mediaType: .movie)
    }

    func test_historyReadsTheFirstThreeMovieOrTVLibraries_watchedTitlesOnly_inOrder() async {
        // One library asked per stub: the libraries are asked at once.
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.itemsByLibrary = [
            "m": [watchedListItem("m1", genres: ["Drama"]), watchedListItem("m2", genres: ["War"], played: false)],
            "music": [watchedListItem("x", genres: ["Rock"])],
        ]
        let other = StubMediaProvider(id: "plex:b", kind: .plex)
        other.itemsByLibrary = ["t": [watchedListItem("t1", .show, genres: ["Comedy"], played: false,
                                                      progress: ChildProgress(played: 2, total: 8), provider: "plex:b")]]
        let jellyfin = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jellyfin.itemsByLibrary = ["j": [watchedListItem("j1", genres: ["Horror"], provider: "jellyfin:s")],
                                   "late": [watchedListItem("l1", genres: ["Western"], provider: "jellyfin:s")]]
        let shown = [library("m", .movies), library("music", .music), library("t", .shows, on: "plex:b"),
                     library("j", .movies, on: "jellyfin:s"), library("late", .shows, on: "jellyfin:s")]

        let history = await DiscoverForYou.watchHistory(shown, providers: [plex, other, jellyfin])

        XCTAssertEqual(history.map(\.genres), [["Drama"], ["Comedy"], ["Horror"]], "library order, though asked at once")
        XCTAssertEqual(plex.itemsRequests.map { $0.library }, ["m"])
        XCTAssertEqual(jellyfin.itemsRequests.map { $0.library }, ["j"], "a fourth library isn't read")
        XCTAssertEqual(plex.itemsRequests.first?.page, Page(offset: 0, limit: 200))
        XCTAssertEqual(plex.itemsRequests.first?.sort, SortOption.titleAsc)
    }

    func test_historyKeepsAtMost120WatchedTitles() async {
        let plex = StubMediaProvider(id: "plex:a")
        plex.itemsByLibrary = ["m": (0..<200).map { watchedListItem("m\($0)", genres: ["Drama"]) }]

        let history = await DiscoverForYou.watchHistory([library("m", .movies)], providers: [plex])

        XCTAssertEqual(history.count, 120)
    }

    func test_theRowLeavesOutTitlesAServerOwns_andLoadsOncePerKey() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.itemsByLibrary = ["m": (0..<5).map { watchedListItem("m\($0)", genres: ["Action", "Thriller", "Science Fiction"]) }]
        plex.ownedItemsResult = [watchedListItem("copy", genres: [], tmdb: "1")]
        let fetcher = StubDiscoverFetcher()
        fetcher.movies = [tmdb(1), tmdb(2)]
        let forYou = DiscoverForYou()
        let ownership = DiscoverOwnership()

        for _ in 0..<2 {
            await forYou.load(key: ["1"], libraries: [library("m", .movies)], providers: [plex], ownership: ownership,
                              isShown: { _ in true }, service: DiscoverRecommendationService(fetcher: fetcher))
        }

        XCTAssertEqual(forYou.items.map { $0.tmdbID }, [2])
        XCTAssertEqual(fetcher.calls, 2, "one load: movies and shows")
        XCTAssertEqual(plex.itemsRequests.count, 1)
    }
}
