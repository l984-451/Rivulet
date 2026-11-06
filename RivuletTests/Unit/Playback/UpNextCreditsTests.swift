// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  UpNextCreditsTests.swift
//  RivuletTests
//
//  PlexPlaybackMarkers.upNextCredits: which credits marker opens Up Next.
//

import XCTest
@testable import Rivulet

final class UpNextCreditsTests: XCTestCase {

    private func credits(_ id: Int, _ start: TimeInterval, _ end: TimeInterval) -> PlexMarker {
        PlexMarker(id: id, type: "credits", startTimeOffset: Int(start * 1000), endTimeOffset: Int(end * 1000))
    }

    func testEarlyCreditsMarkerDoesNotHoldUpNextShut() {
        let opening = credits(1, 60, 120)
        let ending = credits(2, 2500, 2700)
        XCTAssertEqual(PlexPlaybackMarkers.upNextCredits([opening, ending], duration: 2700)?.id, 2)
    }

    func testEarliestEndCreditsWinsWhateverTheServerOrder() {
        let post = credits(2, 2650, 2700)
        let main = credits(1, 2500, 2600)
        XCTAssertEqual(PlexPlaybackMarkers.upNextCredits([post, main], duration: 2700)?.id, 1)
    }

    func testCreditsUnderFiveMinutesFromTheEndCountInTheFirstHalf() {
        // A 6-minute short: credits at 40% still open Up Next.
        XCTAssertEqual(PlexPlaybackMarkers.upNextCredits([credits(1, 144, 360)], duration: 360)?.id, 1)
    }

    func testNonCreditsAndMalformedMarkersAreIgnored() {
        let intro = PlexMarker(id: 1, type: "intro", startTimeOffset: 2_500_000, endTimeOffset: 2_600_000)
        let backwards = credits(2, 2600, 2500)
        XCTAssertNil(PlexPlaybackMarkers.upNextCredits([intro, backwards], duration: 2700))
    }

    func testUnknownDurationTakesTheEarliestCredits() {
        XCTAssertEqual(PlexPlaybackMarkers.upNextCredits([credits(2, 900, 950), credits(1, 60, 90)], duration: 0)?.id, 1)
    }
}
