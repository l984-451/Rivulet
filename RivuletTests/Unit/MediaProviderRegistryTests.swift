// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProviderRegistryTests.swift
//  RivuletTests
//

import Synchronization
import XCTest
@testable import Rivulet

@MainActor
final class MediaProviderRegistryTests: XCTestCase {
    private var savedSiloAccount: Data?

    override func setUp() async throws {
        try await super.setUp()
        savedSiloAccount = UserDefaults.standard.data(forKey: SiloSession.accountKey)
        UserDefaults.standard.removeObject(forKey: SiloSession.accountKey)
    }

    override func tearDown() async throws {
        if let savedSiloAccount {
            UserDefaults.standard.set(savedSiloAccount, forKey: SiloSession.accountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SiloSession.accountKey)
        }
        try await super.tearDown()
    }

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

    // MARK: - Extra Plex servers (#87)

    private func extra(_ id: String, _ name: String) -> (server: PlexExtraServers.Server, token: String) {
        (PlexExtraServers.Server(machineID: id, name: name, url: "http://\(id):32400"), "t-\(id)")
    }

    func test_extraPlexServers_registerBesideTheSelectedOne_inTheGivenOrder() {
        let registry = MediaProviderRegistry()
        registry.populate(plexServerURL: "http://a:32400", plexToken: "t", plexMachineID: "main", plexName: "Angel",
                          extraPlex: [extra("office", "Office"), extra("cabin", "Cabin")], plexOwnerID: "0")

        XCTAssertEqual(registry.plexProvider?.id, "plex:main", "the selected server stays the Plex provider")
        XCTAssertEqual(registry.secondaryProviders.map(\.id), ["plex:office", "plex:cabin"])
        XCTAssertEqual((registry.provider(for: "plex:office") as? PlexProvider)?.authToken, "t-office",
                       "each server uses its own token")
        XCTAssertEqual(registry.provider(for: "plex:office")?.accountID, "0",
                       "an extra server's library settings belong to the profile")
    }

    func test_extraPlexServers_skipTheSelectedServer_andGoWhenDropped() {
        let registry = MediaProviderRegistry()
        registry.populate(plexServerURL: "http://a:32400", plexToken: "t", plexMachineID: "main", plexName: "Angel",
                          extraPlex: [extra("main", "Angel"), extra("office", "Office")])
        XCTAssertEqual(registry.secondaryProviders.map(\.id), ["plex:office"])

        registry.populate(plexServerURL: "http://a:32400", plexToken: "t", plexMachineID: "main", plexName: "Angel")

        XCTAssertNil(registry.provider(for: "plex:office"))
        XCTAssertEqual(registry.plexProvider?.id, "plex:main")
    }

    func test_plexServer_isTheItemsOwnServer_forAnExtraServersItem() {
        let registry = MediaProviderRegistry()
        registry.populate(plexServerURL: "http://a:32400", plexToken: "t", plexMachineID: "main", plexName: "Angel",
                          extraPlex: [extra("office", "Office")])

        let office = registry.plexServer(for: "plex:office")
        XCTAssertEqual(office?.address, "http://office:32400")
        XCTAssertEqual(office?.token, "t-office")
    }

    func test_plexSignOut_removesExtraServersToo() {
        let registry = MediaProviderRegistry()
        registry.populate(plexServerURL: "http://a:32400", plexToken: "t", plexMachineID: "main", plexName: "Angel",
                          extraPlex: [extra("office", "Office")])
        registry.populate(plexServerURL: nil, plexToken: nil, plexMachineID: nil, plexName: "Plex",
                          extraPlex: [extra("office", "Office")])
        XCTAssertTrue(registry.secondaryProviders.isEmpty)
    }

    /// An extra server's item is not the selected server's: the legacy Plex
    /// path would fetch its ratingKey from the wrong server.
    func test_isPlex_meansTheSelectedServerOnly() {
        MediaItemRef.extraPlexIDs.withLock { $0 = ["plex:office"] }
        defer { MediaItemRef.extraPlexIDs.withLock { $0 = [] } }

        XCTAssertTrue(MediaItemRef(providerID: "plex:main", itemID: "1").isPlex)
        XCTAssertFalse(MediaItemRef(providerID: "plex:office", itemID: "1").isPlex)
        XCTAssertFalse(MediaItemRef(providerID: "jellyfin:srv", itemID: "1").isPlex)
    }

    /// The two servers the maintainer's account lists, measured on plex.tv. An
    /// install that never saved the selected server's id must still find it by
    /// its saved URL, or the selected server also shows as an "other" server.
    func test_savedURL_identifiesTheSelectedServer_amongTheAccountsServers() throws {
        func device(_ name: String, _ id: String, _ uri: String, port: Int) throws -> PlexDevice {
            try JSONDecoder().decode(PlexDevice.self, from: Data("""
            {"name":"\(name)","product":"Plex Media Server","productVersion":"1.43","clientIdentifier":"\(id)",
             "createdAt":"","lastSeenAt":"","provides":"server",
             "connections":[{"protocol":"https","address":"192.168.1.140","port":\(port),"uri":"\(uri)","local":true,"relay":false,"IPv6":false}]}
            """.utf8))
        }
        let angel = try device("Angel", "48ebbb1a9b1b40674de33b901f35dc2f72113b80",
                               "https://192-168-1-140.42b7a1de9c224bfa9fb1ca28b6129562.plex.direct:32400", port: 32400)
        let test = try device("Rivulet Test Plex", "27061058f07a814981a2deb3ac3a3f96f89c7d08",
                              "https://192-168-1-140.93b6b279111147c39f167c4cafbc603a.plex.direct:32410", port: 32410)
        let saved = "https://192-168-1-140.42b7a1de9c224bfa9fb1ca28b6129562.plex.direct:32400"

        XCTAssertTrue(PlexAuthManager.urlBelongs(saved, to: angel))
        XCTAssertFalse(PlexAuthManager.urlBelongs(saved, to: test), "same host, other port: another server")
        XCTAssertTrue(PlexAuthManager.urlBelongs("http://192.168.1.140:32400", to: angel), "raw address of the same connection")
    }
}
