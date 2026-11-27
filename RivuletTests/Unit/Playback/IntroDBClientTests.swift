// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  IntroDBClientTests.swift
//  RivuletTests
//
//  The community markers: introdb.app's reply, TheIntroDB's, and how the two combine.
//

import XCTest
@testable import Rivulet

final class IntroDBClientTests: XCTestCase {

    private func kinds(_ markers: [PlexMarker]) -> [String] { markers.compactMap(\.type) }

    func test_theIntroDB_readsEachKindsFirstSegment() {
        let json = #"{"tmdb_id":1,"type":"tv","season":1,"episode":1,"#
            + #""intro":[{"start_ms":228665,"end_ms":246498},{"start_ms":900000,"end_ms":910000}],"#
            + #""recap":[{"start_ms":1000,"end_ms":60000}],"preview":[{"start_ms":5,"end_ms":9}]}"#
        let markers = IntroDBClient.decodeTheIntroDB(Data(json.utf8), duration: nil)
        XCTAssertEqual(kinds(markers), ["intro", "recap"], "previews are not read")
        XCTAssertEqual(markers.first?.startTimeOffset, 228_665)
        XCTAssertEqual(markers.first?.endTimeOffset, 246_498)
    }

    func test_theIntroDB_aMissingStartIsTheEpisodesStart() {
        let json = #"{"intro":[{"start_ms":null,"end_ms":25838}]}"#
        let markers = IntroDBClient.decodeTheIntroDB(Data(json.utf8), duration: nil)
        XCTAssertEqual(markers.first?.startTimeOffset, 0)
        XCTAssertEqual(markers.first?.endTimeOffset, 25_838)
    }

    func test_theIntroDB_creditsToTheEnd_needTheDuration() {
        let json = Data(#"{"credits":[{"start_ms":1228729,"end_ms":null}]}"#.utf8)
        XCTAssertTrue(IntroDBClient.decodeTheIntroDB(json, duration: nil).isEmpty, "no end known: dropped")
        let markers = IntroDBClient.decodeTheIntroDB(json, duration: 1320)
        XCTAssertEqual(kinds(markers), ["credits"])
        XCTAssertEqual(markers.first?.endTimeOffset, 1_320_000)
    }

    func test_theIntroDB_rejectsBackwardsSegments_andNotFound() {
        XCTAssertTrue(IntroDBClient.decodeTheIntroDB(Data(#"{"intro":[{"start_ms":5000,"end_ms":4000}]}"#.utf8), duration: nil).isEmpty)
        let notFound = Data(#"{"error":"media not found for provided tmdb_id","code":"media_not_found"}"#.utf8)
        XCTAssertTrue(IntroDBClient.decodeTheIntroDB(notFound, duration: 1000).isEmpty)
    }

    func test_combined_keepsIntroDBApp_andFillsOnlyTheKindsItLacks() {
        let primary = [PlexMarker(id: -9001, type: "intro", startTimeOffset: 0, endTimeOffset: 30_000)]
        let secondary = [PlexMarker(id: -9001, type: "intro", startTimeOffset: 1_000, endTimeOffset: 31_000),
                         PlexMarker(id: -9003, type: "credits", startTimeOffset: 1_200_000, endTimeOffset: 1_320_000)]
        let combined = IntroDBClient.combined(primary, secondary)
        XCTAssertEqual(kinds(combined), ["intro", "credits"])
        XCTAssertEqual(combined.first?.endTimeOffset, 30_000, "introdb.app's intro wins")
    }

    func test_combined_theIntroDBAlone_whenIntroDBAppHasNothing() {
        let secondary = [PlexMarker(id: -9001, type: "intro", startTimeOffset: 0, endTimeOffset: 25_838)]
        let combined = IntroDBClient.combined([], secondary)
        XCTAssertEqual(kinds(combined), ["intro"])
        XCTAssertEqual(combined.first?.endTimeOffset, 25_838)
    }
}
