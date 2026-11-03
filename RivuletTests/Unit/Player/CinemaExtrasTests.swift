// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// #491: trailers and pre-rolls before a movie.
final class CinemaExtrasTests: XCTestCase {
    func test_appliesOnlyToAMovieStartedFromTheBeginning() {
        XCTAssertTrue(CinemaExtras.applies(type: "movie", startOffset: nil, inPlaylist: false, count: 2))
        XCTAssertTrue(CinemaExtras.applies(type: "movie", startOffset: 0, inPlaylist: false, count: 1))
        XCTAssertFalse(CinemaExtras.applies(type: "movie", startOffset: nil, inPlaylist: false, count: 0), "off by default")
        XCTAssertFalse(CinemaExtras.applies(type: "movie", startOffset: 90, inPlaylist: false, count: 2), "a resume goes straight in")
        XCTAssertFalse(CinemaExtras.applies(type: "movie", startOffset: nil, inPlaylist: true, count: 2))
        XCTAssertFalse(CinemaExtras.applies(type: "episode", startOffset: nil, inPlaylist: false, count: 2))
        XCTAssertFalse(CinemaExtras.applies(type: "clip", startOffset: nil, inPlaylist: false, count: 2), "a trailer has no trailers")
    }

    /// The shape of PMS 1.43.5's reply: trailers, pre-rolls, then the movie.
    func test_clipsKeepTheServersOrderAndDropTheMovie() {
        func item(_ key: String, _ type: String) -> PlexMetadata {
            var meta = PlexMetadata()
            meta.ratingKey = key
            meta.type = type
            return meta
        }
        let clips = PlexNetworkManager.cinemaClips(in: [item("22", "clip"), item("238", "clip"), item("3", "movie")])
        XCTAssertEqual(clips.map(\.ratingKey), ["22", "238"])
    }
}
