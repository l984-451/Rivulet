// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class MediaServerSyncTests: XCTestCase {
    private var savedJellyfin: Data?
    private var savedEmby: Data?

    override func setUp() async throws {
        try await super.setUp()
        savedJellyfin = UserDefaults.standard.data(forKey: JellyfinSession.accountKey)
        savedEmby = UserDefaults.standard.data(forKey: EmbySession.accountKey)
        guard savedJellyfin == nil, savedEmby == nil else { throw XCTSkip("a Jellyfin or Emby sign-in exists on this simulator") }
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: JellyfinSession.accountKey)
        UserDefaults.standard.removeObject(forKey: EmbySession.accountKey)
        await CredentialRegistry.shared.clearToken(for: .server(providerID: "jellyfin:srv"))
        await CredentialRegistry.shared.clearToken(for: .server(providerID: "emby:srv"))
        try await super.tearDown()
    }

    func test_bothAppsSyncJellyfinAndEmby() {
        XCTAssertEqual(CloudSync.accountKinds.map(\.kind), ["plex", "livetv", "jellyfin", "emby"])
    }

    func test_jellyfinExportsAccountAndToken() async throws {
        let account = JellyfinSession.Account(serverURL: URL(string: "http://nas:8096")!, serverID: "srv",
                                              serverName: "NAS", userID: "u1", userName: "bain")
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: JellyfinSession.accountKey)
        try await CredentialRegistry.shared.setToken("tok", for: .server(providerID: account.providerID))

        let exports = SyncedAccountKind.jellyfin.export()
        XCTAssertEqual(exports.map(\.id), ["jellyfin:srv"])
        let body = try XCTUnwrap(SyncBodies.decode(MediaServerSyncBody<JellyfinSession.Account>.self, exports.first?.body))
        XCTAssertEqual(body.account, account)
        XCTAssertEqual(body.token, "tok")
    }

    func test_embyRemovalSignsOutHereOnly() async throws {
        let account = EmbySession.Account(serverURL: URL(string: "http://nas:8097")!, serverID: "srv",
                                          serverName: "NAS", userID: "u1", userName: "bain", policy: .init())
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: EmbySession.accountKey)
        try await CredentialRegistry.shared.setToken("tok", for: .server(providerID: account.providerID))

        let tombstone = SyncedAccounts.Entry(id: "emby:srv", kind: "emby", identity: nil, updatedAt: Date(), deleted: true, body: nil)
        await SyncedAccountKind.emby.remove(tombstone)

        XCTAssertNil(EmbySession.account)
        XCTAssertNil(CredentialRegistry.shared.token(for: .server(providerID: account.providerID)))
    }
}
