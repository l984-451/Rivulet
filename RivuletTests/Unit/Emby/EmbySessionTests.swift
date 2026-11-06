// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbySessionTests.swift
//  RivuletTests
//
//  These tests write the test host's real Keychain and UserDefaults (like
//  JellyfinSessionTests). An Emby sign-in already on the simulator is set aside
//  in setUp and put back in tearDown, token included (stored under its own server id).
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbySessionTests: XCTestCase {
    private let server = FakeEmbyServer()
    /// Port 9 (discard) refuses at once, so signOut's best-effort logout, which uses a real
    /// URLSession when no transport is given, fails fast.
    private let base = URL(string: "http://127.0.0.1:9")!
    private let fixtureServerIDs = [EmbyLiveFixtures.serverID, "b295bd17cada416faae6268b47baf833",
                                    "5f22d4f3e0c4481b895830bc337c85f5", "mismatch-test"]
    private var existingAccount: Data?
    private var existingTokens: [String: String] = [:]

    override func setUp() async throws {
        try await super.setUp()
        existingAccount = UserDefaults.standard.data(forKey: EmbySession.accountKey)
        existingTokens = Dictionary(uniqueKeysWithValues: fixtureServerIDs.compactMap { id in
            CredentialRegistry.shared.token(for: .server(providerID: "emby:\(id)")).map { (id, $0) }
        })
        UserDefaults.standard.removeObject(forKey: EmbySession.accountKey)
    }

    override func tearDown() async throws {
        if EmbySession.account != nil { await EmbySession.signOut(transport: { _ in throw URLError(.timedOut) }) }
        for id in fixtureServerIDs {
            await CredentialRegistry.shared.clearToken(for: .server(providerID: "emby:\(id)"))
        }
        for (id, token) in existingTokens {
            try await CredentialRegistry.shared.setToken(token, for: .server(providerID: "emby:\(id)"))
        }
        if let existingAccount {
            UserDefaults.standard.set(existingAccount, forKey: EmbySession.accountKey)
        }
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        try await super.tearDown()
    }

    private func signIn(url: URL? = nil, username: String = "bain", password: String = "pw") async throws -> EmbySession.Account {
        try await EmbySession.signIn(serverURL: url ?? base, username: username, password: password, transport: server.transport)
    }

    private func authenticateJSON(serverID: String) -> String {
        EmbyLiveFixtures.authenticate4_10_2.replacingOccurrences(of: EmbyLiveFixtures.serverID, with: serverID)
    }

    private func respondWithSuccessfulSignIn() {
        server.respond("/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
        server.respond("/Users/AuthenticateByName", method: "POST", body: EmbyLiveFixtures.authenticate4_10_2)
        server.respond("/Users/\(EmbyLiveFixtures.userID)", body: EmbyLiveFixtures.userAdmin4_10_2)
    }

    private func assertSignInThrows(_ expected: EmbySignInError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await signIn()
            XCTFail("expected a throw", file: file, line: line)
        } catch let error as EmbySignInError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch { XCTFail("got \(error)", file: file, line: line) }
        XCTAssertNil(EmbySession.account, "nothing persisted", file: file, line: line)
        XCTAssertNil(CredentialRegistry.shared.token(for: .server(providerID: "emby:\(EmbyLiveFixtures.serverID)")),
                     file: file, line: line)
    }

    // MARK: - Happy path

    func test_signIn_persistsAccountAndToken_andRegistersProvider() async throws {
        respondWithSuccessfulSignIn()

        let account = try await signIn()

        XCTAssertEqual(account.providerID, "emby:\(EmbyLiveFixtures.serverID)")
        XCTAssertEqual(account.userID, EmbyLiveFixtures.userID)
        XCTAssertEqual(account.userName, "m-transport-auth-pw")
        XCTAssertEqual(account.serverURL, base)
        XCTAssertEqual(EmbySession.account, account)
        XCTAssertEqual(CredentialRegistry.shared.token(for: .server(providerID: account.providerID)), EmbyLiveFixtures.dummyToken)
        XCTAssertEqual(account.policy.isAdministrator, true, "from Users/{id}")
        let provider = MediaProviderRegistry.shared.provider(for: account.providerID)
        XCTAssertEqual(provider?.kind, .emby)
        XCTAssertEqual(provider?.accountID, EmbyLiveFixtures.userID)
        XCTAssertEqual(server.headerProblems, [])
        // The policy read carries the token; the sign-in and the probe do not.
        XCTAssertFalse(server.requests("POST", "/Users/AuthenticateByName")[0].value(forHTTPHeaderField: "Authorization")!.contains("Token="))
        XCTAssertTrue(server.requests("GET", "/Users/\(EmbyLiveFixtures.userID)")[0]
            .value(forHTTPHeaderField: "Authorization")!.hasSuffix(#"Token="\#(EmbyLiveFixtures.dummyToken)""#))
    }

    func test_signIn_callsOnChanged_afterTheRegistryIsRebuilt_andOnSignOut() async throws {
        let previous = EmbySession.onChanged
        defer { EmbySession.onChanged = previous }
        var registeredAtCall: [Bool] = []
        let providerID = "emby:\(EmbyLiveFixtures.serverID)"
        EmbySession.onChanged = { registeredAtCall.append(MediaProviderRegistry.shared.provider(for: providerID) != nil) }
        respondWithSuccessfulSignIn()

        _ = try await signIn()
        await EmbySession.signOut(transport: { _ in throw URLError(.timedOut) })

        XCTAssertEqual(registeredAtCall, [true, false])
    }

    func test_signIn_acceptsEachRealPublicInfo() async throws {
        let infos = [(EmbyLiveFixtures.publicInfo4_10_2, EmbyLiveFixtures.serverID),
                     (EmbyLiveFixtures.publicInfo4_9_5, "5f22d4f3e0c4481b895830bc337c85f5"),
                     (EmbyLiveFixtures.publicInfo4_8_11, "b295bd17cada416faae6268b47baf833")]
        for (info, id) in infos {
            server.reset()
            server.respond("/System/Info/Public", body: info)
            server.respond("/Users/AuthenticateByName", method: "POST", body: authenticateJSON(serverID: id))
            let account = try await signIn()
            XCTAssertEqual(account.serverID, id)
            await EmbySession.signOut(transport: { _ in throw URLError(.timedOut) })
        }
    }

    func test_signIn_policyReadFailure_isNotFatal() async throws {
        server.respond("/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
        server.respond("/Users/AuthenticateByName", method: "POST", body: EmbyLiveFixtures.authenticate4_10_2)
        server.respond("/Users/\(EmbyLiveFixtures.userID)", status: 500, body: EmbyLiveFixtures.sqliteBody, contentType: "text/plain")

        let account = try await signIn()

        XCTAssertEqual(account.policy, EmbySession.Policy())
    }

    func test_signIn_storesTheAdminAndDeletionPolicy() async throws {
        for (json, admin, deletion) in [(EmbyLiveFixtures.userAdmin4_10_2, true, true),
                                        (EmbyLiveFixtures.userNonAdmin4_10_2, false, false)] {
            server.reset()
            server.respond("/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
            server.respond("/Users/AuthenticateByName", method: "POST", body: EmbyLiveFixtures.authenticate4_10_2)
            server.respond("/Users/\(EmbyLiveFixtures.userID)", body: json)
            let account = try await signIn()
            XCTAssertEqual(account.policy.isAdministrator, admin)
            XCTAssertEqual(account.policy.enableContentDeletion, deletion)
            XCTAssertEqual(account.policy.enableContentDeletionFromFolders, [])
            XCTAssertEqual(account.policy.enableLiveTvAccess, true)
            await EmbySession.signOut(transport: { _ in throw URLError(.timedOut) })
        }
    }

    func test_signIn_passwordlessUser_sendsEmptyPw() async throws {
        respondWithSuccessfulSignIn()
        _ = try await signIn(password: "")
        let body = server.requests("POST", "/Users/AuthenticateByName")[0].httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(body?["Pw"] as? String, "")
        XCTAssertNil(body?["Password"])
    }

    func test_signIn_keepsATypedEmbyPath_whenItGoesToTheServer() async throws {
        server.respond("/emby/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
        server.respond("/emby/Users/AuthenticateByName", method: "POST", body: EmbyLiveFixtures.authenticate4_10_2)
        server.respond("/emby/Users/\(EmbyLiveFixtures.userID)", body: EmbyLiveFixtures.userAdmin4_10_2)
        let account = try await signIn(url: URL(string: "http://127.0.0.1:9/emby/web/index.html#!/home")!)
        XCTAssertEqual(account.serverURL.absoluteString, "http://127.0.0.1:9/emby")
    }

    // MARK: - Identity probe

    func test_signIn_rejectsJellyfin_beforeSendingAnyCredential() async {
        server.respond("/System/Info/Public", body: EmbyLiveFixtures.jellyfinPublicInfo12_1)
        await assertSignInThrows(.notEmby)
        XCTAssertEqual(server.requests("POST", "/Users/AuthenticateByName").count, 0)
    }

    func test_signIn_rejectsNonEmbyAnswers() async {
        for (status, body) in [(200, "<html>router login</html>"), (404, "not found"), (200, "{}"),
                               (200, ##"{"Id":"abc","Version":"10.10.7"}"##), (200, ##"{"Id":"","Version":"4.9.5.0"}"##),
                               (200, ##"{"Id":"abc","Version":"3.5.2.0"}"##), (200, ##"{"Id":"abc"}"##)] {
            server.reset()
            server.respond("/System/Info/Public", status: status, body: body)
            await assertSignInThrows(.notEmby)
            XCTAssertEqual(server.requests("POST", "/Users/AuthenticateByName").count, 0, body)
        }
    }

    func test_signIn_unreachable() async {
        do {
            _ = try await signIn()
            XCTFail("expected a throw")
        } catch MediaProviderError.unreachable {
        } catch { XCTFail("got \(error)") }
    }

    func test_signIn_untrustedCertificate_isNamed() async {
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                     .serverCertificateHasBadDate, .serverCertificateNotYetValid] {
            do {
                _ = try await EmbySession.signIn(serverURL: base, username: "bain", password: "pw",
                                                 transport: { _ in throw URLError(code) })
                XCTFail("expected a throw for \(code)")
            } catch EmbySignInError.untrustedCertificate {
            } catch { XCTFail("\(code) -> \(error)") }
        }
    }

    // MARK: - Versions

    func test_isSupported_floorIs4_8_11_0_asAFourIntegerTuple() {
        XCTAssertTrue(EmbySession.isSupported(version: "4.8.11.0"))
        XCTAssertTrue(EmbySession.isSupported(version: "4.9.5.0"))
        XCTAssertTrue(EmbySession.isSupported(version: "4.10.2.0"))
        XCTAssertTrue(EmbySession.isSupported(version: "4.11.0.13"))
        XCTAssertTrue(EmbySession.isSupported(version: "5.0.0.0"))
        XCTAssertTrue(EmbySession.isSupported(version: "4.8.11"), "a missing component is 0")
        XCTAssertFalse(EmbySession.isSupported(version: "4.8.10.0"))
        XCTAssertFalse(EmbySession.isSupported(version: "4.8.10.99"))
        XCTAssertFalse(EmbySession.isSupported(version: "4.8"))
        XCTAssertFalse(EmbySession.isSupported(version: "3.9.9.9"))
        XCTAssertFalse(EmbySession.isSupported(version: "4.x.11.0"))
        XCTAssertFalse(EmbySession.isSupported(version: "4.8.11.0-beta"))
        XCTAssertFalse(EmbySession.isSupported(version: ""))
        XCTAssertFalse(EmbySession.isSupported(version: nil))
    }

    func test_isEmbyVersion_needsFourNumbersAndMajor4() {
        XCTAssertTrue(EmbySession.isEmbyVersion("4.10.2.0"))
        XCTAssertFalse(EmbySession.isEmbyVersion("12.1.0"))
        XCTAssertFalse(EmbySession.isEmbyVersion("10.10.7.0"))
        XCTAssertFalse(EmbySession.isEmbyVersion("4.8.11"))
        XCTAssertFalse(EmbySession.isEmbyVersion("4.8.11.0.1"))
        XCTAssertFalse(EmbySession.isEmbyVersion("4.a.11.0"))
        XCTAssertFalse(EmbySession.isEmbyVersion("4..11.0"))
    }

    func test_signIn_rejectsOldServer_4_8_10() async {
        server.respond("/System/Info/Public",
                       body: EmbyLiveFixtures.publicInfo4_8_11.replacingOccurrences(of: "4.8.11.0", with: "4.8.10.0"))
        await assertSignInThrows(.serverTooOld(version: "4.8.10.0"))
        XCTAssertEqual(server.requests("POST", "/Users/AuthenticateByName").count, 0)
    }

    // MARK: - Sign-in failures (nothing persisted)

    func test_signIn_wrongPassword_isInvalidCredentials_andIsNeverRetried() async {
        server.respond("/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
        server.respond("/Users/AuthenticateByName", method: "POST", status: 401,
                       body: EmbyLiveFixtures.invalidCredentialsBody, contentType: "text/plain")
        await assertSignInThrows(.invalidCredentials)
        XCTAssertEqual(server.requests("POST", "/Users/AuthenticateByName").count, 1)
    }

    func test_signIn_lockout_keepsTheServerMessage() async {
        server.respond("/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
        server.respond("/Users/AuthenticateByName", method: "POST", status: 403,
                       body: EmbyLiveFixtures.lockedOutBody, contentType: "text/plain")
        await assertSignInThrows(.lockedOut(message: EmbyLiveFixtures.lockedOutBody))
        XCTAssertEqual(server.requests("POST", "/Users/AuthenticateByName").count, 1)
    }

    func test_signIn_serverIDMismatch_fails() async {
        server.respond("/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
        server.respond("/Users/AuthenticateByName", method: "POST", body: authenticateJSON(serverID: "mismatch-test"))
        await assertSignInThrows(.notEmby)
    }

    func test_signIn_responseWithoutToken_isUnauthorized() async {
        server.respond("/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
        server.respond("/Users/AuthenticateByName", method: "POST",
                       body: EmbyLiveFixtures.authenticate4_10_2.replacingOccurrences(of: "\"AccessToken\":\"\(EmbyLiveFixtures.dummyToken)\",", with: ""))
        do {
            _ = try await signIn()
            XCTFail("expected a throw")
        } catch MediaProviderError.unauthorized {
        } catch { XCTFail("got \(error)") }
        XCTAssertNil(EmbySession.account)
    }

    // MARK: - Sign-out

    func test_signOut_clearsLocalState_andStillCallsSessionsLogout() async throws {
        respondWithSuccessfulSignIn()
        server.respond("/Sessions/Logout", method: "POST", status: 204)
        let account = try await signIn()

        await EmbySession.signOut(transport: server.transport)

        XCTAssertNil(EmbySession.account)
        XCTAssertNil(CredentialRegistry.shared.token(for: .server(providerID: account.providerID)))
        XCTAssertNil(MediaProviderRegistry.shared.provider(for: account.providerID))
        for _ in 0..<100 where server.requests("POST", "/Sessions/Logout").isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let logout = server.requests("POST", "/Sessions/Logout")
        XCTAssertEqual(logout.count, 1)
        XCTAssertTrue(logout[0].value(forHTTPHeaderField: "Authorization")!.hasSuffix(#"Token="\#(EmbyLiveFixtures.dummyToken)""#))
    }

    func test_signOut_unreachableServer_stillClearsEverything() async throws {
        respondWithSuccessfulSignIn()
        let account = try await signIn()
        await EmbySession.signOut(transport: { _ in throw URLError(.timedOut) })
        XCTAssertNil(EmbySession.account)
        XCTAssertNil(CredentialRegistry.shared.token(for: .server(providerID: account.providerID)))
    }

    // MARK: - Stored account

    func test_storedProvider_rebuildsFromTheAccount() async throws {
        respondWithSuccessfulSignIn()
        _ = try await signIn()
        let provider = try XCTUnwrap(EmbySession.storedProvider())
        XCTAssertEqual(provider.id, "emby:\(EmbyLiveFixtures.serverID)")
        XCTAssertEqual(provider.kind, .emby)
        XCTAssertEqual(provider.client.token, EmbyLiveFixtures.dummyToken)
        XCTAssertEqual(provider.accountID, EmbyLiveFixtures.userID)
        XCTAssertFalse(provider.supportsWatchlist)
        XCTAssertEqual(OtherServerKind.entry(for: .emby)?.account()?.providerID, provider.id)
        let music = try XCTUnwrap(OtherServerKind.entry(for: .emby)?.storedMusicProvider())
        XCTAssertEqual(music.id, provider.id, "the music registry shares the video provider's id")
        XCTAssertEqual(music.kind, .emby)
    }

    func test_storedProvider_isNilWhenTheKeychainLostTheToken() async throws {
        respondWithSuccessfulSignIn()
        let account = try await signIn()
        await CredentialRegistry.shared.clearToken(for: .server(providerID: account.providerID))
        XCTAssertNil(EmbySession.storedProvider())
    }

    // MARK: - URL input

    func test_normalizedServerURL_acceptsBrowserURLs_keepingProxySubpathAndTypedEmby() {
        let cases = [
            ("http://nas:8096/web/index.html#!/home", "http://nas:8096"),
            ("http://nas:8096/web/index.html#!/item?id=1&serverId=2", "http://nas:8096"),
            ("https://host.example/emby/web/index.html#!/home", "https://host.example/emby"),
            ("https://host.example/proxy/web/", "https://host.example/proxy"),
            ("https://host.example/proxy/emby", "https://host.example/proxy/emby"),
            ("http://nas:8096/emby", "http://nas:8096/emby"),
            ("http://nas:8096/", "http://nas:8096"),
            ("http://nas:8096", "http://nas:8096")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(EmbySession.normalizedServerURL(URL(string: input)!).absoluteString, expected, input)
        }
    }

    // MARK: - Jellyfin and Emby tell each other apart

    func test_jellyfinSession_rejectsAnEmbyPublicInfo() async {
        let jellyfin = FakeJellyfinServer()
        for info in [EmbyLiveFixtures.publicInfo4_10_2, EmbyLiveFixtures.publicInfo4_9_5, EmbyLiveFixtures.publicInfo4_8_11] {
            jellyfin.reset()
            jellyfin.respond("/System/Info/Public", body: info)
            do {
                _ = try await JellyfinSession.signIn(serverURL: base, username: "bain", password: "pw", transport: jellyfin.transport)
                XCTFail("expected a throw")
            } catch JellyfinSignInError.notJellyfin {
            } catch { XCTFail("got \(error)") }
            XCTAssertEqual(jellyfin.requests.count, 1, "no credential reached the wrong backend")
        }
    }
}
