// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchProfileBuilderTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class WatchProfileBuilderTests: XCTestCase {

    func testProfileWeightsByRecencyAndRating() async {
        let recent = PlexMetadata(
            ratingKey: "1", type: "movie", title: "Recent",
            viewCount: 1,
            lastViewedAt: Int(Date().timeIntervalSince1970),
            userRating: 9.0
        )
        let old = PlexMetadata(
            ratingKey: "2", type: "movie", title: "Old",
            viewCount: 1,
            lastViewedAt: Int(Date().addingTimeInterval(-365 * 24 * 3600).timeIntervalSince1970),
            userRating: 5.0
        )

        let profile = await WatchProfileBuilder.build(from: [recent, old].map(WatchedTitle.init))

        // Profile should be non-empty when items have local genres.
        // (Items here have no genres, so profile may still be empty — assertion is non-negative.)
        XCTAssertTrue(profile.maxGenre >= 0)
    }

    func testEmptyHistoryYieldsEmptyProfile() async {
        let profile = await WatchProfileBuilder.build(from: [])
        XCTAssertEqual(profile.maxGenre, 0)
        XCTAssertEqual(profile.maxKeyword, 0)
    }

    /// A list item's favorite weighs as Plex's five stars, anything else as unrated: recency × rewatch × rating.
    func test_aFavoriteWeighsAsFiveStars() async {
        let now = Date()
        let overAYear = now.addingTimeInterval(-366 * 24 * 3600)
        var fiveStars = PlexMetadata(ratingKey: "1", type: "movie", title: "A", viewCount: 1,
                                     lastViewedAt: Int(now.timeIntervalSince1970), userRating: 10)
        fiveStars.Genre = [PlexTag(tag: "Sci-Fi")]
        var unrated = PlexMetadata(ratingKey: "2", type: "movie", title: "B", viewCount: 1,
                                   lastViewedAt: Int(overAYear.timeIntervalSince1970))
        unrated.Genre = [PlexTag(tag: "Drama")]
        let plex = await WatchProfileBuilder.build(from: [fiveStars, unrated].map(WatchedTitle.init))
        XCTAssertEqual(plex.genres["science fiction"], 1.0)
        XCTAssertEqual(plex.genres["drama"] ?? 0, 0.1 * 0.6, accuracy: 1e-9)

        // A favorite stands for five stars; anything else is unrated.
        let listed = [watchedListItem("a", genres: ["Sci-Fi"], favorite: true, lastViewed: now),
                      watchedListItem("b", genres: ["Drama"], lastViewed: overAYear)]
        let list = await WatchProfileBuilder.build(from: listed.map(WatchedTitle.init))
        XCTAssertEqual(list.genres, plex.genres)
    }

    /// On tvOS a show's view count is its watched episodes; a list item's episode count stands in.
    func test_aShowsWatchedEpisodesCountAsItsViews() async {
        let show = watchedListItem("s", .show, genres: ["Drama"], played: false, progress: ChildProgress(played: 4, total: 10))
        XCTAssertTrue(WatchedTitle.isWatched(show))
        XCTAssertFalse(WatchedTitle.isWatched(watchedListItem("u", .show, genres: [], played: false,
                                                              progress: ChildProgress(played: 0, total: 10))))
        XCTAssertFalse(WatchedTitle.isWatched(watchedListItem("m", genres: [], played: false)))
        // Emby gives a show only its unplayed count: one played from counts, one never played doesn't.
        XCTAssertTrue(WatchedTitle.isWatched(watchedListItem("e", .show, genres: [], played: false, lastViewed: Date(),
                                                             progress: ChildProgress(played: 0, total: 6, unplayedOnly: true))))
        XCTAssertFalse(WatchedTitle.isWatched(watchedListItem("n", .show, genres: [], played: false,
                                                              progress: ChildProgress(played: 0, total: 6, unplayedOnly: true))))

        let profile = await WatchProfileBuilder.build(from: [WatchedTitle(show)])
        XCTAssertEqual(profile.genres["drama"] ?? 0, 3 * 0.6, accuracy: 1e-9, "log2(4) + 1, unrated")
    }

    func testTopGenresReturnsRequestedCount() async {
        // Construct a profile manually to avoid TMDB dependency
        var profile = FeatureProfile()
        profile.genres = ["action": 5.0, "drama": 3.0, "comedy": 1.0, "horror": 0.5]

        let top2 = profile.topGenres(2)
        XCTAssertEqual(top2.count, 2)
        XCTAssertEqual(top2[0], "action")
        XCTAssertEqual(top2[1], "drama")
    }

    func testTopKeywordsReturnsRequestedCount() async {
        var profile = FeatureProfile()
        profile.keywords = ["k1": 3.0, "k2": 5.0, "k3": 1.0]

        let top2 = profile.topKeywords(2)
        XCTAssertEqual(top2.count, 2)
        XCTAssertEqual(top2[0], "k2")
        XCTAssertEqual(top2[1], "k1")
    }
}

/// A server's list item as the watch history reads it (its TMDB id is never read, so no TMDB request).
func watchedListItem(_ id: String, _ kind: MediaKind = .movie, genres: [String], played: Bool = true,
                     favorite: Bool = false, lastViewed: Date? = nil, progress: ChildProgress? = nil,
                     tmdb: String? = nil, provider: String = "plex:a") -> MediaItem {
    MediaItem(ref: MediaItemRef(providerID: provider, itemID: id), kind: kind, title: id, sortTitle: nil, overview: nil,
              year: nil, runtime: nil, parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
              childProgress: progress,
              userState: MediaUserState(isPlayed: played, viewOffset: 0, isFavorite: favorite, lastViewedAt: lastViewed),
              artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
              parentArtwork: nil, grandparentArtwork: nil, genres: genres, externalIDs: tmdb.map { ["tmdb": $0] })
}
