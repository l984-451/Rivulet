// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ServerLabelsTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class ServerLabelsTests: XCTestCase {
    func test_oneServer_hasNoLabels() {
        let labels = ServerLabels([(id: "plex:a", name: "Home", kind: .plex)])
        XCTAssertNil(labels.badge(providerID: "plex:a"))
        XCTAssertEqual(labels.title("Movies", providerID: "plex:a"), "Movies")
    }

    func test_severalServers_nameTheirRowsAndTitles() {
        let labels = ServerLabels([(id: "plex:a", name: "Home", kind: .plex), (id: "jellyfin:s", name: "Attic", kind: .jellyfin)])
        XCTAssertEqual(labels.badge(providerID: "jellyfin:s"), "Attic")
        XCTAssertEqual(labels.title("Movies", providerID: "plex:a"), "Movies (Home)")
    }

    func test_twoServersWithOneName_alsoSayTheirType() {
        let labels = ServerLabels([(id: "plex:a", name: "Media", kind: .plex), (id: "emby:e", name: "Media", kind: .emby)])
        XCTAssertEqual(labels.badge(providerID: "emby:e"), "Media (Emby)")
        XCTAssertEqual(labels.badge(providerID: "plex:a"), "Media (Plex)")
    }

    func test_anIdNoLongerRegistered_namesItsKind() {
        let labels = ServerLabels([(id: "plex:a", name: "Home", kind: .plex), (id: "jellyfin:s", name: "Attic", kind: .jellyfin)])
        XCTAssertEqual(labels.badge(providerID: "emby:gone"), "Emby")
        XCTAssertEqual(labels.badge(providerID: "nonsense"), nil)
    }

    func test_isMulti() {
        XCTAssertFalse(ServerLabels([]).isMulti)
        XCTAssertTrue(ServerLabels([(id: "a", name: "A", kind: .plex), (id: "b", name: "B", kind: .plex)]).isMulti)
    }
}
