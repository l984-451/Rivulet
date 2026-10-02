// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinSessionTests.swift
//  RivuletTests
//
//  These tests write the test host's real Keychain and UserDefaults (like
//  CredentialRegistryTests). A Jellyfin sign-in already on the simulator is
//  set aside in setUp and put back in tearDown; its token lives under its
//  own server id, which no test touches.
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinSessionTests: XCTestCase {
    private let server = FakeJellyfinServer()
    /// Port 9 (discard) refuses at once, so signOut's best-effort logout,
    /// which uses a real URLSession, fails fast.
    private let base = URL(string: "http://127.0.0.1:9")!
    private let testProviderID = "jellyfin:session-test"
    private var existingAccount: Data?

    override func setUp() async throws {
        try await super.setUp()
        existingAccount = UserDefaults.standard.data(forKey: JellyfinSession.accountKey)
    }

    override func tearDown() async throws {
        if JellyfinSession.account?.providerID == testProviderID {
            await JellyfinSession.signOut()
        }
        await CredentialRegistry.shared.clearToken(for: .server(providerID: testProviderID))
        if let existingAccount {
            UserDefaults.standard.set(existingAccount, forKey: JellyfinSession.accountKey)
            MediaProviderRegistry.shared.populateFromCurrentAuth()
        }
        try await super.tearDown()
    }

    private func signIn(url: URL? = nil, password: String = "pw") async throws -> JellyfinSession.Account {
        try await JellyfinSession.signIn(
            serverURL: url ?? base, username: "bain", password: password, transport: server.transport
        )
    }

    func test_signInAndSignOut_callOnChanged_afterTheRegistryIsRebuilt() async throws {
        let previous = JellyfinSession.onChanged
        defer { JellyfinSession.onChanged = previous }
        var registeredAtCall: [Bool] = []
        let providerID = testProviderID
        JellyfinSession.onChanged = {
            registeredAtCall.append(MediaProviderRegistry.shared.provider(for: providerID) != nil)
        }
        respondWithSuccessfulSignIn()

        _ = try await signIn()
        await JellyfinSession.signOut(transport: { _ in throw URLError(.timedOut) })

        XCTAssertEqual(registeredAtCall, [true, false],
                       "the hook must see the provider after sign-in and its absence after sign-out")
    }

    // MARK: - Versions

    func test_isSupported_floorIs10_10() {
        XCTAssertTrue(JellyfinSession.isSupported(version: "12.1.0"))
        XCTAssertTrue(JellyfinSession.isSupported(version: "10.11.11"))
        XCTAssertTrue(JellyfinSession.isSupported(version: "10.10.7"))
        XCTAssertFalse(JellyfinSession.isSupported(version: "10.9.11"))
        XCTAssertFalse(JellyfinSession.isSupported(version: nil))
        XCTAssertFalse(JellyfinSession.isSupported(version: "dev"))
    }

    // MARK: - URL input

    func test_normalizedServerURL_acceptsBrowserURLs() {
        let cases = [
            ("http://nas:8096/web/#/home.html", "http://nas:8096"),
            ("http://nas:8096/web/index.html#!/home.html", "http://nas:8096"),
            ("https://host.example/jellyfin/web/", "https://host.example/jellyfin"),
            ("https://host.example/jellyfin", "https://host.example/jellyfin"),
            ("http://nas:8096/", "http://nas:8096")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(JellyfinSession.normalizedServerURL(URL(string: input)!).absoluteString, expected, input)
        }
    }

    // MARK: - Sign-in failures (nothing persisted)

    // Failure fixtures use the test server id, so "nothing persisted" would
    // catch an account saved under it.

    func test_signIn_rejectsEmby() async {
        server.respond("/System/Info/Public", body: JellyfinFixtures.publicInfo(id: "session-test", product: "Emby Server"))
        await assertSignInThrows(JellyfinSignInError.notJellyfin)
    }

    func test_signIn_rejectsHTMLPage() async {
        server.respond("/System/Info/Public", body: "<html>router login</html>")
        await assertSignInThrows(JellyfinSignInError.notJellyfin)
    }

    func test_signIn_rejectsOldServer() async {
        server.respond("/System/Info/Public", body: JellyfinFixtures.publicInfo(id: "session-test", version: "10.8.13"))
        await assertSignInThrows(JellyfinSignInError.serverTooOld(version: "10.8.13"))
    }

    /// A self-signed HTTPS server is reachable; telling the user to check the
    /// address and port sends them the wrong way.
    func test_signIn_untrustedCertificate_isNamed() async {
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                     .serverCertificateHasBadDate, .serverCertificateNotYetValid] {
            do {
                _ = try await JellyfinSession.signIn(serverURL: base, username: "bain", password: "pw",
                                                     transport: { _ in throw URLError(code) })
                XCTFail("expected a throw for \(code)")
            } catch JellyfinSignInError.untrustedCertificate {
            } catch { XCTFail("\(code) -> \(error)") }
        }
    }

    func test_signIn_unreachable() async {
        do {
            _ = try await signIn()
            XCTFail("expected a throw")
        } catch MediaProviderError.unreachable {
        } catch { XCTFail("got \(error)") }
    }

    func test_signIn_wrongPassword_isUnauthorized_andSendsPw() async {
        server.respond("/System/Info/Public", body: JellyfinFixtures.publicInfo(id: "session-test"))
        server.respond("/Users/AuthenticateByName", status: 401)
        do {
            _ = try await signIn(password: "")
            XCTFail("expected a throw")
        } catch MediaProviderError.unauthorized {
        } catch { XCTFail("got \(error)") }
        XCTAssertEqual(server.jsonBody(1)["Username"] as? String, "bain")
        XCTAssertEqual(server.jsonBody(1)["Pw"] as? String, "", "an empty password is valid on Jellyfin")
        XCTAssertNotEqual(JellyfinSession.account?.providerID, testProviderID)
    }

    func test_signIn_probesTheNormalizedURL() async {
        server.respond("/System/Info/Public", body: JellyfinFixtures.publicInfo(version: "10.8.0"))
        _ = try? await signIn(url: URL(string: "http://nas:8096/web/#/home.html")!)
        XCTAssertEqual(server.requests.first?.url?.absoluteString, "http://nas:8096/System/Info/Public")
    }

    private func assertSignInThrows(_ expected: JellyfinSignInError, line: UInt = #line) async {
        do {
            _ = try await signIn()
            XCTFail("expected a throw", line: line)
        } catch let error as JellyfinSignInError {
            XCTAssertEqual(error, expected, line: line)
        } catch { XCTFail("got \(error)", line: line) }
        XCTAssertNotEqual(JellyfinSession.account?.providerID, testProviderID, line: line)
    }

    // MARK: - Round trip

    private func respondWithSuccessfulSignIn() {
        server.respond("/System/Info/Public", body: JellyfinFixtures.publicInfo(id: "session-test"))
        server.respond("/Users/AuthenticateByName",
                       body: #"{"AccessToken":"tok-1","ServerId":"session-test","User":{"Id":"user-1","Name":"bain"}}"#)
    }

    /// Sign-out must not wait on the server: an unreachable one would hold the
    /// row for the 60s request timeout. Local state goes first, then logout.
    func test_signOut_forgetsLocally_beforeContactingTheServer() async throws {
        respondWithSuccessfulSignIn()
        _ = try await signIn()

        let sent = expectation(description: "logout sent")
        let tokenAtLogout = TokenProbe()
        let scope = CredentialScope.server(providerID: testProviderID)
        let credentials = CredentialRegistry.shared
        await JellyfinSession.signOut(transport: { _ in
            tokenAtLogout.record(credentials.token(for: scope))
            sent.fulfill()
            throw URLError(.timedOut)
        })

        XCTAssertNil(JellyfinSession.account)
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertTrue(tokenAtLogout.wasNil, "the token was still stored when logout went out")
    }

    func test_signIn_persists_registers_andSurvivesPlexRepopulate_thenSignOutClears() async throws {
        respondWithSuccessfulSignIn()

        let account = try await signIn()
        XCTAssertEqual(account.providerID, testProviderID)
        XCTAssertEqual(account.serverName, "NAS")
        XCTAssertEqual(JellyfinSession.account, account)
        XCTAssertEqual(CredentialRegistry.shared.token(for: .server(providerID: testProviderID)), "tok-1")
        XCTAssertEqual(MediaProviderRegistry.shared.provider(for: testProviderID)?.kind, .jellyfin)

        // A Plex sign-in, sign-out or server switch repopulates the registry.
        // That used to wipe every provider.
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        XCTAssertNotNil(MediaProviderRegistry.shared.provider(for: testProviderID))

        await JellyfinSession.signOut()
        XCTAssertNil(JellyfinSession.account)
        XCTAssertNil(CredentialRegistry.shared.token(for: .server(providerID: testProviderID)))
        XCTAssertNil(MediaProviderRegistry.shared.provider(for: testProviderID))
    }
}

/// What the Keychain held when the logout request went out. Written from the
/// transport, off the main actor.
private nonisolated final class TokenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: String??

    func record(_ token: String?) { lock.withLock { recorded = .some(token) } }
    var wasNil: Bool { lock.withLock { recorded == .some(nil) } }
}
