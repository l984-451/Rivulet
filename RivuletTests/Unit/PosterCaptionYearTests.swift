// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PosterCaptionYearTests.swift
//  RivuletTests
//
//  Settings → Appearance → Year Under Titles: which tiles carry a year, and the row room it takes.
//

import XCTest
@testable import Rivulet

@MainActor
final class PosterCaptionYearTests: XCTestCase {

    private let keys = [MediaRowMetrics.posterTitlesKey, MediaRowMetrics.posterYearsKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        super.tearDown()
    }

    private func item(_ kind: MediaKind, year: Int? = 2021) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "emby:srv", itemID: "1"),
            kind: kind, title: "Dune", sortTitle: nil, overview: nil, year: year, runtime: nil,
            parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    /// Movies and shows get their year; an episode's or season's line already names it.
    func test_year_onlyForMoviesAndShows() {
        XCTAssertEqual(PosterCaption.year(for: item(.movie)), 2021)
        XCTAssertEqual(PosterCaption.year(for: item(.show)), 2021)
        XCTAssertNil(PosterCaption.year(for: item(.episode)))
        XCTAssertNil(PosterCaption.year(for: item(.season)))
        XCTAssertNil(PosterCaption.year(for: item(.movie, year: nil)))
    }

    /// The year line adds room only while titles are on; Continue Watching keeps the title line alone.
    func test_captionRoom_followsBothSettings() {
        let title = MediaRowMetrics.posterTitleLineHeight
        let withYear = title + MediaRowMetrics.posterYearLineHeight

        UserDefaults.standard.set(true, forKey: MediaRowMetrics.posterTitlesKey)
        UserDefaults.standard.set(false, forKey: MediaRowMetrics.posterYearsKey)
        XCTAssertEqual(MediaRowMetrics.posterCaptionSpace, title)

        UserDefaults.standard.set(true, forKey: MediaRowMetrics.posterYearsKey)
        XCTAssertEqual(MediaRowMetrics.posterCaptionSpace, withYear)
        XCTAssertEqual(MediaRowMetrics.posterTitleLineSpace, title)

        // Years alone show nothing: they hang under the title line.
        UserDefaults.standard.set(false, forKey: MediaRowMetrics.posterTitlesKey)
        XCTAssertFalse(MediaRowMetrics.showsPosterYears)
        XCTAssertEqual(MediaRowMetrics.posterCaptionSpace, 0)
        XCTAssertEqual(MediaRowMetrics.posterTitleLineSpace, 0)
    }
}
