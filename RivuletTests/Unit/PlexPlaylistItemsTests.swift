// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexPlaylistItemsTests.swift
//  RivuletTests
//
//  /playlists/{id}/items as PMS 1.43.4 answered on 2026-10-30, cut down.
//  A smart list says so on the container and its rows carry no playlistItemID.
//

import XCTest
@testable import Rivulet

final class PlexPlaylistItemsTests: XCTestCase {

    private func decode(_ json: String) throws -> PlexPlaylistItemsContainer.Container {
        try JSONDecoder().decode(PlexPlaylistItemsContainer.self, from: Data(json.utf8)).MediaContainer
    }

    func test_smartList_isSmart_andRowsHaveNoPlaylistItemID() throws {
        let page = try decode("""
        {"MediaContainer":{"size":2,"totalSize":316,"smart":true,"playlistType":"video","Metadata":[
          {"ratingKey":"231926","type":"movie","title":"28 Years Later"},
          {"ratingKey":"232044","type":"movie","title":"Abigail"}]}}
        """)
        XCTAssertEqual(page.smart, true)
        XCTAssertEqual(page.totalSize, 316)
        XCTAssertEqual(page.Metadata?.map(\.ratingKey), ["231926", "232044"])
        XCTAssertEqual(page.Metadata?.compactMap(\.playlistItemID), [])
    }

    func test_regularList_isNotSmart_andRowsHavePlaylistItemID() throws {
        let page = try decode("""
        {"MediaContainer":{"size":2,"totalSize":2,"smart":false,"Metadata":[
          {"ratingKey":"9342","type":"movie","title":"X-Men","playlistItemID":82017},
          {"ratingKey":"101804","type":"movie","title":"Deadpool","playlistItemID":82025}]}}
        """)
        XCTAssertEqual(page.smart, false)
        XCTAssertEqual(page.Metadata?.compactMap(\.playlistItemID), [82017, 82025])
    }
}
