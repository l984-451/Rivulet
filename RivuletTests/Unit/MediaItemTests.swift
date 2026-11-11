// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItemTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaItemTests: XCTestCase {
    func test_id_returnsRef() {
        let ref = MediaItemRef(providerID: "plex:abc", itemID: "1")
        let item = MediaItem(
            ref: ref,
            kind: .movie,
            title: "Inception",
            sortTitle: nil,
            overview: nil,
            year: 2010,
            runtime: 8880,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
        XCTAssertEqual(item.id, ref)
    }

    func test_seasonShow_isTheShowWithItsPoster() {
        let show = MediaItemRef(providerID: "plex:abc", itemID: "10")
        let showPoster = URL(string: "https://x/show.jpg")
        let season = MediaItem(
            ref: MediaItemRef(providerID: "plex:abc", itemID: "11"), kind: .season, title: "Season 1",
            sortTitle: nil, overview: nil, year: nil, runtime: nil, parentRef: show, grandparentRef: nil,
            seriesTitle: "Le Crime lui va si bien", episodeNumber: nil, seasonNumber: 1, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: URL(string: "https://x/season.jpg"), backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: MediaArtwork(poster: showPoster, backdrop: nil, thumbnail: nil, logo: nil),
            grandparentArtwork: nil)
        let stub = season.seasonShow
        XCTAssertEqual(stub?.ref, show)
        XCTAssertEqual(stub?.kind, .show)
        XCTAssertEqual(stub?.title, "Le Crime lui va si bien")
        XCTAssertEqual(stub?.artwork.poster, showPoster)
        XCTAssertNil(stub?.seasonShow)
    }
}
