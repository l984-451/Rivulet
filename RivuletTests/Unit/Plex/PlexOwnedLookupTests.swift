// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PlexOwnedLookupTests: XCTestCase {
    private let first = PlexOwnedLookup.Server(id: "plex:a", url: "https://a", token: "ta")
    private let second = PlexOwnedLookup.Server(id: "plex:b", url: "https://b", token: "tb")

    private func movie(_ key: String, resolution: String? = nil, bitrate: Int? = nil) -> PlexMetadata {
        var item = PlexMetadata(ratingKey: key, guid: "plex://movie/x", type: "movie", title: "X")
        if resolution != nil || bitrate != nil {
            item.Media = [PlexMedia(id: Int(key) ?? 0, duration: nil, bitrate: bitrate, width: nil, height: nil,
                                    aspectRatio: nil, audioChannels: nil, audioCodec: nil, videoCodec: nil,
                                    videoResolution: resolution, container: nil, videoFrameRate: nil, Part: nil)]
        }
        return item
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

    func test_best_prefersHigherResolution() {
        let hd = PlexOwnedLookup.Match(server: first, item: movie("1", resolution: "1080", bitrate: 20000))
        let uhd = PlexOwnedLookup.Match(server: second, item: movie("2", resolution: "4k", bitrate: 15000))
        XCTAssertEqual(PlexOwnedLookup.best([hd, uhd])?.server, second)
    }

    func test_best_sameResolution_prefersHigherBitrate() {
        let low = PlexOwnedLookup.Match(server: first, item: movie("1", resolution: "1080", bitrate: 8000))
        let high = PlexOwnedLookup.Match(server: second, item: movie("2", resolution: "1080", bitrate: 30000))
        XCTAssertEqual(PlexOwnedLookup.best([low, high])?.server, second)
    }

    func test_best_tieOrNoFileInfo_keepsTheEarliest() {
        let a = PlexOwnedLookup.Match(server: first, item: movie("1", resolution: "1080", bitrate: 10000))
        let b = PlexOwnedLookup.Match(server: second, item: movie("2", resolution: "1080", bitrate: 10000))
        XCTAssertEqual(PlexOwnedLookup.best([a, b])?.server, first)

        let showA = PlexOwnedLookup.Match(server: first, item: movie("1"))
        let showB = PlexOwnedLookup.Match(server: second, item: movie("2"))
        XCTAssertEqual(PlexOwnedLookup.best([showA, showB])?.server, first)
    }

    func test_best_knownFileBeatsUnknown() {
        let unknown = PlexOwnedLookup.Match(server: first, item: movie("1"))
        let known = PlexOwnedLookup.Match(server: second, item: movie("2", resolution: "720", bitrate: 4000))
        XCTAssertEqual(PlexOwnedLookup.best([unknown, known])?.server, second)
    }

    // MARK: - betterElsewhere (the watchlist's pick)

    func test_betterElsewhere_aBetterCopyElsewhereWins() {
        let selected = PlexOwnedLookup.Match(server: first, item: movie("1", resolution: "1080", bitrate: 10000))
        let uhd = PlexOwnedLookup.Match(server: second, item: movie("2", resolution: "4k", bitrate: 20000))
        XCTAssertEqual(PlexOwnedLookup.betterElsewhere(selected: selected, elsewhere: [uhd])?.server, second)
    }

    func test_betterElsewhere_tieOrWorse_staysOnTheSelectedServer() {
        let selected = PlexOwnedLookup.Match(server: first, item: movie("1", resolution: "1080", bitrate: 10000))
        let same = PlexOwnedLookup.Match(server: second, item: movie("2", resolution: "1080", bitrate: 10000))
        let worse = PlexOwnedLookup.Match(server: second, item: movie("3", resolution: "720", bitrate: 4000))
        XCTAssertNil(PlexOwnedLookup.betterElsewhere(selected: selected, elsewhere: [same]))
        XCTAssertNil(PlexOwnedLookup.betterElsewhere(selected: selected, elsewhere: [worse]))
    }

    func test_betterElsewhere_ownedOnlyElsewhere_opensThatCopy() {
        let only = PlexOwnedLookup.Match(server: second, item: movie("2"))
        XCTAssertEqual(PlexOwnedLookup.betterElsewhere(selected: nil, elsewhere: [only])?.server, second)
        XCTAssertNil(PlexOwnedLookup.betterElsewhere(selected: nil, elsewhere: []))
    }

    func test_sharesExternalID_matchesOnAnyCommonID() {
        XCTAssertTrue(PlexOwnedLookup.sharesExternalID(["tvdb": "383203", "imdb": "tt10986410"], ["tvdb": "383203"]))
        XCTAssertFalse(PlexOwnedLookup.sharesExternalID(["tmdb": "97546"], ["tmdb": "1"]))
        XCTAssertFalse(PlexOwnedLookup.sharesExternalID(["tmdb": ""], ["tmdb": ""]))
        XCTAssertFalse(PlexOwnedLookup.sharesExternalID([:], ["tmdb": "97546"]))
    }
}
