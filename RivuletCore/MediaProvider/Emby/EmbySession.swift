// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbySession.swift
//  Rivulet
//
//  The signed-in Emby server: sign in, sign out, and the stored account the
//  provider registry rebuilds from at launch. One server at a time, as for
//  Jellyfin. The token lives in the Keychain under CredentialScope.server;
//  everything else in UserDefaults. No Quick Connect, no Emby Connect.
//

import Foundation

@MainActor
enum EmbySession {
    struct Account: Codable, Equatable {
        let serverURL: URL
        let serverID: String
        let serverName: String
        let userID: String
        let userName: String
        let policy: Policy

        var providerID: String { "emby:\(serverID)" }
    }

    /// What the user's `Policy` allowed at sign-in, for the admin and deletion gates.
    struct Policy: Codable, Equatable {
        var isAdministrator = false
        var enableContentDeletion = false
        var enableContentDeletionFromFolders: [String] = []
        var enableLiveTvAccess = false
        /// Nil when the server did not say, which counts as allowed.
        var enableContentDownloading: Bool?
        /// Nil when the server did not say, which counts as allowed.
        var enableSubtitleDownloading: Bool?

        init() {}

        init(_ dto: EmbyUser.Policy?) {
            isAdministrator = dto?.isAdministrator ?? false
            enableContentDeletion = dto?.enableContentDeletion ?? false
            enableContentDeletionFromFolders = (dto?.enableContentDeletionFromFolders ?? []).map(\.value)
            enableLiveTvAccess = dto?.enableLiveTvAccess ?? false
            enableContentDownloading = dto?.enableContentDownloading
            enableSubtitleDownloading = dto?.enableSubtitleDownloading
        }
    }

    static let accountKey = "embyAccount"

    /// Set at launch (`RivuletApp.init`) to reload the Emby browse state. Runs after
    /// sign-in and sign-out, once the registry holds the new provider (or no longer does).
    static var onChanged: (() -> Void)?

    /// Four-part Emby version. 4.8.11.0 is the oldest measured; older 4.8.x answers a failed
    /// login with 403, which would read as a lockout. No ceiling.
    nonisolated static let minimumVersion = (major: 4, minor: 8, patch: 11, build: 0)

