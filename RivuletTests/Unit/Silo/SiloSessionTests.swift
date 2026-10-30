// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Security
import XCTest
@testable import Rivulet

/// These cases exercise staging/cancellation only: none commits an account,
/// writes Keychain/defaults, replaces the real account, or invokes onChanged.
@MainActor
final class SiloSessionTests: XCTestCase {
    private let base = URL(string: "https://silo-auth-tests.invalid/proxy/silo")!

    func test_cancelledLoginResponseCannotCreatePendingOrCommittedAccount() async {
        let existing = SiloSession.account
        let server = SiloAuthTestServer()
        let gate = SiloAuthRequestGate()
        await server.configureLogin(baseURL: base, loginGate: gate)
        defer { SiloSession.cancelPendingSignIn() }
        let operation = Task { try await SiloSession.signIn(serverURL: base, username: "alice", password: "password", transport: server.transport) }
        await fulfillment(of: [gate.entered], timeout: 5)
        SiloSession.cancelPendingSignIn()
        await gate.release()
        do {
            _ = try await operation.value
            XCTFail("A late login response must not reopen a cancelled sign-in.")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(SiloSession.hasPendingSignIn)
        XCTAssertEqual(SiloSession.account, existing)
    }

    func test_profileSelectionCancelledAfterAuthorizationCannotCommit() async throws {
        let existing = SiloSession.account
        let server = SiloAuthTestServer()
        await server.configureLogin(baseURL: base)
        defer { SiloSession.cancelPendingSignIn() }
        let profiles = try await SiloSession.signIn(serverURL: base, username: "alice", password: "password", transport: server.transport)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(SiloSession.account, existing, "login itself must not register a default profile")
        let gate = SiloAuthRequestGate()
        await server.respond("GET", "/proxy/silo/api/v2/home/capabilities", [.init(body: #"{"revision":"home-1","state":"available","allowed":true}"#, gate: gate)])
        let operation = Task { try await SiloSession.selectProfile(profile) }
        await fulfillment(of: [gate.entered], timeout: 5)
        SiloSession.cancelProfileSelection()
        await gate.release()
        do {
            try await operation.value
            XCTFail("A profile page pop must invalidate the pending commit.")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SiloSession.account, existing)
        XCTAssertTrue(SiloSession.hasPendingSignIn, "returning from PIN/profile pages must preserve the staged login")
        let stillAvailable = try await SiloSession.profiles()
        XCTAssertEqual(stillAvailable.map(\.id), [profile.id])
    }

    func test_pinResponseAfterLeavingFlowCannotUnlockOrCommitProfile() async throws {
        let existing = SiloSession.account
        let server = SiloAuthTestServer()
        await server.configureLogin(baseURL: base, locked: true)
        defer { SiloSession.cancelPendingSignIn() }
        let profiles = try await SiloSession.signIn(serverURL: base, username: "alice", password: "password", transport: server.transport)
        let profile = try XCTUnwrap(profiles.first)
        let gate = SiloAuthRequestGate()
        await server.respond("POST", "/proxy/silo/api/v2/profiles/profile-a/verify-pin", [.init(body: #"{"valid":true,"profile_token":"proof-a","expires_at":null}"#, gate: gate)])
        let operation = Task { try await SiloSession.selectProfile(profile, pin: "1234") }
        await fulfillment(of: [gate.entered], timeout: 5)
        SiloSession.cancelPendingSignIn()
        await gate.release()
        do {
            try await operation.value
            XCTFail("A cancelled PIN response must never commit a profile.")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SiloSession.account, existing)
        XCTAssertFalse(SiloSession.hasPendingSignIn)
        let requests = await server.requests()
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/home/capabilities") == true })
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/verify-pin") == true }.count, 1)
    }

    func test_wrongPINSpendsExactlyOneAttemptAndDoesNotCommit() async throws {
        let existing = SiloSession.account
        let server = SiloAuthTestServer()
        await server.configureLogin(baseURL: base, locked: true)
        defer { SiloSession.cancelPendingSignIn() }
        let profiles = try await SiloSession.signIn(serverURL: base, username: "alice", password: "password", transport: server.transport)
        let profile = try XCTUnwrap(profiles.first)
        await server.respond("POST", "/proxy/silo/api/v2/profiles/profile-a/verify-pin", [.init(body: #"{"valid":false,"expires_at":null}"#)])
        do {
            try await SiloSession.selectProfile(profile, pin: "0000")
            XCTFail("Wrong PIN must fail.")
        } catch SiloSignInError.incorrectPIN {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SiloSession.account, existing)
        XCTAssertTrue(SiloSession.hasPendingSignIn)
        let requests = await server.requests()
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/verify-pin") == true }.count, 1)
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/home/capabilities") == true })
    }

    func test_originMismatchStopsBeforeCredentialsAreSent() async {
        let server = SiloAuthTestServer()
        let info = #"{"api_major":2,"server_version":"test","request_origin":"https://other.invalid","links":{"identity":"/api/v2/system/identity","capabilities":"/api/v2/capabilities","openapi":"/api/v2/openapi.json"}}"#
        await server.respond("GET", "/proxy/silo/api/v2/system/info", [.init(body: info)])
        do {
            _ = try await SiloSession.probe(base, transport: server.transport)
            XCTFail("A different reached origin must be rejected before login.")
        } catch SiloSignInError.originMismatch {
        } catch { XCTFail("Unexpected error: \(error)") }
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.httpBody)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
    }
}

/// These cases commit isolated fixture accounts. Preserve the app's account and
/// callback, and delete only the unique Keychain entries each test creates.
@MainActor
final class SiloServerNameTests: XCTestCase {
    private let base = URL(string: "https://silo-auth-tests.invalid/proxy/silo")!
    private var savedAccount: Data?
    private var savedOnChanged: (() -> Void)?
    private var secretKeys: Set<String> = []

    override func setUp() async throws {
        try await super.setUp()
        savedAccount = UserDefaults.standard.data(forKey: SiloSession.accountKey)
        savedOnChanged = SiloSession.onChanged
        SiloSession.onChanged = nil
        SiloSession.cancelPendingSignIn()
        UserDefaults.standard.removeObject(forKey: SiloSession.accountKey)
    }

    override func tearDown() async throws {
        SiloSession.onChanged = nil
        // Clear fixture metadata first so signOut clears in-memory authority
        // without revoking through the real network transport.
        UserDefaults.standard.removeObject(forKey: SiloSession.accountKey)
        await SiloSession.signOut()
        for key in secretKeys { SecItemDelete(attributes(key) as CFDictionary) }
        if let savedAccount { UserDefaults.standard.set(savedAccount, forKey: SiloSession.accountKey) }
        SiloSession.onChanged = savedOnChanged
        try await super.tearDown()
    }

    func test_firstLoginCommitsNativeBrandingNameNotHost() async throws {
        let server = SiloAuthTestServer()
        await server.configureLogin(baseURL: base)
        let profiles = try await SiloSession.signIn(
            serverURL: base, username: "alice", password: "password", transport: server.transport
        )
        XCTAssertNil(SiloSession.account, "Public branding must not commit a staged login.")
        try await SiloSession.selectProfile(try XCTUnwrap(profiles.first))
        let account = try XCTUnwrap(SiloSession.account)
        rememberSecrets(for: account)
        XCTAssertEqual(account.serverName, "Harbor Cinema")
        XCTAssertEqual(account.serverID, "silo-auth-test")
        XCTAssertEqual(SiloSession.storedProvider()?.displayName, "Harbor Cinema")
        let requests = await server.requests()
        let branding = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/theme/branding") == true })
        XCTAssertNil(branding.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(branding.value(forHTTPHeaderField: "X-Profile-Id"))
        XCTAssertNil(branding.value(forHTTPHeaderField: "X-Profile-Token"))
        XCTAssertFalse(requests.contains { $0.url?.path.contains("/api/v1/") == true })
    }

    func test_restoreMigratesSavedIPNameAndPublishesDisplayMetadataWithoutChangingAuthority() async throws {
        let server = SiloAuthTestServer()
        await configureRestoration(server)
        let old = try seedSavedAccount()
        let revision = SiloSession.authorityRevision
        let registry = MediaProviderRegistry()
        var changes = 0
        SiloSession.onChanged = {
            changes += 1
            if let provider = SiloSession.storedProvider() { registry.register(provider) }
        }

        try await SiloSession.restore(transport: server.transport)

        let restored = try XCTUnwrap(SiloSession.account)
        XCTAssertEqual(restored.serverName, "Harbor Cinema")
        XCTAssertEqual(restored.serverURL, old.serverURL)
        XCTAssertEqual(restored.serverID, old.serverID)
        XCTAssertEqual(restored.userID, old.userID)
        XCTAssertEqual(restored.profileID, old.profileID)
        XCTAssertEqual(restored.profileName, old.profileName)
        XCTAssertEqual(restored.credentialID, old.credentialID)
        XCTAssertEqual(SiloSession.authorityRevision, revision, "A display rename is not a profile switch.")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(registry.provider(for: old.providerID)?.displayName, "Harbor Cinema")
        XCTAssertEqual(try savedCredentials(old).accessToken, "restored-access")
        XCTAssertEqual(try secret("profile.\(old.credentialID).\(old.profileID)"), Data("profile-proof".utf8))
        let requests = await server.requests()
        let capability = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/home/capabilities") == true })
        XCTAssertEqual(capability.value(forHTTPHeaderField: "X-Profile-Id"), old.profileID)
        XCTAssertEqual(capability.value(forHTTPHeaderField: "X-Profile-Token"), "profile-proof")
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/auth/logout") == true })

        try await SiloSession.restore(transport: server.transport)
        XCTAssertEqual(changes, 1, "An unchanged name must not trigger another source reload.")
    }

    func test_restorationIdentityMismatchCannotRenameOrSendSavedCredentials() async throws {
        let server = SiloAuthTestServer()
        await configureRestoration(server)
        await server.configureDiscovery(baseURL: base, serverID: "different-server")
        let old = try seedSavedAccount()
        do {
            try await SiloSession.restore(transport: server.transport)
            XCTFail("A replacement deployment must not overwrite saved display metadata.")
        } catch SiloSignInError.serverChanged {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SiloSession.account, old)
        XCTAssertEqual(try savedCredentials(old).accessToken, "saved-access")
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.httpBody == nil })
    }

    func test_restorationAccountMismatchCannotRenameOrReplaceCredentials() async throws {
        let server = SiloAuthTestServer()
        await configureRestoration(server)
        await server.respond("GET", "/proxy/silo/api/v2/account/me", [.init(body: """
        {"id":"different-account","username":"mallory","password_change_required":false}
        """)])
        let old = try seedSavedAccount()
        do {
            try await SiloSession.restore(transport: server.transport)
            XCTFail("A refreshed token for another account must not commit a name or credentials.")
        } catch SiloSignInError.accountChanged {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SiloSession.account, old)
        XCTAssertEqual(try savedCredentials(old).accessToken, "saved-access")
        let requests = await server.requests()
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/theme/branding") == true })
    }

    func test_failedProfileVerificationCannotRenameSavedAccount() async throws {
        let server = SiloAuthTestServer()
        await configureRestoration(server)
        await server.respond("GET", "/proxy/silo/api/v2/home/capabilities", [.init(
            status: 403, body: SiloAuthTestServer.problem(status: 403, code: "profile_locked", detail: "Profile is locked.")
        )])
        let old = try seedSavedAccount()
        do {
            try await SiloSession.restore(transport: server.transport)
            XCTFail("The saved profile must be verified before publishing a name.")
        } catch let error as SiloAPIError {
            XCTAssertEqual(error.status, 403)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SiloSession.account, old)
        XCTAssertEqual(try savedCredentials(old).userID, old.userID)
        XCTAssertEqual(try secret("profile.\(old.credentialID).\(old.profileID)"), Data("profile-proof".utf8))
        let requests = await server.requests()
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/theme/branding") == true })
    }

    func test_missingOrBlankNativeBrandingCannotEraseSavedName() async throws {
        let server = SiloAuthTestServer()
        await configureRestoration(server)
        let old = try seedSavedAccount()
        for body in [#"{"server_name":" \n ","storage_available":false}"#, #"{"storage_available":false}"#] {
            await server.respond("GET", "/proxy/silo/api/v2/theme/branding", [.init(body: body)])
            do {
                try await SiloSession.restore(transport: server.transport)
                XCTFail("Malformed branding is not a server rename.")
            } catch SiloSignInError.invalidResponse {
            } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(SiloSession.account, old)
            XCTAssertEqual(try savedCredentials(old).userID, old.userID)
        }
    }

    func test_publicBrandingFailureDoesNotInvalidateVerifiedLoginOrProfile() async throws {
        let server = SiloAuthTestServer()
        await configureRestoration(server)
        let old = try seedSavedAccount()
        let revision = SiloSession.authorityRevision
        var changes = 0
        SiloSession.onChanged = { changes += 1 }
        for status in [401, 403, 404] {
            await server.respond("GET", "/proxy/silo/api/v2/theme/branding", [.init(status: status,
                body: SiloAuthTestServer.problem(status: status, code: "branding_unavailable", detail: "Branding unavailable"))])
            do {
                try await SiloSession.restore(transport: server.transport)
                XCTFail("The branding failure must remain visible to the caller")
            } catch let error as SiloAPIError {
                XCTAssertEqual(error.status, status)
            }
            XCTAssertEqual(SiloSession.account, old)
            XCTAssertEqual(SiloSession.authorityRevision, revision)
            XCTAssertEqual(changes, 0)
            XCTAssertEqual(try savedCredentials(old).userID, old.userID)
            XCTAssertEqual(SiloSession.storedProvider()?.id, old.providerID)
        }
    }

    private func configureRestoration(_ server: SiloAuthTestServer) async {
        await server.configureLogin(baseURL: base, locked: true)
        await server.respond("POST", "/proxy/silo/api/v2/auth/refresh", [.init(body: """
        {"access_token":"restored-access","refresh_token":"restored-refresh","expires_in":3600}
        """)])
        await server.respond("GET", "/proxy/silo/api/v2/account/me", [.init(body: """
        {"id":"account-a","username":"alice","password_change_required":false}
        """)])
    }

    private func seedSavedAccount() throws -> SiloSession.Account {
        let account = SiloSession.Account(
            serverURL: base, serverID: "silo-auth-test", serverName: "192.0.2.23",
            userID: "account-a", userName: "alice", profileID: "profile-a",
            profileName: "Alice", credentialID: UUID()
        )
        rememberSecrets(for: account)
        let credentials = SiloLoginCredentials(
            accessToken: "saved-access", refreshToken: "saved-refresh",
            expiresAt: Date().addingTimeInterval(3600), serverID: account.serverID, userID: account.userID
        )
        try saveSecret(JSONEncoder().encode(credentials), key: "login.\(account.credentialID)")
        try saveSecret(Data("profile-proof".utf8), key: "profile.\(account.credentialID).\(account.profileID)")
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: SiloSession.accountKey)
        return account
    }

    private func rememberSecrets(for account: SiloSession.Account) {
        secretKeys.insert("login.\(account.credentialID)")
        secretKeys.insert("profile.\(account.credentialID).\(account.profileID)")
    }

    private func attributes(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.rivulet.silo", kSecAttrAccount as String: key]
    }

    private func saveSecret(_ data: Data, key: String) throws {
        var item = attributes(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SiloSignInError.keychain }
    }

    private func secret(_ key: String) throws -> Data {
        var query = attributes(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw SiloSignInError.keychain }
        return data
    }

    private func savedCredentials(_ account: SiloSession.Account) throws -> SiloLoginCredentials {
        try JSONDecoder().decode(SiloLoginCredentials.self, from: secret("login.\(account.credentialID)"))
    }
}
