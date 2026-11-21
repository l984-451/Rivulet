// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  JellyfinSessionUsersTests.swift
//  RivuletTests
//
//  More users of one Jellyfin server (`JellyfinSession+Users`). Like JellyfinSessionTests these
//  write the test host's real Keychain and UserDefaults; a sign-in already on the simulator is
//  set aside in setUp and put back in tearDown.
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinSessionUsersTests: XCTestCase {
    private let server = FakeJellyfinServer()
    /// The kid's sign-in: its own fake, since a fake answers a path with the first reply it was given.
    private let kidServer = FakeJellyfinServer()
    private let base = URL(string: "http://127.0.0.1:9")!
    private let providerID = "jellyfin:users-test"
    private var existingAccount: Data?
    private var existingSaved: Data?
    private let noNetwork: JellyfinClient.Transport = { _ in throw URLError(.timedOut) }

    override func setUp() async throws {
        try await super.setUp()
        existingAccount = UserDefaults.standard.data(forKey: JellyfinSession.accountKey)
        existingSaved = UserDefaults.standard.data(forKey: JellyfinSession.savedUsersKey)
        UserDefaults.standard.removeObject(forKey: JellyfinSession.savedUsersKey)
        server.respond("/System/Info/Public", body: JellyfinFixtures.publicInfo(id: "users-test"))
        server.respond("/Users/AuthenticateByName",
                       body: #"{"AccessToken":"tok-1","ServerId":"users-test","User":{"Id":"user-1","Name":"bain"}}"#)
        _ = try await JellyfinSession.signIn(serverURL: base, username: "bain", password: "pw", transport: server.transport)
    }

    override func tearDown() async throws {
        if JellyfinSession.account?.providerID == providerID { await JellyfinSession.signOut(transport: noNetwork) }
        await CredentialRegistry.shared.clearToken(for: .server(providerID: providerID))
        for id in ["user-1", "kid-1"] {
            await CredentialRegistry.shared.clearToken(for: .serverUser(providerID: providerID, userID: id))
        }
        if let existingAccount { UserDefaults.standard.set(existingAccount, forKey: JellyfinSession.accountKey) }
        if let existingSaved { UserDefaults.standard.set(existingSaved, forKey: JellyfinSession.savedUsersKey) }
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        try await super.tearDown()
    }

    private func respondWithKid(serverID: String = "users-test") {
        kidServer.respond("/Users/AuthenticateByName",
                          body: #"{"AccessToken":"tok-kid","ServerId":"\#(serverID)","User":{"Id":"kid-1","Name":"Kid"}}"#)
    }

    func test_addUser_keepsTheActiveUser() async throws {
        respondWithKid()
        let kid = try await JellyfinSession.addUser(username: "kid", password: "", transport: kidServer.transport)

        XCTAssertEqual(kid.userName, "Kid")
        XCTAssertEqual(JellyfinSession.account?.userID, "user-1")
        XCTAssertEqual(JellyfinSession.users.map(\.userID), ["user-1", "kid-1"], "active first")
        XCTAssertEqual(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: "kid-1")), "tok-kid")
    }

    func test_switchUser_swapsTheActiveUserAndTokens() async throws {
        respondWithKid()
        try await JellyfinSession.addUser(username: "kid", password: "", transport: kidServer.transport)

        let switched = await JellyfinSession.switchUser(to: "kid-1")

        XCTAssertTrue(switched)
        XCTAssertEqual(JellyfinSession.account?.userID, "kid-1")
        XCTAssertEqual(JellyfinSession.savedUsers.map(\.userID), ["user-1"])
        XCTAssertEqual(CredentialRegistry.shared.token(for: .server(providerID: providerID)), "tok-kid")
        XCTAssertEqual(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: "user-1")), "tok-1")
        XCTAssertNil(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: "kid-1")))
    }

    func test_removeUser_forgetsUserAndToken() async throws {
        respondWithKid()
        try await JellyfinSession.addUser(username: "kid", password: "", transport: kidServer.transport)

        await JellyfinSession.removeUser("kid-1", transport: noNetwork)

        XCTAssertTrue(JellyfinSession.savedUsers.isEmpty)
        XCTAssertNil(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: "kid-1")))
    }

    func test_signOut_removesEverySavedUser() async throws {
        respondWithKid()
        try await JellyfinSession.addUser(username: "kid", password: "", transport: kidServer.transport)

        await JellyfinSession.signOut(transport: noNetwork)

        XCTAssertNil(JellyfinSession.account)
        XCTAssertTrue(JellyfinSession.savedUsers.isEmpty)
        XCTAssertNil(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: "kid-1")))
    }

    func test_addUser_fromAnotherServer_isRefused() async {
        respondWithKid(serverID: "another-server")
        do {
            try await JellyfinSession.addUser(username: "kid", password: "", transport: kidServer.transport)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? JellyfinSignInError, .notJellyfin)
        }
        XCTAssertTrue(JellyfinSession.savedUsers.isEmpty)
    }
}
