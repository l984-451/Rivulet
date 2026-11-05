// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbySession.swift
//  Rivulet
//
//  The signed-in Emby server, beside (not instead of) the Jellyfin one.
//  Sign-in, sign-out and the stored account are Emby's own; browsing and
//  playback reuse JellyfinProvider and JellyfinClient as they are, with
//  `EmbyRequests` as the client's transport. The account shape is Jellyfin's,
//  so the provider id is `jellyfin:<serverID>` and every view that routes a
//  Jellyfin item routes an Emby item the same way.
//
//  Emby has no Quick Connect here: username and password only. The password
//  is used for the one exchange; only the token is kept (Keychain).
//

import Foundation

enum EmbySignInError: Error, Equatable {
    case notEmby
    /// The address is a Jellyfin server: the Jellyfin page signs in to it.
    case isJellyfin
    case serverTooOld(version: String)
}

@MainActor
enum EmbySession {
    typealias Account = JellyfinSession.Account

    static let accountKey = "embyAccount"

    /// Set at launch (`RivuletApp.init`), like `JellyfinSession.onChanged`.
    static var onChanged: (() -> Void)?

    /// 4.8 is the oldest release still offered for download. Untested below
    /// the 4.11 beta this was written against.
    nonisolated static let minimumVersion = (major: 4, minor: 8)

    static var account: Account? {
        guard let data = UserDefaults.standard.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    /// A Jellyfin client that speaks Emby for this account.
    static func client(
        for account: Account, token: String,
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) -> JellyfinClient {
        JellyfinClient(baseURL: account.serverURL, token: token, transport: EmbyRequests.transport(
            baseURL: account.serverURL, userID: account.userID, token: token, sending: transport))
    }

    /// The provider for the stored account, or nil when signed out or the
    /// Keychain lost the token.
    static func storedProvider() -> JellyfinProvider? {
        guard let account,
              let token = CredentialRegistry.shared.token(for: .server(providerID: account.providerID))
        else { return nil }
        return JellyfinProvider(serverID: account.serverID, displayName: account.serverName,
                                userID: account.userID, client: client(for: account, token: token))
    }

    /// Probe, check it is Emby and new enough, trade the password for a token,
    /// persist, and register the provider.
    static func signIn(
        serverURL: URL,
        username: String,
        password: String,
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> Account {
        let serverURL = JellyfinSession.normalizedServerURL(serverURL)
        let anonymous = JellyfinClient(baseURL: serverURL, token: nil, transport: EmbyRequests.transport(
            baseURL: serverURL, userID: nil, token: nil, sending: transport))
        let info = try await checkedServer(anonymous)
        let auth: JFAuthenticationResult = try await anonymous.post(
            "Users/AuthenticateByName", body: JFAuthenticateByName(username: username, pw: password)
        )
        guard let token = auth.accessToken, let userID = auth.user?.id, let serverID = info.id else {
            throw MediaProviderError.unauthorized
        }
        let account = Account(
            serverURL: serverURL,
            serverID: serverID,
            serverName: info.serverName ?? "Emby",
            userID: userID,
            userName: auth.user?.name ?? username
        )
        try await CredentialRegistry.shared.setToken(token, for: .server(providerID: account.providerID))
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: accountKey)
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        MusicProviderRegistry.shared.populateFromCurrentAuth()
        onChanged?()
        return account
    }

    private static func checkedServer(_ anonymous: JellyfinClient) async throws -> JFPublicSystemInfo {
        let info: JFPublicSystemInfo
        do {
            info = try await anonymous.get("System/Info/Public")
        } catch MediaProviderError.unreachable {
            throw MediaProviderError.unreachable
        } catch JellyfinSignInError.untrustedCertificate {
            throw JellyfinSignInError.untrustedCertificate
        } catch {
            throw EmbySignInError.notEmby
        }
        if info.productName == "Jellyfin Server" { throw EmbySignInError.isJellyfin }
        guard isEmby(productName: info.productName, version: info.version),
              let serverID = info.id, !serverID.isEmpty else {
            throw EmbySignInError.notEmby
        }
        guard isSupported(version: info.version) else {
            throw EmbySignInError.serverTooOld(version: info.version ?? "unknown")
        }
        return info
    }

    /// Emby names itself, or leaves ProductName out; its versions are 4.x where
    /// Jellyfin's are 10 and up.
    nonisolated static func isEmby(productName: String?, version: String?) -> Bool {
        if let productName { return productName.localizedCaseInsensitiveContains("emby") }
        guard let major = versionParts(version).first else { return false }
        return (3...9).contains(major)
    }

    /// "4.11.0.13" -> true. Unparseable -> false.
    nonisolated static func isSupported(version: String?) -> Bool {
        let parts = versionParts(version)
        guard parts.count >= 2 else { return false }
        return (parts[0], parts[1]) >= (minimumVersion.major, minimumVersion.minor)
    }

    nonisolated private static func versionParts(_ version: String?) -> [Int] {
        (version ?? "").split(separator: ".").compactMap { Int($0) }
    }

    /// Forgets everything locally, then revokes the token without waiting, as
    /// `JellyfinSession.signOut` does.
    static func signOut(
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async {
        guard let account else { return }
        let scope = CredentialScope.server(providerID: account.providerID)
        let token = CredentialRegistry.shared.token(for: scope)
        await CredentialRegistry.shared.clearToken(for: scope)
        UserDefaults.standard.removeObject(forKey: accountKey)
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        MusicProviderRegistry.shared.populateFromCurrentAuth()
        onChanged?()

        guard let token else { return }
        let logout = client(for: account, token: token, transport: transport)
        Task { try? await logout.post("Sessions/Logout") }
    }
}
