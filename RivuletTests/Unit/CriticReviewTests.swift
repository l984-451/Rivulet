// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CriticReviewTests.swift
//  RivuletTests
//
//  `Review` shape measured on PMS 1.43.x with includeReviews=1.
//

import XCTest
@testable import Rivulet

@MainActor
final class CriticReviewTests: XCTestCase {

    func test_decodeAndMap() throws {
        let json = """
        {"ratingKey":"1","key":"/library/metadata/1","type":"movie","title":"T","Review":[
         {"id":86,"filter":"=86","tag":"David Sims","text":"It won me over.",
          "image":"rottentomatoes://image.review.fresh","link":"https://x.test","source":"The Atlantic"},
         {"id":87,"tag":"Katie Walsh","text":"  Meh.  ","image":"rottentomatoes://image.review.rotten","source":"TNS"},
         {"id":88,"tag":"Blank","text":"","image":"rottentomatoes://image.review.fresh"},
         {"id":89,"text":"No image or critic","source":"Outlet"}]}
        """
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        let reviews = PlexMediaMapper.reviews(meta)
        XCTAssertEqual(reviews.count, 3)
        XCTAssertEqual(reviews[0].verdict, .fresh)
        XCTAssertEqual(reviews[0].byline, "David Sims, The Atlantic")
        XCTAssertEqual(reviews[1].verdict, .rotten)
        XCTAssertEqual(reviews[1].excerpt, "Meh.")
        XCTAssertNil(reviews[2].verdict)
        XCTAssertEqual(reviews[2].byline, "Outlet")
    }

    func test_noReviewKey_isEmpty() {
        XCTAssertTrue(PlexMediaMapper.reviews(PlexMetadata()).isEmpty)
    }
}
