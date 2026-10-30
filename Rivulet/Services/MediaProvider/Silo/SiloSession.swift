// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Security

extension Notification.Name {
    static let siloAuthorityDidChange = Notification.Name("siloAuthorityDidChange")
}

@MainActor
enum SiloSession {
    struct Account: Codable, Equatable, Sendable {
        let serverURL: URL
        let serverID: String
        let serverName: String
        let userID: String
        let userName: String
        let profileID: String
        let profileName: String
        let credentialID: UUID
        var providerID: String { "silo:\(serverID):\(profileID)" }
    }

    private struct Pending {
        let id: UUID
        let serverURL: URL
        let serverID: String
        let serverName: String
        let user: SiloLoginAccount
        let authority: SiloTokenAuthority
        let transport: SiloClient.Transport
    }

    static let accountKey = "siloAccount"
    static var onChanged: (() -> Void)?
    private(set) static var authorityRevision: UInt64 = 0
    private static var pending: Pending?
    private static var activeAuthority: SiloTokenAuthority?
    private static var activeCredentialID: UUID?
    private static var operation = UUID()
    private static var deviceAttempt: (url: URL, code: String, canCancel: Bool, transport: SiloClient.Transport)?

    static var account: Account? {
        guard let data = UserDefaults.standard.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    static var hasPendingSignIn: Bool { pending != nil }

    static func storedProvider() -> SiloProvider? {
        guard let account, let authority = authority(for: account) else { return nil }
        let proof = SiloSecrets.get("profile.\(account.credentialID).\(account.profileID)")
        return SiloProvider(
            serverID: account.serverID, displayName: account.serverName, profileID: account.profileID,
            client: client(baseURL: account.serverURL, authority: authority,
                           profileID: account.profileID, profileToken: proof),
            authorityRevision: authorityRevision
        )
    }

    /// Launch restoration verifies the deployment and login account before
    /// accepting the saved profile. A missing/locked profile is not replaced by
    /// the primary profile: the profile chooser remains the recovery route.
    static func restore(
        transport: @escaping SiloClient.Transport = { try await SiloHTTP.data(for: $0) }
    ) async throws {
        guard let saved = account, let authority = authority(for: saved, transport: transport) else { return }
        let capturedOperation = operation
        do {
            let identity = try await probe(saved.serverURL, transport: transport)
            guard identity == saved.serverID else { throw SiloSignInError.serverChanged }
            let unscoped = client(baseURL: saved.serverURL, authority: authority, transport: transport)
            let user: SiloLoginAccount = try await unscoped.get("account/me")
            guard user.id == saved.userID else { throw SiloSignInError.accountChanged }
            guard !user.passwordChangeRequired else { throw SiloSignInError.passwordChangeRequired }
            let profiles: SiloProfileCollection = try await unscoped.get("profiles")
            guard profiles.items.contains(where: { $0.id == saved.profileID }) else { throw SiloSignInError.profileMissing }
            let proof = SiloSecrets.get("profile.\(saved.credentialID).\(saved.profileID)")
            let scoped = client(baseURL: saved.serverURL, authority: authority,
                                profileID: saved.profileID, profileToken: proof, transport: transport)
            let _: SiloCapability = try await scoped.get("home/capabilities")
        } catch {
            // Keep account/profile metadata on transport and PIN errors so that
            // settings can reconnect or unlock without silently changing identity.
            if let problem = error as? SiloAPIError, problem.status == 401,
               account == saved, operation == capturedOperation {
                await signOut()
            } else if account == saved, operation == capturedOperation {
                let invalid: Bool
                switch error {
                case SiloSignInError.serverChanged, SiloSignInError.accountChanged,
                     SiloSignInError.profileMissing, SiloSignInError.passwordChangeRequired,
                     SiloSignInError.originMismatch, SiloSignInError.notSilo,
                     SiloSignInError.unsupportedAPI:
                    invalid = true
                case let problem as SiloAPIError:
                    invalid = [403, 404].contains(problem.status)
                default:
                    invalid = false
                }
                if invalid {
                    authorityRevision &+= 1
                    NotificationCenter.default.post(name: .siloAuthorityDidChange, object: nil)
                    onChanged?()
                }
            }
            throw error
        }
        // Branding is public display metadata, not evidence that saved
        // credentials or profile access became invalid.
        let serverName = try await configuredServerName(saved.serverURL, transport: transport)
        guard account == saved, operation == capturedOperation else { throw CancellationError() }
        if serverName != saved.serverName {
            let updated = Account(serverURL: saved.serverURL, serverID: saved.serverID, serverName: serverName,
                                  userID: saved.userID, userName: saved.userName, profileID: saved.profileID,
                                  profileName: saved.profileName, credentialID: saved.credentialID)
            UserDefaults.standard.set(try JSONEncoder().encode(updated), forKey: accountKey)
            onChanged?()
        }
    }

    /// Probe first, then open a login session. It is staged, not registered,
    /// until the user explicitly chooses a household profile.
    static func signIn(
        serverURL: URL, username: String, password: String,
        transport: @escaping SiloClient.Transport = { try await SiloHTTP.data(for: $0) }
    ) async throws -> [SiloProfile] {
        cancelPendingSignIn()
        let requestID = UUID()
        operation = requestID
        let serverURL = try validatedURL(serverURL)
        let serverID = try await probe(serverURL, transport: transport)
        let serverName = try await configuredServerName(serverURL, transport: transport)
        try check(requestID)
        let anonymous = SiloClient(baseURL: serverURL, transport: transport, deviceHeaders: deviceHeaders)
        let tokens: SiloTokenPair = try await anonymous.post(
            "auth/login", body: SiloLoginBody(username: username, password: password)
        )
        guard operation == requestID else {
            revoke(serverURL: serverURL, token: tokens.accessToken, transport: transport)
            throw CancellationError()
        }
        return try await stage(tokens: tokens, serverURL: serverURL, serverID: serverID,
                               serverName: serverName, requestID: requestID, transport: transport)
    }

    /// An anonymous device request is bound to this operation and server identity.
    static func startDeviceSignIn(
        serverURL input: URL,
        transport: @escaping SiloClient.Transport = { try await SiloHTTP.data(for: $0) }
    ) async throws -> SiloDeviceStart {
        cancelPendingSignIn()
        let requestID = operation
        let serverURL = try validatedURL(input)
        let serverID = try await probe(serverURL, transport: transport)
        try check(requestID)
        let client = SiloClient(baseURL: serverURL, transport: transport, deviceHeaders: deviceHeaders)
        let capability: SiloDeviceCapability
        do { capability = try await client.get("auth/device/capability") }
        catch let error as SiloAPIError where [403, 404].contains(error.status) { throw SiloDeviceSignInError.unsupported }
        guard capability.available else { throw SiloDeviceSignInError.unsupported }
        try check(requestID)
        let started: SiloDeviceStart
        do {
            started = try await client.post("auth/device/start", body: SiloDeviceStartBody(
                deviceName: PlexAPI.deviceName, devicePlatform: "tvos"))
        } catch let error as SiloAPIError where [403, 404].contains(error.status) {
            throw SiloDeviceSignInError.unsupported
        }
        guard operation == requestID else {
            withdrawDevice(url: serverURL, code: started.deviceCode, transport: transport)
            throw CancellationError()
        }
        guard !started.deviceCode.isEmpty, !started.userCode.isEmpty, started.expiresIn > 0,
              started.interval > 0, let verification = URL(string: started.verificationUri),
              let complete = URL(string: started.verificationUriComplete),
              ["https", "http"].contains(verification.scheme?.lowercased() ?? ""),
              SiloClient.origin(verification) == SiloClient.origin(serverURL),
              SiloClient.origin(complete) == SiloClient.origin(serverURL) else {
            withdrawDevice(url: serverURL, code: started.deviceCode, transport: transport)
            throw SiloDeviceSignInError.invalidCode
        }
        deviceAttempt = (serverURL, started.deviceCode, capability.cancel == true, transport)
        // Retain the probed identity for the eventual token response.
        deviceServerID = serverID
        return started
    }

    private static var deviceServerID: String?

    static func awaitDeviceSignIn(
        _ started: SiloDeviceStart,
        onPending: @escaping @MainActor (Bool) -> Void = { _ in }
    ) async throws -> [SiloProfile] {
        let requestID = operation
        guard let attempt = deviceAttempt, attempt.code == started.deviceCode,
              let serverID = deviceServerID else { throw CancellationError() }
        let deadline = Date().addingTimeInterval(TimeInterval(started.expiresIn))
        let client = SiloClient(baseURL: attempt.url, transport: attempt.transport, deviceHeaders: deviceHeaders)
        var interval = max(1, started.interval)
        while Date() < deadline {
            try check(requestID)
            let poll: SiloDevicePoll
            do { poll = try await client.post("auth/device/poll", body: SiloDeviceCodeBody(deviceCode: started.deviceCode)) }
            catch let error as SiloAPIError where error.status == 404 { throw SiloDeviceSignInError.expired }
            catch let error as SiloAPIError where [408, 429].contains(error.status) || error.status >= 500 {
                try await Task.sleep(for: .seconds(interval))
                continue
            }
            catch MediaProviderError.unreachable {
                try await Task.sleep(for: .seconds(interval))
                continue
            }
            try check(requestID)
            guard deviceAttempt?.code == started.deviceCode else { throw CancellationError() }
            guard Date() < deadline else { throw SiloDeviceSignInError.expired }
            switch poll.status {
            case "pending":
                guard poll.tokens == nil else { throw SiloSignInError.invalidResponse }
                onPending(true)
                interval = max(interval, poll.pollAfter, 1)
                try await Task.sleep(for: .seconds(interval))
            case "approved":
                guard let tokens = poll.tokens, poll.temporary != true else { throw SiloSignInError.invalidResponse }
                let serverName = try await configuredServerName(attempt.url, transport: attempt.transport)
                try check(requestID)
                guard deviceAttempt?.code == started.deviceCode else {
                    revoke(serverURL: attempt.url, token: tokens.accessToken, transport: attempt.transport)
                    throw CancellationError()
                }
                guard try await probe(attempt.url, transport: attempt.transport) == serverID else {
                    revoke(serverURL: attempt.url, token: tokens.accessToken, transport: attempt.transport)
                    throw SiloSignInError.serverChanged
                }
                guard operation == requestID, deviceAttempt?.code == started.deviceCode else {
                    revoke(serverURL: attempt.url, token: tokens.accessToken, transport: attempt.transport)
                    throw CancellationError()
                }
                deviceAttempt = nil
                deviceServerID = nil
                return try await stage(tokens: tokens, serverURL: attempt.url, serverID: serverID,
                                       serverName: serverName, requestID: requestID, transport: attempt.transport)
            case "denied": throw SiloDeviceSignInError.denied
            case "expired", "canceled": throw SiloDeviceSignInError.expired
            case "consumed": throw SiloDeviceSignInError.consumed
            default: throw SiloSignInError.invalidResponse
            }
        }
        throw SiloDeviceSignInError.expired
    }

    private static func stage(tokens: SiloTokenPair, serverURL: URL, serverID: String,
                              serverName: String, requestID: UUID,
                              transport: @escaping SiloClient.Transport) async throws -> [SiloProfile] {
        guard !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty, !tokens.user.id.isEmpty,
              tokens.expiresIn > 0 else {
            revoke(serverURL: serverURL, token: tokens.accessToken, transport: transport)
            throw SiloSignInError.invalidResponse
        }
        guard !tokens.user.passwordChangeRequired else {
            revoke(serverURL: serverURL, token: tokens.accessToken, transport: transport)
            throw SiloSignInError.passwordChangeRequired
        }
        let id = UUID()
        let credentials = SiloLoginCredentials(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                              expiresAt: Date().addingTimeInterval(Double(tokens.expiresIn)),
                                              serverID: serverID, userID: tokens.user.id)
        let authority = makeAuthority(id: id, baseURL: serverURL, credentials: credentials,
                                      transport: transport, initiallyVerified: true)
        pending = Pending(id: id, serverURL: serverURL, serverID: serverID,
                          serverName: serverName, user: tokens.user,
                          authority: authority, transport: transport)
        do {
            let result: SiloProfileCollection = try await client(baseURL: serverURL, authority: authority, transport: transport).get("profiles")
            try check(requestID)
            return result.items
        } catch {
            if pending?.id == id { cancelPendingSignIn() }
            throw error
        }
    }

    /// Profile listing deliberately uses account-only authority: an expired PIN
    /// proof must not lock the user out of the chooser.
    static func profiles() async throws -> [SiloProfile] {
        let captured = operation
        if let pending {
            let result: SiloProfileCollection = try await client(baseURL: pending.serverURL,
                authority: pending.authority, transport: pending.transport).get("profiles")
            try check(captured)
            return result.items
        }
        guard let account, let authority = authority(for: account) else { throw SiloSignInError.signedOut }
        let result: SiloProfileCollection = try await client(baseURL: account.serverURL, authority: authority).get("profiles")
        try check(captured)
        return result.items
    }

    static func selectProfile(_ profile: SiloProfile, pin: String? = nil) async throws {
        let requestID = UUID()
        operation = requestID
        let staged = pending
        let current = account
        let id: UUID
        let baseURL: URL
        let serverID: String
        let serverName: String
        let userID: String
        let userName: String
        let authority: SiloTokenAuthority
        let transport: SiloClient.Transport
        if let staged {
            id = staged.id; baseURL = staged.serverURL; serverID = staged.serverID
            serverName = staged.serverName; userID = staged.user.id; userName = staged.user.username
            authority = staged.authority; transport = staged.transport
        } else if let current, let restored = self.authority(for: current) {
            id = current.credentialID; baseURL = current.serverURL; serverID = current.serverID
            serverName = current.serverName; userID = current.userID; userName = current.userName
            authority = restored; transport = { try await SiloHTTP.data(for: $0) }
        } else { throw SiloSignInError.signedOut }
        let unscoped = client(baseURL: baseURL, authority: authority, transport: transport)
        let available: SiloProfileCollection = try await unscoped.get("profiles")
        try check(requestID)
        guard let selected = available.items.first(where: { $0.id == profile.id }) else { throw SiloSignInError.profileMissing }
        var proof: String?
        if selected.hasPIN {
            guard let pin, !pin.isEmpty else { throw SiloSignInError.pinRequired }
            let verification: SiloProfileVerification = try await unscoped.post(
                "profiles/\(SiloClient.pathComponent(selected.id))/verify-pin", body: SiloPINBody(pin: pin)
            )
            try check(requestID)
            guard verification.valid, let token = verification.profileToken, !token.isEmpty else {
                throw SiloSignInError.incorrectPIN
            }
            proof = token
        }
        let scoped = client(baseURL: baseURL, authority: authority, profileID: selected.id,
                            profileToken: proof, transport: transport)
        // Check native capability authorization, not a version or an unrelated
        // compatibility endpoint. A disabled home is still a valid login.
        let _: SiloCapability = try await scoped.get("home/capabilities")
        let credentials = try await authority.credentials()
        try check(requestID)
        guard credentials.userID == userID, credentials.serverID == serverID else { throw SiloSignInError.accountChanged }
        let newAccount = Account(serverURL: baseURL, serverID: serverID, serverName: serverName,
                                 userID: userID, userName: userName, profileID: selected.id,
                                 profileName: selected.name, credentialID: id)
        let encodedAccount = try JSONEncoder().encode(newAccount)
        do {
            try SiloSecrets.save(credentials, id: id)
            if let proof { try SiloSecrets.set(proof, key: "profile.\(id).\(selected.id)") }
            else { SiloSecrets.delete("profile.\(id).\(selected.id)") }
        } catch {
            if current?.credentialID != id {
                SiloSecrets.delete("login.\(id)")
                SiloSecrets.delete("profile.\(id).\(selected.id)")
            }
            throw error
        }
        UserDefaults.standard.set(encodedAccount, forKey: accountKey)
        activeAuthority = authority
        activeCredentialID = id
        pending = nil
        authorityRevision &+= 1
        NotificationCenter.default.post(name: .siloAuthorityDidChange, object: nil)
        if let current, current.credentialID != id {
            if let old = forgetSecrets(current) {
                revoke(serverURL: current.serverURL, token: old, transport: transport)
            }
        } else if let current, current.profileID != selected.id {
            SiloSecrets.delete("profile.\(id).\(current.profileID)")
        }
        onChanged?()
    }

    /// Invalidates only staged operations. The existing committed account is
    /// unaffected when the user cancels a new sign-in or leaves settings.
    static func cancelPendingSignIn() {
        operation = UUID()
        if let attempt = deviceAttempt {
            deviceAttempt = nil
            deviceServerID = nil
            if attempt.canCancel { withdrawDevice(url: attempt.url, code: attempt.code, transport: attempt.transport) }
        }
        guard let old = pending else { return }
        pending = nil
        Task {
            if let token = await old.authority.cachedAccessToken() {
                revoke(serverURL: old.serverURL, token: token, transport: old.transport)
            }
        }
    }

    private static func withdrawDevice(url: URL, code: String, transport: @escaping SiloClient.Transport) {
        Task {
            try? await SiloClient(baseURL: url, transport: transport).post(
                "auth/device/cancel", body: SiloDeviceCodeBody(deviceCode: code))
        }
    }

    static func cancelProfileSelection() {
        operation = UUID()
    }

    static func signOut() async {
        let saved = account
        let authority = activeAuthority
        cancelPendingSignIn()
        let savedToken = saved.flatMap { SiloSecrets.load(id: $0.credentialID)?.accessToken }
        UserDefaults.standard.removeObject(forKey: accountKey)
        activeAuthority = nil
        activeCredentialID = nil
        authorityRevision &+= 1
        NotificationCenter.default.post(name: .siloAuthorityDidChange, object: nil)
        if let saved { _ = forgetSecrets(saved) }
        onChanged?()
        let cachedToken = await authority?.cachedAccessToken()
        if let saved, let token = savedToken ?? cachedToken {
            revoke(serverURL: saved.serverURL, token: token, transport: SiloHTTP.data(for:))
        }
    }

    nonisolated static func normalizedServerURL(_ url: URL) -> URL { SiloClient.normalizedServerURL(url) }

    private static func check(_ requestID: UUID) throws {
        try Task.checkCancellation()
        guard operation == requestID else { throw CancellationError() }
    }

    private static var deviceHeaders: [String: String] {
        ["X-Silo-Device-Id": PlexAPI.clientIdentifier,
         "X-Silo-Device-Name": PlexAPI.deviceName,
         "X-Silo-Device-Platform": "tvos"]
    }

    private static func authority(
        for account: Account,
        transport: @escaping SiloClient.Transport = { try await SiloHTTP.data(for: $0) }
    ) -> SiloTokenAuthority? {
        if activeCredentialID == account.credentialID, let activeAuthority { return activeAuthority }
        guard let credentials = SiloSecrets.load(id: account.credentialID),
              credentials.userID == account.userID, credentials.serverID == account.serverID else { return nil }
        let authority = makeAuthority(id: account.credentialID, baseURL: account.serverURL,
                                      credentials: credentials, transport: transport)
        activeAuthority = authority
        activeCredentialID = account.credentialID
        return authority
    }

    private static func makeAuthority(id: UUID, baseURL: URL, credentials: SiloLoginCredentials,
                                      transport: @escaping SiloClient.Transport,
                                      initiallyVerified: Bool = false) -> SiloTokenAuthority {
        SiloTokenAuthority(baseURL: baseURL, credentials: credentials, transport: transport,
            initiallyVerified: initiallyVerified,
            validate: {
                await MainActor.run {
                    account?.credentialID == id || pending?.id == id
                }
            }, persist: { credentials in
                try await MainActor.run {
                    if let current = account, current.credentialID == id {
                        guard current.userID == credentials.userID, current.serverID == credentials.serverID else {
                            throw SiloSignInError.accountChanged
                        }
                        try SiloSecrets.save(credentials, id: id)
                    } else if pending?.id != id { throw CancellationError() }
                }
            })
    }

    private static func client(baseURL: URL, authority: SiloTokenAuthority,
                               profileID: String? = nil, profileToken: String? = nil,
                               transport: @escaping SiloClient.Transport = { try await SiloHTTP.data(for: $0) }) -> SiloClient {
        SiloClient(baseURL: baseURL, profileID: profileID, profileToken: profileToken, transport: transport,
                   tokenSource: { try await authority.accessToken(forceRefresh: $0) }, deviceHeaders: deviceHeaders)
    }

    private static func forgetSecrets(_ account: Account) -> String? {
        let token = SiloSecrets.load(id: account.credentialID)?.accessToken
        SiloSecrets.delete("login.\(account.credentialID)")
        SiloSecrets.delete("profile.\(account.credentialID).\(account.profileID)")
        return token
    }

    private static func revoke(serverURL: URL, token: String, transport: @escaping SiloClient.Transport) {
        Task {
            let client = SiloClient(baseURL: serverURL, token: token, transport: transport)
            try? await client.post("auth/logout")
        }
    }

    nonisolated private static func validatedURL(_ url: URL) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw SiloSignInError.invalidAddress
        }
        return normalizedServerURL(url)
    }

    nonisolated private static func configuredServerName(
        _ baseURL: URL, transport: @escaping SiloClient.Transport
    ) async throws -> String {
        // The native identity document has no name. Branding is public and
        // account/profile-independent; never send credentials with this read.
        let branding: SiloBranding = try await SiloClient(baseURL: baseURL, transport: transport).get("theme/branding")
        let name = branding.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SiloSignInError.invalidResponse }
        return name
    }

    nonisolated static func probe(_ baseURL: URL, transport: @escaping SiloClient.Transport) async throws -> String {
        let client = SiloClient(baseURL: try validatedURL(baseURL), transport: transport)
        let info: SiloSystemInfo
        do { info = try await client.get("system/info") }
        catch SiloSignInError.invalidResponse { throw SiloSignInError.notSilo }
        guard info.apiMajor == 2 else { throw SiloSignInError.unsupportedAPI(info.apiMajor) }
        guard info.links.identity.hasSuffix("/api/v2/system/identity"),
              info.links.capabilities.hasSuffix("/api/v2/capabilities") else { throw SiloSignInError.notSilo }
        if let origin = info.requestOrigin, origin != SiloClient.origin(baseURL) { throw SiloSignInError.originMismatch }
        let identity: SiloServerIdentity = try await client.get("system/identity")
        guard !identity.serverId.isEmpty else { throw SiloSignInError.notSilo }
        return identity.serverId
    }
}

