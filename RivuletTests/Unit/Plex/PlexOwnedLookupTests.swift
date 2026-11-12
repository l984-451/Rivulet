// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PlexOwnedLookupTests: XCTestCase {
    private let first = PlexOwnedLookup.Server(id: "plex:a", url: "https://a", token: "ta")
    private let second = PlexOwnedLookup.Server(id: "plex:b", url: "https://b", token: "tb")

    private func movie(_ key: String) -> PlexMetadata {
        PlexMetadata(ratingKey: key, guid: "plex://movie/x", type: "movie", title: "X")
    }

    func test_copies_collectsEachServersCopyInOrder() {
        let found = PlexOwnedLookup.copies(of: ["plex://movie/x"], servers: [first, second],
                                           answers: [0: [movie("1")], 1: [movie("2")]])
        XCTAssertEqual(found["plex://movie/x"]?.map(\.server), [first, second])
    }

    func test_copies_ignoresUnaskedGuidsAndFailedServers() {
        let stray = PlexMetadata(ratingKey: "3", guid: "plex://movie/other", type: "movie", title: "Other")
        let found = PlexOwnedLookup.copies(of: ["plex://movie/x"], servers: [first, second], answers: [1: [stray]])
        XCTAssertTrue(found.isEmpty)
    }

    func test_sharesExternalID_matchesOnAnyCommonID() {
        XCTAssertTrue(PlexOwnedLookup.sharesExternalID(["tvdb": "383203", "imdb": "tt10986410"], ["tvdb": "383203"]))
        XCTAssertFalse(PlexOwnedLookup.sharesExternalID(["tmdb": "97546"], ["tmdb": "1"]))
        XCTAssertFalse(PlexOwnedLookup.sharesExternalID(["tmdb": ""], ["tmdb": ""]))
        XCTAssertFalse(PlexOwnedLookup.sharesExternalID([:], ["tmdb": "97546"]))
    }
}
