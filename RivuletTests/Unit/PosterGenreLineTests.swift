// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PosterGenreLineTests.swift
//  RivuletTests
//
//  Settings → Appearance → Genre on Posters: the "Movie · Action" line on a poster's artwork.
//

import XCTest
@testable import Rivulet

@MainActor
final class PosterGenreLineTests: XCTestCase {

    private func item(_ kind: MediaKind, genres: [String]? = ["Action", "Drama"], music: Bool? = nil) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "emby:srv", itemID: "1"),
            kind: kind, title: "Dune", sortTitle: nil, overview: nil, year: 2021, runtime: nil,
            isMusic: music,
            parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil,
            genres: genres
        )
    }

    /// The kind, then the server's first genre.
    func test_moviesAndShows_nameKindAndFirstGenre() {
        XCTAssertEqual(PosterCell.genreLine(for: item(.movie)), "\(String(localized: "Movie")) · Action")
        XCTAssertEqual(PosterCell.genreLine(for: item(.show, genres: ["Drama"])), "\(String(localized: "TV Show")) · Drama")
    }

    /// No genre leaves the kind alone; an empty first genre is skipped.
    func test_missingGenre_keepsTheKind() {
        XCTAssertEqual(PosterCell.genreLine(for: item(.movie, genres: nil)), String(localized: "Movie"))
        XCTAssertEqual(PosterCell.genreLine(for: item(.movie, genres: ["", "Comedy"])), "\(String(localized: "Movie")) · Comedy")
    }

    /// Episodes and seasons show their show's poster, and music is no movie or show.
    func test_otherTiles_haveNoLine() {
        XCTAssertNil(PosterCell.genreLine(for: item(.episode)))
        XCTAssertNil(PosterCell.genreLine(for: item(.season)))
        XCTAssertNil(PosterCell.genreLine(for: item(.movie, music: true)))
    }
}
