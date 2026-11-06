// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloAuthorityTests: XCTestCase {
    private let base = URL(string: "https://silo.invalid/proxy/silo")!
    private nonisolated struct Item: Decodable, Sendable { let id: String }

    private func authority(server: SiloAuthTestServer, recorder: SiloAuthTokenRecorder,
                           validity: SiloAuthorityValidity = SiloAuthorityValidity()) -> SiloTokenAuthority {
        let credentials = SiloLoginCredentials(accessToken: "old-access", refreshToken: "old-refresh",
                                              expiresAt: Date(timeIntervalSince1970: 1),
                                              serverID: "server-a", userID: "account-a")
        return SiloTokenAuthority(baseURL: base, credentials: credentials, transport: server.transport,
                                  initiallyVerified: false, validate: { await validity.isActive() },
                                  persist: { await recorder.save($0) })
    }

    private func configureRefresh(_ server: SiloAuthTestServer, userID: String = "account-a",
                                  gate: SiloAuthRequestGate? = nil) async {
        await server.configureDiscovery(baseURL: base, serverID: "server-a")
        await server.respond("POST", "/proxy/silo/api/v2/auth/refresh", [.init(body: """
        {"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}
        """, gate: gate)])
        await server.respond("GET", "/proxy/silo/api/v2/account/me", [.init(body: """
        {"id":"\(userID)","username":"alice","password_change_required":false}
        """)])
        await server.respond("GET", "/proxy/silo/api/v2/catalog/items/movie-a", [.init(body: #"{"id":"movie-a"}"#)])
    }

    func test_refreshCannotReplaceCapturedAccountWithAnotherAccount() async {
        let server = SiloAuthTestServer()
        let recorder = SiloAuthTokenRecorder()
        await configureRefresh(server, userID: "account-b")
        let authority = authority(server: server, recorder: recorder)
        let client = SiloClient(baseURL: base, profileID: "profile-a", profileToken: "proof-a",
                                transport: server.transport, tokenSource: { try await authority.accessToken(forceRefresh: $0) })
        do {
            let _: Item = try await client.get("catalog/items/movie-a")
            XCTFail("A refreshed token for another account must never reach profile-scoped content.")
        } catch SiloSignInError.accountChanged {
        } catch { XCTFail("Unexpected error: \(error)") }
        let saved = await recorder.saves()
        let token = await authority.cachedAccessToken()
        let requests = await server.requests()
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(token, "old-access")
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/catalog/items/movie-a") == true })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Id") == nil },
                      "refresh verifies the account without borrowing any current profile")
    }

    func test_replacementServerIsRejectedBeforeSendingRefreshSecret() async {
        let server = SiloAuthTestServer()
        let recorder = SiloAuthTokenRecorder()
        await server.configureDiscovery(baseURL: base, serverID: "replacement-server")
        let authority = authority(server: server, recorder: recorder)
        do {
            _ = try await authority.accessToken(forceRefresh: false)
            XCTFail("Deployment identity changed.")
        } catch SiloSignInError.serverChanged {
        } catch { XCTFail("Unexpected error: \(error)") }
        let requests = await server.requests()
        let saved = await recorder.saves()
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.httpBody == nil })
    }

    func test_refreshKeepsProfileProofAndPersistsOnlyTheSameAccountPair() async throws {
        let server = SiloAuthTestServer()
        let recorder = SiloAuthTokenRecorder()
        await configureRefresh(server)
        let authority = authority(server: server, recorder: recorder)
        let client = SiloClient(baseURL: base, profileID: "profile-a", profileToken: "proof-a",
                                transport: server.transport, tokenSource: { try await authority.accessToken(forceRefresh: $0) })
        let item: Item = try await client.get("catalog/items/movie-a")
        XCTAssertEqual(item.id, "movie-a")
        let saved = await recorder.saves()
        let requests = await server.requests()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.serverID, "server-a")
        XCTAssertEqual(saved.first?.userID, "account-a")
        XCTAssertEqual(saved.first?.accessToken, "new-access")
        XCTAssertEqual(saved.first?.refreshToken, "new-refresh")
        let content = try XCTUnwrap(requests.last)
        XCTAssertEqual(content.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertEqual(content.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
        XCTAssertEqual(content.value(forHTTPHeaderField: "X-Profile-Token"), "proof-a")
    }

    func test_signoutDuringRefreshCannotPersistOrSendScopedContent() async {
        let server = SiloAuthTestServer()
        let recorder = SiloAuthTokenRecorder()
        let validity = SiloAuthorityValidity()
        let gate = SiloAuthRequestGate()
        await configureRefresh(server, gate: gate)
        let authority = authority(server: server, recorder: recorder, validity: validity)
        let client = SiloClient(baseURL: base, profileID: "profile-a", transport: server.transport,
                                tokenSource: { try await authority.accessToken(forceRefresh: $0) })
        let operation = Task<Item, Error> { try await client.get("catalog/items/movie-a") }
        await fulfillment(of: [gate.entered], timeout: 5)
        await validity.revoke()
        await gate.release()
        do {
            _ = try await operation.value
            XCTFail("An ended login must not be resurrected by a late refresh.")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        let saved = await recorder.saves()
        let requests = await server.requests()
        XCTAssertTrue(saved.isEmpty)
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/catalog/items/movie-a") == true })
    }
}

private actor SiloAuthorityValidity {
    private var active = true
    func isActive() -> Bool { active }
    func revoke() { active = false }
}
