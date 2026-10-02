// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProviderRegistryTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class MediaProviderRegistryTests: XCTestCase {
    /// Browse surfaces mint refs for Plex hubs from `plexProvider`. With a
    /// second backend registered, "first provider in the dictionary" could
    /// hand them the Jellyfin id.
    func test_plexProvider_ignoresOtherKinds() {
        let registry = MediaProviderRegistry()
        registry.register(StubMediaProvider(id: "jellyfin:a", kind: .jellyfin))
        XCTAssertNil(registry.plexProvider)
        registry.register(StubMediaProvider(id: "plex:b", kind: .plex))
        XCTAssertEqual(registry.plexProvider?.id, "plex:b")
    }

    /// A restored session has no machineIdentifier, so the Plex provider id is
    /// a hash of the server URL, and a mid-session URL change (connection
    /// upgrade, failover) changes it. Tiles minted before the change carry
    /// the old id and must still open their detail pages.
    func test_plexURLChange_keepsEarlierIDResolvable_andMintsWithTheNewOne() {
        let registry = MediaProviderRegistry()
        registry.populate(plexServerURL: "https://relay.plex.direct:8443", plexToken: "t",
                          plexMachineID: nil, plexName: "Plex")
        let oldID = try? XCTUnwrap(registry.plexProvider?.id)

        registry.populate(plexServerURL: "http://192.168.1.140:32400", plexToken: "t",
                          plexMachineID: nil, plexName: "Plex")

        XCTAssertNotNil(registry.provider(for: oldID ?? ""))
        let fresh = MediaProviderRegistry()
        fresh.populate(plexServerURL: "http://192.168.1.140:32400", plexToken: "t",
                       plexMachineID: nil, plexName: "Plex")
        XCTAssertEqual(registry.plexProvider?.id, fresh.plexProvider?.id)
        XCTAssertNotEqual(registry.plexProvider?.id, oldID)
    }

    func test_plexSignOut_removesEveryPlexProvider() {
        let registry = MediaProviderRegistry()
        registry.populate(plexServerURL: "http://a:32400", plexToken: "t", plexMachineID: nil, plexName: "Plex")
        registry.populate(plexServerURL: "http://b:32400", plexToken: "t", plexMachineID: nil, plexName: "Plex")
        registry.populate(plexServerURL: nil, plexToken: nil, plexMachineID: nil, plexName: "Plex")
        XCTAssertNil(registry.plexProvider)
        XCTAssertFalse(registry.providers.values.contains { $0.kind == .plex })
    }
}
