// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  EmbySessionUsersTests.swift
//  RivuletTests
//
//  More users of one Emby server (`EmbySession+Users`). Like EmbySessionTests these write the
//  test host's real Keychain and UserDefaults; a sign-in already on the simulator is set aside
//  in setUp and put back in tearDown.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbySessionUsersTests: XCTestCase {
    private let server = FakeEmbyServer()
    /// The kid's sign-in: its own fake, since a fake answers a path with the first reply it was given.
    private let kidServer = FakeEmbyServer()
    private let base = URL(string: "http://127.0.0.1:9")!
    private let providerID = "emby:\(EmbyLiveFixtures.serverID)"
    private let kidID = "0000000000000000000000000000000d"
    private let kidToken = "kid-access-token"
    private var existingAccount: Data?
    private var existingSaved: Data?
    private var existingToken: String?
    private let noNetwork: EmbyClient.Transport = { _ in throw URLError(.timedOut) }

    override func setUp() async throws {
        try await super.setUp()
        existingAccount = UserDefaults.standard.data(forKey: EmbySession.accountKey)
        existingSaved = UserDefaults.standard.data(forKey: EmbySession.savedUsersKey)
        existingToken = CredentialRegistry.shared.token(for: .server(providerID: providerID))
        UserDefaults.standard.removeObject(forKey: EmbySession.accountKey)
        UserDefaults.standard.removeObject(forKey: EmbySession.savedUsersKey)
        server.respond("/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
        server.respond("/Users/AuthenticateByName", method: "POST", body: EmbyLiveFixtures.authenticate4_10_2)
        server.respond("/Users/\(EmbyLiveFixtures.userID)", body: EmbyLiveFixtures.userAdmin4_10_2)
        _ = try await EmbySession.signIn(serverURL: base, username: "bain", password: "pw", transport: server.transport)
    }

    override func tearDown() async throws {
        if EmbySession.account != nil { await EmbySession.signOut(transport: noNetwork) }
        await CredentialRegistry.shared.clearToken(for: .serverUser(providerID: providerID, userID: kidID))
        await CredentialRegistry.shared.clearToken(for: .serverUser(providerID: providerID, userID: EmbyLiveFixtures.userID))
        if let existingToken { try await CredentialRegistry.shared.setToken(existingToken, for: .server(providerID: providerID)) }
        if let existingAccount { UserDefaults.standard.set(existingAccount, forKey: EmbySession.accountKey) }
        if let existingSaved { UserDefaults.standard.set(existingSaved, forKey: EmbySession.savedUsersKey) }
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        try await super.tearDown()
    }

    /// The kid's AuthenticateByName answer: the fixture with another user id, name and token.
    private func respondWithKid(serverID: String = EmbyLiveFixtures.serverID) {
        let body = EmbyLiveFixtures.authenticate4_10_2
            .replacingOccurrences(of: EmbyLiveFixtures.userID, with: kidID)
            .replacingOccurrences(of: "m-transport-auth-pw", with: "Kid")
            .replacingOccurrences(of: EmbyLiveFixtures.dummyToken, with: kidToken)
            .replacingOccurrences(of: EmbyLiveFixtures.serverID, with: serverID)
        kidServer.respond("/Users/AuthenticateByName", method: "POST", body: body)
    }

    func test_addUser_keepsTheActiveUser() async throws {
        respondWithKid()
        let kid = try await EmbySession.addUser(username: "kid", password: "", transport: kidServer.transport)

        XCTAssertEqual(EmbySession.account?.userID, EmbyLiveFixtures.userID, "the active user stays")
        XCTAssertEqual(EmbySession.savedUsers.map(\.userID), [kidID])
        XCTAssertEqual(kid.userName, "Kid")
        XCTAssertEqual(EmbySession.users.map(\.userID), [EmbyLiveFixtures.userID, kidID], "active first")
        XCTAssertEqual(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: kidID)), kidToken)
        XCTAssertEqual(CredentialRegistry.shared.token(for: .server(providerID: providerID)), EmbyLiveFixtures.dummyToken)
    }

    func test_switchUser_swapsTheActiveUserAndTokens() async throws {
        respondWithKid()
        try await EmbySession.addUser(username: "kid", password: "", transport: kidServer.transport)

        let switched = await EmbySession.switchUser(to: kidID)

        XCTAssertTrue(switched)
        XCTAssertEqual(EmbySession.account?.userID, kidID)
        XCTAssertEqual(EmbySession.savedUsers.map(\.userID), [EmbyLiveFixtures.userID])
        XCTAssertEqual(CredentialRegistry.shared.token(for: .server(providerID: providerID)), kidToken)
        XCTAssertEqual(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: EmbyLiveFixtures.userID)),
                       EmbyLiveFixtures.dummyToken)
        XCTAssertNil(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: kidID)))

        let back = await EmbySession.switchUser(to: EmbyLiveFixtures.userID)
        XCTAssertTrue(back)
        XCTAssertEqual(EmbySession.account?.userID, EmbyLiveFixtures.userID)
        XCTAssertEqual(CredentialRegistry.shared.token(for: .server(providerID: providerID)), EmbyLiveFixtures.dummyToken)
    }

    func test_switchUser_toAnUnknownUser_changesNothing() async {
        let switched = await EmbySession.switchUser(to: "nobody")
        XCTAssertFalse(switched)
        XCTAssertEqual(EmbySession.account?.userID, EmbyLiveFixtures.userID)
    }

    func test_removeUser_forgetsUserAndToken() async throws {
        respondWithKid()
        try await EmbySession.addUser(username: "kid", password: "", transport: kidServer.transport)

        await EmbySession.removeUser(kidID, transport: noNetwork)

        XCTAssertTrue(EmbySession.savedUsers.isEmpty)
        XCTAssertNil(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: kidID)))
        XCTAssertEqual(EmbySession.account?.userID, EmbyLiveFixtures.userID)
    }

    func test_signOut_removesEverySavedUser() async throws {
        respondWithKid()
        try await EmbySession.addUser(username: "kid", password: "", transport: kidServer.transport)

        await EmbySession.signOut(transport: noNetwork)

        XCTAssertNil(EmbySession.account)
        XCTAssertTrue(EmbySession.savedUsers.isEmpty)
        XCTAssertNil(CredentialRegistry.shared.token(for: .serverUser(providerID: providerID, userID: kidID)))
    }

    func test_addUser_fromAnotherServer_isRefused() async {
        respondWithKid(serverID: "another-server")
        do {
            try await EmbySession.addUser(username: "kid", password: "", transport: kidServer.transport)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? EmbySignInError, .notEmby)
        }
        XCTAssertTrue(EmbySession.savedUsers.isEmpty)
    }

    func test_addingTheActiveUserAgain_addsNothing() async throws {
        let same = try await EmbySession.addUser(username: "bain", password: "pw", transport: server.transport)
        XCTAssertEqual(same.userID, EmbyLiveFixtures.userID)
        XCTAssertTrue(EmbySession.savedUsers.isEmpty)
    }

    func test_profiles_listBothUsers_activeFirst() async throws {
        XCTAssertFalse(ServerUserProfiles.canSwitch, "one user: nothing to switch to")
        respondWithKid()
        try await EmbySession.addUser(username: "kid", password: "", transport: kidServer.transport)

        let emby = ServerUserProfiles.profiles.filter { $0.kind == .emby }
        XCTAssertTrue(ServerUserProfiles.canSwitch)
        XCTAssertEqual(emby.map(\.userID), [EmbyLiveFixtures.userID, kidID])
        XCTAssertEqual(emby.map(\.isActive), [true, false])
    }
}
