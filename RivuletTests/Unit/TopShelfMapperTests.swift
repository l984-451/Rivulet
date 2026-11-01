// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class TopShelfMapperTests: XCTestCase {

    // Follows the established codebase pattern: `var m = PlexMetadata()` then set
    // `var` fields (see PlexMediaMapperTests). PlexMetadata() is an all-defaulted init.
    private func meta(
        ratingKey: String,
        type: String,
        title: String,
        grandparentTitle: String? = nil,
        art: String? = nil,
        grandparentArt: String? = nil,
        parentThumb: String? = nil,
        thumb: String? = nil,
        lastViewedAt: Int? = nil
    ) -> PlexMetadata {
        var m = PlexMetadata()
        m.ratingKey = ratingKey
        m.type = type
        m.title = title
        m.grandparentTitle = grandparentTitle
        m.art = art
        m.grandparentArt = grandparentArt
        m.parentThumb = parentThumb
        m.thumb = thumb
        m.lastViewedAt = lastViewedAt
        return m
    }

    // The carousel shows the BARE episode name as the title (the show name
    // rides the contextTitle line above, Apple-TV+-style). The mapper uses
    // `m.title` directly, NOT `fullEpisodeTitle` — so no "SxxExx - " prefix.

    private let server = "http://plex.local:32400"
    private let token = "TESTTOKEN"

    // The regression guard for #194: a movie MUST survive mapping.
    func testMovieIsIncluded() {
        let input = [
            meta(ratingKey: "m1", type: "movie", title: "Blade Runner", art: "/art/m1", thumb: "/thumb/m1", lastViewedAt: 200),
            meta(ratingKey: "e1", type: "episode", title: "Ozymandias", grandparentTitle: "Breaking Bad", grandparentArt: "/art/bb", thumb: "/thumb/e1", lastViewedAt: 100)
        ]
        let items = TopShelfMapper.items(from: input, serverURL: server, token: token)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.ratingKey == "m1" }, "Movie must not be dropped (regression #194)")
    }

    func testRecentlyAddedNewestFirstSkipsWatchedAndOtherTypes() {
        var old = meta(ratingKey: "old", type: "movie", title: "Old", thumb: "/o")
        old.addedAt = 100
        var new = meta(ratingKey: "new", type: "movie", title: "New", thumb: "/n")
        new.addedAt = 300
        var seen = meta(ratingKey: "seen", type: "movie", title: "Seen", thumb: "/s")
        seen.addedAt = 400
        seen.viewCount = 1
        var album = meta(ratingKey: "alb", type: "album", title: "Album", thumb: "/a")
        album.addedAt = 500
        let items = TopShelfMapper.recentlyAddedItems(from: [old, seen, new, album], serverURL: server, token: token, limit: 5)
        XCTAssertEqual(items.map(\.ratingKey), ["new", "old"])
        XCTAssertEqual(items.first?.progress, 0)
    }

    func testSortedByLastViewedDescending() {
        let input = [
            meta(ratingKey: "a", type: "movie", title: "A", thumb: "/a", lastViewedAt: 50),
            meta(ratingKey: "b", type: "movie", title: "B", thumb: "/b", lastViewedAt: 300),
            meta(ratingKey: "c", type: "movie", title: "C", thumb: "/c", lastViewedAt: 150)
        ]
        let items = TopShelfMapper.items(from: input, serverURL: server, token: token)
        XCTAssertEqual(items.map(\.ratingKey), ["b", "c", "a"])
    }

    func testDedupeByRatingKeyKeepsFirst() {
        let input = [
            meta(ratingKey: "x", type: "movie", title: "First", thumb: "/1", lastViewedAt: 100),
            meta(ratingKey: "x", type: "movie", title: "Dup",   thumb: "/2", lastViewedAt: 100)
        ]
        let items = TopShelfMapper.items(from: input, serverURL: server, token: token)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "First")
    }

    func testCapsAtLimit() {
        let input = (0..<10).map { meta(ratingKey: "k\($0)", type: "movie", title: "T\($0)", thumb: "/\($0)", lastViewedAt: 10 - $0) }
        let items = TopShelfMapper.items(from: input, serverURL: server, token: token, limit: 5)
        XCTAssertEqual(items.count, 5)
    }

    func testEpisodeTextUsesEpisodeNameAndShowSubtitle() {
        let input = [meta(ratingKey: "e1", type: "episode", title: "Ozymandias", grandparentTitle: "Breaking Bad", grandparentArt: "/art/bb", lastViewedAt: 100)]
        let item = TopShelfMapper.items(from: input, serverURL: server, token: token).first
        // Bare episode name (no "SxxExx - " prefix); show name is the subtitle.
        XCTAssertEqual(item?.title, "Ozymandias")
        XCTAssertEqual(item?.subtitle, "Breaking Bad")
    }

    func testMovieHasNoSubtitle() {
        let input = [meta(ratingKey: "m1", type: "movie", title: "Blade Runner", thumb: "/t", lastViewedAt: 100)]
        let item = TopShelfMapper.items(from: input, serverURL: server, token: token).first
        XCTAssertNil(item?.subtitle)
    }

    func testWideURLPrefersBackdropAndCarriesToken() {
        let movie = meta(ratingKey: "m1", type: "movie", title: "M", art: "/art/m1", thumb: "/thumb/m1", lastViewedAt: 100)
        let ep    = meta(ratingKey: "e1", type: "episode", title: "E", grandparentTitle: "S", grandparentArt: "/art/bb", parentThumb: nil, thumb: "/thumb/e1", lastViewedAt: 90)
        let items = TopShelfMapper.items(from: [movie, ep], serverURL: server, token: token)
        let m = items.first { $0.ratingKey == "m1" }!
        let e = items.first { $0.ratingKey == "e1" }!
        XCTAssertTrue(m.wideImageURL.contains("/art/m1"))
        XCTAssertTrue(m.wideImageURL.contains("X-Plex-Token=\(token)"))
        XCTAssertTrue(e.wideImageURL.contains("/art/bb"))  // grandparentArt preferred for episode
    }

    func testWideURLFallsBackToThumbWhenNoBackdrop() {
        let movie = meta(ratingKey: "m1", type: "movie", title: "M", art: nil, thumb: "/thumb/only", lastViewedAt: 100)
        let item = TopShelfMapper.items(from: [movie], serverURL: server, token: token).first!
        XCTAssertTrue(item.wideImageURL.contains("/thumb/only"))
    }

    // MARK: - Jellyfin and merge

    private func jellyfinEpisode(_ id: String, lastViewed: Date?) -> MediaItem {
        let url = { (s: String) in URL(string: "http://jf.local/Items/\(s)") }
        return MediaItem(
            ref: MediaItemRef(providerID: "jellyfin:abc", itemID: id),
            kind: .episode, title: "Ep \(id)", sortTitle: nil, overview: nil,
            year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            seriesTitle: "Show", episodeNumber: 1, seasonNumber: 1, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: lastViewed),
            artwork: MediaArtwork(poster: url("ep"), backdrop: url("backdrop"), thumbnail: nil, logo: url("logo")),
            parentArtwork: nil,
            grandparentArtwork: MediaArtwork(poster: url("showposter"), backdrop: nil, thumbnail: nil, logo: nil)
        )
    }

    func testJellyfinItemCarriesProviderLogoAndShowPoster() {
        let item = TopShelfMapper.items(from: [jellyfinEpisode("j1", lastViewed: nil)]).first!
        XCTAssertEqual(item.serverIdentifier, "jellyfin:abc")
        XCTAssertEqual(item.subtitle, "Show")
        XCTAssertEqual(item.logoImageURL, "http://jf.local/Items/logo")
        XCTAssertEqual(item.imageURL, "http://jf.local/Items/showposter")
        XCTAssertEqual(item.wideImageURL, "http://jf.local/Items/backdrop")
        XCTAssertEqual(item.lastWatched, .distantPast)
    }

    func testMergeOrdersAcrossServersByLastWatched() {
        let plex = TopShelfMapper.items(from: [
            meta(ratingKey: "p300", type: "movie", title: "A", lastViewedAt: 300),
            meta(ratingKey: "p100", type: "movie", title: "B", lastViewedAt: 100),
        ], serverURL: server, token: token)
        let jellyfin = TopShelfMapper.items(from: [
            jellyfinEpisode("j200", lastViewed: Date(timeIntervalSince1970: 200)),
            jellyfinEpisode("jUpNext1", lastViewed: nil),
            jellyfinEpisode("jUpNext2", lastViewed: nil),
        ])
        let merged = TopShelfMapper.merge(plex, jellyfin, limit: 4)
        // Never-watched items keep their server's order, after everything watched.
        XCTAssertEqual(merged.map(\.ratingKey), ["p300", "j200", "p100", "jUpNext1"])
    }
}