nonisolated struct SiloLoginCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let serverID: String
    let userID: String
}

/// Single-flight refresh is per captured login, never a lookup of whichever
/// account/profile is currently selected. The refresh result is checked against
/// account/me before replacing either the in-memory or persisted token pair.
actor SiloTokenAuthority {
    private let baseURL: URL
    private var stored: SiloLoginCredentials
    private let transport: SiloClient.Transport
    private let validate: @Sendable () async -> Bool
    private let persist: @Sendable (SiloLoginCredentials) async throws -> Void
    private var refresh: (id: UUID, task: Task<SiloLoginCredentials, Error>)?
    private var verified: Bool

    init(baseURL: URL, credentials: SiloLoginCredentials, transport: @escaping SiloClient.Transport,
         initiallyVerified: Bool, validate: @escaping @Sendable () async -> Bool,
         persist: @escaping @Sendable (SiloLoginCredentials) async throws -> Void) {
        self.baseURL = baseURL; stored = credentials; self.transport = transport
        self.validate = validate; self.persist = persist; verified = initiallyVerified
    }

    func cachedAccessToken() -> String? { stored.accessToken }

    func credentials() async throws -> SiloLoginCredentials {
        _ = try await accessToken(forceRefresh: false)
        return stored
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard await validate() else { throw CancellationError() }
        if let refresh { return try await finish(refresh.task, id: refresh.id) }
        if !forceRefresh, verified, stored.expiresAt.timeIntervalSinceNow > 60 { return stored.accessToken }
        let old = stored
        let baseURL = self.baseURL
        let transport = self.transport
        let persist = self.persist
        let validate = self.validate
        let refreshID = UUID()
        let task = Task<SiloLoginCredentials, Error> {
            let identity = try await SiloSession.probe(baseURL, transport: transport)
            guard identity == old.serverID else { throw SiloSignInError.serverChanged }
            guard await validate() else { throw CancellationError() }
            let anonymous = SiloClient(baseURL: baseURL, transport: transport)
            let result: SiloRefreshedTokens = try await anonymous.post(
                "auth/refresh", body: SiloRefreshBody(refreshToken: old.refreshToken)
            )
            guard !result.accessToken.isEmpty, !result.refreshToken.isEmpty, result.expiresIn > 0 else {
                throw SiloSignInError.invalidResponse
            }
            let next = SiloLoginCredentials(accessToken: result.accessToken, refreshToken: result.refreshToken,
                                           expiresAt: Date().addingTimeInterval(Double(result.expiresIn)),
                                           serverID: old.serverID, userID: old.userID)
            let accountClient = SiloClient(baseURL: baseURL, token: next.accessToken, transport: transport)
            let user: SiloLoginAccount = try await accountClient.get("account/me")
            guard user.id == old.userID else { throw SiloSignInError.accountChanged }
            guard await validate() else { throw CancellationError() }
            try await persist(next)
            return next
        }
        refresh = (refreshID, task)
        return try await finish(task, id: refreshID)
    }

    private func finish(_ task: Task<SiloLoginCredentials, Error>, id: UUID) async throws -> String {
        do {
            let result = try await task.value
            guard await validate() else { throw CancellationError() }
            if refresh?.id == id {
                stored = result
                verified = true
                refresh = nil
            }
            return result.accessToken
        } catch {
            if refresh?.id == id { refresh = nil }
            throw error
        }
    }
}

/// One atomic keychain item per login token pair. SecItemUpdate preserves the
/// previous pair if saving a refreshed pair fails; no credentials enter defaults.
@MainActor
private enum SiloSecrets {
    private static let service = "com.rivulet.silo"

    static func get(_ key: String) -> String? {
        var query = attributes(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, key: String) throws {
        let data = Data(value.utf8)
        let query = attributes(key)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw SiloSignInError.keychain }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SiloSignInError.keychain }
    }

    static func save(_ credentials: SiloLoginCredentials, id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        try set(String(decoding: data, as: UTF8.self), key: "login.\(id)")
    }

    static func load(id: UUID) -> SiloLoginCredentials? {
        guard let value = get("login.\(id)") else { return nil }
        return try? JSONDecoder().decode(SiloLoginCredentials.self, from: Data(value.utf8))
    }

    static func delete(_ key: String) { SecItemDelete(attributes(key) as CFDictionary) }

    private static func attributes(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}
