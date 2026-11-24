// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentOriginTests.swift
//  RivuletTests
//
//  Flags for where IPTV content is from, in place of the tags panels put in front.
//

import XCTest
@testable import Rivulet

final class ContentOriginTests: XCTestCase {
    func test_markers() {
        XCTAssertEqual(ContentOrigin.marker(forTag: "NL"), "🇳🇱")
        XCTAssertEqual(ContentOrigin.marker(forTag: "UK"), "🇬🇧")
        XCTAssertEqual(ContentOrigin.marker(forTag: "EN"), "🇬🇧")
        XCTAssertEqual(ContentOrigin.marker(forTag: "USA"), "🇺🇸")
        XCTAssertEqual(ContentOrigin.marker(forTag: "FR-4K"), "🇫🇷")
        XCTAssertEqual(ContentOrigin.marker(forTag: "HINDI"), "🇮🇳")
        XCTAssertEqual(ContentOrigin.marker(forTag: "MULTI / LINGO"), "🌐")
        XCTAssertEqual(ContentOrigin.marker(forTag: "AR"), "AR", "Arabic, not Argentina")
        XCTAssertEqual(ContentOrigin.marker(forTag: "EXYU"), "EXYU")
        XCTAssertNil(ContentOrigin.marker(forTag: "PPV"))
        XCTAssertNil(ContentOrigin.marker(forTag: "UCL"))
        XCTAssertNil(ContentOrigin.marker(forTag: "4K"))
    }

    func test_marked_andBadges() {
        XCTAssertEqual(ContentOrigin.marked("┃NL┃ TURKS NU TE ZIEN"), "🇳🇱 TURKS NU TE ZIEN")
        XCTAssertEqual(ContentOrigin.marked("| PPV | UFC PPV"), "UFC PPV")
        XCTAssertEqual(ContentOrigin.marked("┃MULTI / LINGO┃ NETFLIX"), "🌐 NETFLIX")
        XCTAssertEqual(ContentOrigin.marked("Kids"), "Kids")
        XCTAssertEqual(ContentOrigin.badge(forTag: "FR-4K"), "🇫🇷 4K")
        XCTAssertEqual(ContentOrigin.badge(forTag: "MULTI / LINGO"), "🌐")
        XCTAssertEqual(ContentOrigin.badge(forTag: "VO"), "VO")
        XCTAssertNil(ContentOrigin.badge(forTag: nil))
    }

    func test_groupNames_flagsTellCountriesApart() {
        let names = LiveGroupDisplay.names(["| UK | SPORTS", "| US | SPORTS", "| PPV | BOXING", "| UK | BOXING"])
        XCTAssertEqual(names["| UK | SPORTS"], "🇬🇧 SPORTS")
        XCTAssertEqual(names["| US | SPORTS"], "🇺🇸 SPORTS")
        XCTAssertEqual(names["| PPV | BOXING"], "BOXING")
        XCTAssertEqual(names["| UK | BOXING"], "🇬🇧 BOXING")
    }
}
