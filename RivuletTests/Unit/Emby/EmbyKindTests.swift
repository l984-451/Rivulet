// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyKindTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class EmbyKindTests: XCTestCase {
    func test_mediaProviderKind_embyRoundTrips_andFollowsJellyfin() throws {
        XCTAssertEqual(MediaProviderKind.emby.rawValue, "emby")
        XCTAssertEqual(MediaProviderKind.emby.displayName, "Emby")
        XCTAssertEqual(MediaProviderKind(providerID: "emby:2e822559686942dda788fd5fac9f3fac"), .emby)
        XCTAssertEqual(MediaProviderKind(providerID: "jellyfin:abc"), .jellyfin)
        XCTAssertNil(MediaProviderKind(providerID: "embyx:abc"))
        let data = try JSONEncoder().encode([MediaProviderKind.emby])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["emby"]"#)
        XCTAssertEqual(try JSONDecoder().decode([MediaProviderKind].self, from: data), [.emby])
        XCTAssertEqual(MediaProviderKind.otherServerKinds, [.jellyfin, .emby])
        XCTAssertEqual(OtherServerKind.all.map(\.kind), MediaProviderKind.otherServerKinds)
    }

    func test_liveTVSourceType_embyFollowsItsServer() throws {
        XCTAssertEqual(LiveTVSourceType(rawValue: "emby"), .emby)
        XCTAssertTrue(LiveTVSourceType.emby.followsServer)
        XCTAssertEqual(try JSONDecoder().decode(LiveTVSourceType.self, from: Data(#""emby""#.utf8)), .emby)
    }
}
