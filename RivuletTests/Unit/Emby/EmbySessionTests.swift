// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbySessionTests.swift
//  RivuletTests
//
//  Writes the test host's real Keychain and UserDefaults, like
//  JellyfinSessionTests. An Emby sign-in already on the simulator is set
//  aside in setUp and put back in tearDown.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbySessionTests: XCTestCase {
    private let server = FakeJellyfinServer()
    /// Port 9 refuses at once, so tearDown's logout fails fast.
    private let base = URL(string: "http://127.0.0.1:9")!
    private let testProviderID = "jellyfin:emby-session-test"
    private var existingAccount: Data?

    override func setUp() async throws {
        try await super.setUp()
        existingAccount = UserDefaults.standard.data(forKey: EmbySession.accountKey)
    }

    override func tearDown() async throws {
        if EmbySession.account?.providerID == testProviderID {
            await EmbySession.signOut()
        }
        await CredentialRegistry.shared.clearToken(for: .server(providerID: testProviderID))
        if let existingAccount {
            UserDefaults.standard.set(existingAccount, forKey: EmbySession.accountKey)
            MediaProviderRegistry.shared.populateFromCurrentAuth()
        }
        try await super.tearDown()
    }

    private func publicInfo(product: String = "Emby Server", version: String = "4.9.1.80") -> String {
        JellyfinFixtures.publicInfo(id: "emby-session-test", version: version, product: product)
    }

    private func signIn() async throws -> EmbySession.Account {
        try await EmbySession.signIn(serverURL: base, username: "bain", password: "pw", transport: server.transport)
    }

    func test_signIn_usesEmbyHeader_persists_andRegistersBesideJellyfin() async throws {
        server.respond("/System/Info/Public", body: publicInfo())
        server.respond("/Users/AuthenticateByName",
                       body: #"{"AccessToken":"tok-e","ServerId":"emby-session-test","User":{"Id":"user-1","Name":"bain"}}"#)
        let account = try await signIn()

        let auth = server.requests[1]
        XCTAssertNotNil(auth.value(forHTTPHeaderField: "X-Emby-Authorization"))
        XCTAssertNil(auth.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(server.jsonBody(1)["Username"] as? String, "bain")
        XCTAssertEqual(server.jsonBody(1)["Pw"] as? String, "pw")

        XCTAssertEqual(account.providerID, testProviderID)
        XCTAssertEqual(EmbySession.account, account)
        XCTAssertNotEqual(JellyfinSession.account?.providerID, testProviderID, "Emby keeps its own account")
        XCTAssertEqual(CredentialRegistry.shared.token(for: .server(providerID: testProviderID)), "tok-e")
        XCTAssertNotNil(MediaProviderRegistry.shared.provider(for: testProviderID))

        await EmbySession.signOut()
        XCTAssertNil(EmbySession.account)
        XCTAssertNil(MediaProviderRegistry.shared.provider(for: testProviderID))
    }

    func test_signIn_rejectsJellyfin_withAPointer() async {
        server.respond("/System/Info/Public", body: publicInfo(product: "Jellyfin Server", version: "12.1.0"))
        await assertSignInThrows(.isJellyfin)
    }

    func test_signIn_rejectsOldEmby() async {
        server.respond("/System/Info/Public", body: publicInfo(version: "4.7.14.0"))
        await assertSignInThrows(.serverTooOld(version: "4.7.14.0"))
    }

    func test_signIn_rejectsHTMLPage() async {
        server.respond("/System/Info/Public", body: "<html>router login</html>")
        await assertSignInThrows(.notEmby)
    }

    private func assertSignInThrows(_ expected: EmbySignInError, line: UInt = #line) async {
        do {
            _ = try await signIn()
            XCTFail("expected a throw", line: line)
        } catch let error as EmbySignInError {
            XCTAssertEqual(error, expected, line: line)
        } catch { XCTFail("got \(error)", line: line) }
        XCTAssertNotEqual(EmbySession.account?.providerID, testProviderID, line: line)
    }
}