    static var account: Account? {
        guard let data = UserDefaults.standard.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    /// The provider for the stored account, or nil when signed out or the
    /// Keychain lost the token.
    static func storedProvider() -> EmbyProvider? {
        guard let account,
              let token = CredentialRegistry.shared.token(for: .server(providerID: account.providerID))
        else { return nil }
        return EmbyProvider(
            serverID: account.serverID,
            displayName: account.serverName,
            userID: account.userID,
            policy: account.policy,
            client: EmbyClient(baseURL: account.serverURL, token: token)
        )
    }

    /// Probe, check the version, trade the password for a token, persist, and
    /// register the provider. The password is never stored.
    static func signIn(
        serverURL: URL,
        username: String,
        password: String,
        transport: @escaping EmbyClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> Account {
        let serverURL = normalizedServerURL(serverURL)
        let anonymous = EmbyClient(baseURL: serverURL, token: nil, transport: transport)
        let info = try await checkedServer(anonymous)
        let auth = try await anonymous.authenticate(username: username, password: password)
        guard let token = auth.accessToken, let userID = auth.user?.id?.value, let serverID = info.id else {
            throw MediaProviderError.unauthorized
        }
        // The probe and the sign-in must have reached the same server.
        guard auth.serverId == serverID else { throw EmbySignInError.notEmby }

        let policy = await fetchPolicy(
            EmbyClient(baseURL: serverURL, token: token, transport: transport), userID: userID
        )
        let account = Account(
            serverURL: serverURL,
            serverID: serverID,
            serverName: info.serverName ?? "Emby",
            userID: userID,
            userName: auth.user?.name ?? username,
            policy: policy
        )
        try await persist(account, token: token)
        return account
    }

    private static func persist(_ account: Account, token: String) async throws {
        try await CredentialRegistry.shared.setToken(token, for: .server(providerID: account.providerID))
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: accountKey)
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        MusicProviderRegistry.shared.populateFromCurrentAuth()
        onChanged?()
        CloudSync.shared.accountsChanged()
    }

    /// Signs in with a token another device holds, after one authenticated call proves the server takes it.
    /// Refused when this device already has a server or the server rejects the token.
    static func adopt(
        account: Account, token: String,
        transport: @escaping EmbyClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> AdoptOutcome {
        guard self.account == nil else { return .refused }
        let client = EmbyClient(baseURL: account.serverURL, token: token, transport: transport)
        do {
            let _: EmbyUser = try await client.get("Users/\(account.userID)")
        } catch MediaProviderError.unauthorized {
            return .refused
        } catch {
            return .unavailable
        }
        return (try? await persist(account, token: token)) != nil ? .adopted : .unavailable
    }

    /// The address answers as an Emby server new enough for Rivulet. Runs before any
    /// credential is sent: a Jellyfin-style AuthenticateByName succeeds against Emby,
    /// so a wrong-server sign-in would hand the password to the wrong backend.
    private static func checkedServer(_ anonymous: EmbyClient) async throws -> EmbyPublicSystemInfo {
        let info: EmbyPublicSystemInfo
        do {
            info = try await anonymous.get("System/Info/Public")
        } catch MediaProviderError.unreachable {
            throw MediaProviderError.unreachable
        } catch EmbySignInError.untrustedCertificate {
            throw EmbySignInError.untrustedCertificate
        } catch {
            // Reachable but not Emby's API: a wrong port, a web page, Jellyfin.
            throw EmbySignInError.notEmby
        }
        guard info.productName != "Jellyfin Server", let version = info.version, isEmbyVersion(version),
              let serverID = info.id, !serverID.isEmpty
        else { throw EmbySignInError.notEmby }
        guard isSupported(version: version) else { throw EmbySignInError.serverTooOld(version: version) }
        return info
    }

    /// A non-fatal read: the token is already good, and the policy only gates admin and delete UI.
    private static func fetchPolicy(_ client: EmbyClient, userID: String) async -> Policy {
        guard let user: EmbyUser = try? await client.get("Users/\(userID)") else { return Policy() }
        return Policy(user.policy)
    }

    /// Forgets everything locally, then revokes the token without waiting: an unreachable
    /// server must not hold the row for the 60s request timeout. With iCloud Sync the token
    /// is shared, so only `.everywhere` revokes it; a caller that does not ask gets this device only.
    static func signOut(
        scope signOutScope: SignOutScope? = nil,
        transport: @escaping EmbyClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async {
        guard let account else { return }
        let signOutScope = signOutScope ?? .thisDevice
        let shared = CloudSync.shared.wasShared(accountID: account.providerID)
        let scope = CredentialScope.server(providerID: account.providerID)
        let token = CredentialRegistry.shared.token(for: scope)
        await CredentialRegistry.shared.clearToken(for: scope)
        UserDefaults.standard.removeObject(forKey: accountKey)
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        MusicProviderRegistry.shared.populateFromCurrentAuth()
        onChanged?()
        if signOutScope != .syncedRemoval {
            CloudSync.shared.signedOut(accountID: account.providerID, identity: nil, scope: signOutScope)
        }

        guard let token, signOutScope.revokesToken(everShared: shared) else { return }
        let client = EmbyClient(baseURL: account.serverURL, token: token, transport: transport)
        Task { try? await client.post("Sessions/Logout") }
    }

    /// Accepts what a user copies out of a browser:
    /// "http://nas:8096/web/index.html#!/home" -> "http://nas:8096". A reverse-proxy
    /// subpath keeps its place, and so does a typed "/emby": the server takes both.
    nonisolated static func normalizedServerURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil
        var parts = components.path.split(separator: "/")
        if let web = parts.lastIndex(of: "web") { parts.removeSubrange(web...) }
        components.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        return components.url ?? url
    }

    /// Four dot-separated integers with major 4: what `System/Info/Public` reports on Emby.
    /// Jellyfin writes three parts, and a version Emby never wrote is not Emby.
    nonisolated static func isEmbyVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && Int($0) != nil }
            && parts[0] == "4"
    }

    /// "4.10.2.0" -> true. Compared as four integers, missing ones as 0. A non-numeric
    /// component is unsupported: refuse rather than guess.
    nonisolated static func isSupported(version: String?) -> Bool {
        let strings = (version ?? "").split(separator: ".", omittingEmptySubsequences: false)
        let numbers = strings.compactMap { Int($0) }
        guard !strings.isEmpty, numbers.count == strings.count else { return false }
        let p = Array((numbers + [0, 0, 0, 0]).prefix(4))
        let floor = minimumVersion
        return (p[0], p[1], p[2], p[3]) >= (floor.major, floor.minor, floor.patch, floor.build)
    }

    /// The server's own text for a lockout, a disabled account or a blocked device: only English says which.
    static func failureMessage(for error: Error) -> String {
        let name = MediaProviderKind.emby.displayName
        let floor = minimumVersion
        switch error {
        case EmbySignInError.notEmby:
            return String(localized: "That address isn't an \(name) server. Check the port. A Jellyfin server signs in under Jellyfin Server.")
        case EmbySignInError.serverTooOld:
            return String(localized: "Rivulet needs \(name) Server \(floor.major).\(floor.minor).\(floor.patch) or newer.")
        case EmbySignInError.untrustedCertificate:
            return String(localized: "This server's HTTPS certificate isn't trusted. Try its http:// address.")
        case EmbySignInError.invalidCredentials, MediaProviderError.unauthorized:
            return String(localized: "\(name) didn't accept that username and password.")
        case EmbySignInError.lockedOut(let message), EmbySignInError.accountDisabled(let message),
             EmbySignInError.notAllowed(let message):
            return message
        default:
            return String(localized: "Couldn't reach that server. Check the address and port.")
        }
    }
}
