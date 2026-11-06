// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ProviderPlayRouteTests: XCTestCase {
    func test_plexWithItsSessionUsesThePlexPath() throws {
        let plex = PlexProvider(machineIdentifier: "m", displayName: "P", serverURL: "http://p", authToken: "t")
        XCTAssertEqual(try ProviderPlayback.route(for: plex, hasPlexSession: true), .plexSession)
    }

    func test_plexWithoutItsSessionFailsInsteadOfFallingThrough() {
        let plex = PlexProvider(machineIdentifier: "m", displayName: "P", serverURL: "http://p", authToken: "t")
        XCTAssertThrowsError(try ProviderPlayback.route(for: plex, hasPlexSession: false))
    }

    func test_otherProvidersPlayThroughTheSeamWithOrWithoutAPlexSession() throws {
        let jf = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        XCTAssertEqual(try ProviderPlayback.route(for: jf, hasPlexSession: false), .provider)
        XCTAssertEqual(try ProviderPlayback.route(for: jf, hasPlexSession: true), .provider)
    }
}
