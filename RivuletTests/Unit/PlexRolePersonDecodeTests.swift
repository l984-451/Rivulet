// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexRolePersonDecodeTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class PlexRolePersonDecodeTests: XCTestCase {
    func test_decodesTagKeyAndFilter() throws {
        let json = """
        { "tag": "Jon Hamm", "role": "Don Draper",
          "thumb": "https://metadata-static.plex.tv/p/people/abc.jpg",
          "tagKey": "5d776831151a60001f24a6b1", "filter": "actor=49" }
        """.data(using: .utf8)!
        let role = try JSONDecoder().decode(PlexRole.self, from: json)
        XCTAssertEqual(role.tagKey, "5d776831151a60001f24a6b1")
        XCTAssertEqual(role.filter, "actor=49")
        XCTAssertEqual(role.originActorId, "49")
    }

    func test_missingFieldsDecodeNil() throws {
        let json = #"{ "tag": "Nobody" }"#.data(using: .utf8)!
        let role = try JSONDecoder().decode(PlexRole.self, from: json)
        XCTAssertNil(role.tagKey)
        XCTAssertNil(role.originActorId)
    }

    func test_directorDecodesTagKeyAndFilter() throws {
        let json = """
        { "tag": "Greta Gerwig", "thumb": "https://metadata-static.plex.tv/p/people/g.jpg",
          "tagKey": "5d77683254f42c001f8c3a1d", "filter": "director=77" }
        """.data(using: .utf8)!
        let crew = try JSONDecoder().decode(PlexCrewMember.self, from: json)
        XCTAssertEqual(crew.tagKey, "5d77683254f42c001f8c3a1d")
        XCTAssertEqual(crew.originTagId, "77")
    }
}
