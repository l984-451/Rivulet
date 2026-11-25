// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBMediaMapperTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class TMDBMediaMapperTests: XCTestCase {

    // MARK: - ItemID encoding

    func testEncodeItemIDIncludesTypeAndId() {
        XCTAssertEqual(TMDBMediaMapper.encodeItemID(tmdbId: 42, type: .movie), "movie:42")
        XCTAssertEqual(TMDBMediaMapper.encodeItemID(tmdbId: 100, type: .tv), "tv:100")
    }

    func testDecodeItemIDRoundTrip() {
        let encoded = TMDBMediaMapper.encodeItemID(tmdbId: 1234, type: .tv)
        let decoded = TMDBMediaMapper.decodeItemID(encoded)
        XCTAssertEqual(decoded?.tmdbId, 1234)
        XCTAssertEqual(decoded?.type, .tv)
    }

    func testDecodeItemIDDistinguishesMovieAndTV() {
        let movie = TMDBMediaMapper.decodeItemID("movie:100")
        let tv = TMDBMediaMapper.decodeItemID("tv:100")
        XCTAssertEqual(movie?.type, .movie)
        XCTAssertEqual(tv?.type, .tv)
        XCTAssertEqual(movie?.tmdbId, tv?.tmdbId)
    }

    func testDecodeItemIDRejectsBareNumeric() {
        // Strict decode — legacy bare-numeric format no longer valid, forces
        // callers to go through the mapper which always encodes with type.
        XCTAssertNil(TMDBMediaMapper.decodeItemID("603"))
    }

    func testDecodeItemIDRejectsUnknownType() {
        XCTAssertNil(TMDBMediaMapper.decodeItemID("person:42"))
        XCTAssertNil(TMDBMediaMapper.decodeItemID("foo:42"))
    }

    func testDecodeItemIDRejectsGarbage() {
        XCTAssertNil(TMDBMediaMapper.decodeItemID(""))
        XCTAssertNil(TMDBMediaMapper.decodeItemID("movie:"))
        XCTAssertNil(TMDBMediaMapper.decodeItemID(":42"))
        XCTAssertNil(TMDBMediaMapper.decodeItemID("movie:abc"))
    }

    // MARK: - Mapper produces encoded refs

    func testMapperUsesEncodedItemIDForTVItem() {
        let tv = TMDBListItem(
            id: 777,
            title: "Some Show",
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            voteAverage: nil,
            mediaType: .tv
        )
        let item = TMDBMediaMapper.item(tv)
        XCTAssertEqual(item.ref.itemID, "tv:777")
        XCTAssertEqual(item.kind, .show)
    }

    func testMapperUsesEncodedItemIDForMovieItem() {
        let movie = TMDBListItem(
            id: 888,
            title: "Some Movie",
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            voteAverage: nil,
            mediaType: .movie
        )
        let item = TMDBMediaMapper.item(movie)
        XCTAssertEqual(item.ref.itemID, "movie:888")
        XCTAssertEqual(item.kind, .movie)
    }

    // MARK: - Poster sizing

    func testSizedPosterTakesTheSmallestPosterWidthThatCovers() throws {
        let movie = TMDBListItem(id: 1, title: "M", overview: nil, posterPath: "/p.jpg", backdropPath: "/b.jpg",
                                 releaseDate: nil, voteAverage: nil, mediaType: .movie)
        let artwork = TMDBMediaMapper.item(movie).artwork
        let poster = try XCTUnwrap(artwork.poster)
        XCTAssertEqual(TMDBMediaMapper.sizedPoster(poster, width: 300).absoluteString, "https://image.tmdb.org/t/p/w342/p.jpg")
        XCTAssertEqual(TMDBMediaMapper.sizedPoster(poster, width: 480).absoluteString, "https://image.tmdb.org/t/p/w500/p.jpg")
        XCTAssertEqual(TMDBMediaMapper.sizedPoster(poster, width: 960), poster)
        // Backdrops, logos, cast photos and server art keep their own size.
        for url in [try XCTUnwrap(artwork.backdrop),
                    try XCTUnwrap(URL(string: "https://image.tmdb.org/t/p/w500/l.png")),
                    try XCTUnwrap(URL(string: "https://image.tmdb.org/t/p/w342/c.jpg")),
                    try XCTUnwrap(URL(string: "http://h:32400/library/metadata/1/thumb/2?X-Plex-Token=t"))] {
            XCTAssertEqual(TMDBMediaMapper.sizedPoster(url, width: 300), url)
        }
    }
}
