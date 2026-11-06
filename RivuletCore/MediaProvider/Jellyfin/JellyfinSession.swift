// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinSession.swift
//  Rivulet
//
//  The signed-in Jellyfin server: sign in, sign out, and the stored account
//  the provider registry rebuilds from at launch. One server at a time, the
//  same model Plex uses. The token lives in the Keychain under
//  CredentialScope.server; everything else in UserDefaults.
//

import Foundation

/// Connection failures `MediaProviderError` has no name for. The client throws
/// `untrustedCertificate` on any request; the other two come from sign-in.
enum JellyfinSignInError: Error, Equatable {
    case notJellyfin
    case serverTooOld(version: String)
    case untrustedCertificate
}

@MainActor
enum JellyfinSession {
    struct Account: Codable, Equatable {
        let serverURL: URL
        let serverID: String
        let serverName: String
        let userID: String
        let userName: String

        var providerID: String { "jellyfin:\(serverID)" }
    }

    static let accountKey = "jellyfinAccount"

    /// Set at launch (`RivuletApp.init`) to reload the Jellyfin browse state.
    /// Runs after sign-in and sign-out, once the registry holds the new
    /// provider (or no longer does). A closure so the session stays free of
    /// view-layer stores, like `PlexAuthManager.onAuthenticated`.
    static var onChanged: (() -> Void)?

    /// Every route JellyfinProvider calls exists unchanged in 10.10.7, 10.11.11
    /// and 12.1.0 (checked against each release's OpenAPI spec), and all three
    /// accept the MediaBrowser header and `ApiKey=`. Older servers lack
    /// /UserViews and /UserItems/Resume.
    nonisolated static let minimumVersion = (major: 10, minor: 10)

    static var account: Account? {
        guard let data = UserDefaults.standard.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    /// The provider for the stored account, or nil when signed out or the
    /// Keychain lost the token.
    static func storedProvider() -> JellyfinProvider? {
        guard let account,
              let token = CredentialRegistry.shared.token(for: .server(providerID: account.providerID))
        else { return nil }
        return JellyfinProvider(
            serverID: account.serverID,
            displayName: account.serverName,
            userID: account.userID,
            client: JellyfinClient(baseURL: account.serverURL, token: token)
        )
    }

    /// Probe, check the version, trade the password for a token, persist, and
    /// register the provider. The password is never stored.
    static func signIn(
        serverURL: URL,
        username: String,
        password: String,
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> Account {
        let serverURL = normalizedServerURL(serverURL)
        let anonymous = JellyfinClient(baseURL: serverURL, token: nil, transport: transport)
        let info = try await checkedServer(anonymous)
        let auth: JFAuthenticationResult = try await anonymous.post(
            "Users/AuthenticateByName", body: JFAuthenticateByName(username: username, pw: password)
        )
        return try await save(auth, info: info, serverURL: serverURL, username: username)
    }

    /// Sign-in by Quick Connect (#481): hands `showCode` the code to approve on a
    /// signed-in device, then polls until it is approved or the task is cancelled.
    /// A server with Quick Connect off answers `unauthorized`; an expired code `notFound`.
    static func signInWithQuickConnect(
        serverURL: URL,
        pollInterval: Duration = .seconds(3),
        showCode: (String) -> Void,
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> Account {
        let serverURL = normalizedServerURL(serverURL)
        let anonymous = JellyfinClient(baseURL: serverURL, token: nil, transport: transport)
        let info = try await checkedServer(anonymous)
        let started: JFQuickConnect = try await anonymous.post("QuickConnect/Initiate")
        guard let code = started.code, let secret = started.secret else { throw MediaProviderError.notFound }
        showCode(code)
        while true {
            try await Task.sleep(for: pollInterval)
            let status: JFQuickConnect = try await anonymous.get(
                "QuickConnect/Connect", [URLQueryItem(name: "secret", value: secret)]
            )
            if status.authenticated == true { break }
        }
        let auth: JFAuthenticationResult = try await anonymous.post(
            "Users/AuthenticateWithQuickConnect", body: JFQuickConnectAuthenticate(secret: secret)
        )
        return try await save(auth, info: info, serverURL: serverURL, username: "")
    }

    /// The address answers as a Jellyfin server new enough for Rivulet.
    private static func checkedServer(_ anonymous: JellyfinClient) async throws -> JFPublicSystemInfo {
        let info: JFPublicSystemInfo
        do {
            info = try await anonymous.get("System/Info/Public")
        } catch MediaProviderError.unreachable {
            throw MediaProviderError.unreachable
        } catch JellyfinSignInError.untrustedCertificate {
            throw JellyfinSignInError.untrustedCertificate
        } catch {
            // Reachable but not Jellyfin's API: a wrong port, a web page, Emby.
            throw JellyfinSignInError.notJellyfin
        }
        guard info.productName == "Jellyfin Server", let serverID = info.id, !serverID.isEmpty else {
            throw JellyfinSignInError.notJellyfin
        }
        guard isSupported(version: info.version) else {
            throw JellyfinSignInError.serverTooOld(version: info.version ?? "unknown")
        }
        return info
    }

    private static func save(
        _ auth: JFAuthenticationResult, info: JFPublicSystemInfo, serverURL: URL, username: String
    ) async throws -> Account {
        guard let token = auth.accessToken, let userID = auth.user?.id, let serverID = info.id else {
            throw MediaProviderError.unauthorized
        }

        let account = Account(
            serverURL: serverURL,
            serverID: serverID,
            serverName: info.serverName ?? "Jellyfin",
            userID: userID,
            userName: auth.user?.name ?? username
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
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> AdoptOutcome {
        guard self.account == nil else { return .refused }
        let client = JellyfinClient(baseURL: account.serverURL, token: token, transport: transport)
        do {
            let _: JFUser = try await client.get("Users/Me")
        } catch MediaProviderError.unauthorized {
            return .refused
        } catch {
            return .unavailable
        }
        return (try? await persist(account, token: token)) != nil ? .adopted : .unavailable
    }

    /// Forgets everything locally, then revokes the token server-side without
    /// waiting. An unreachable server (the likeliest reason to sign out) must
    /// not hold the row for the 60s request timeout, and a second press finds
    /// nothing left to sign out. With iCloud Sync the token is shared, so only
    /// `.everywhere` revokes it; a caller that does not ask gets this device only.
    static func signOut(
        scope signOutScope: SignOutScope? = nil,
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
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
        let client = JellyfinClient(baseURL: account.serverURL, token: token, transport: transport)
        Task { try? await client.post("Sessions/Logout") }
    }

    /// Accepts what a user copies out of a browser:
    /// "http://nas:8096/web/#/home.html" -> "http://nas:8096". A reverse-proxy
    /// subpath ("https://host/jellyfin/web/") keeps its "/jellyfin".
    nonisolated static func normalizedServerURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil
        var parts = components.path.split(separator: "/")
        if let web = parts.lastIndex(of: "web") { parts.removeSubrange(web...) }
        components.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        return components.url ?? url
    }

    /// "12.1.0" -> true. Unparseable -> false: refuse rather than guess.
    nonisolated static func isSupported(version: String?) -> Bool {
        let parts = (version ?? "").split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return (parts[0], parts[1]) >= (minimumVersion.major, minimumVersion.minor)
    }

    /// What a failed Quick Connect sign-in tells the user.
    static func quickConnectFailureMessage(for error: Error) -> String {
        switch error {
        case MediaProviderError.unauthorized:
            String(localized: "Quick Connect is off on this server. Turn it on in the Jellyfin dashboard, under General.")
        case MediaProviderError.notFound:
            String(localized: "That code expired. Try again.")
        default:
            failureMessage(for: error)
        }
    }

    /// What a failed sign-in tells the user.
    static func failureMessage(for error: Error) -> String {
        switch error {
        case JellyfinSignInError.notJellyfin:
            String(localized: "That address isn't a Jellyfin server. Check the port. An Emby server signs in under Emby Server.")
        case JellyfinSignInError.serverTooOld(let version):
            String(localized: "This server runs Jellyfin \(version). Rivulet needs \(minimumVersion.major).\(minimumVersion.minor) or newer.")
        case JellyfinSignInError.untrustedCertificate:
            String(localized: "This server's HTTPS certificate isn't trusted. Try its http:// address.")
        case MediaProviderError.unauthorized:
            String(localized: "Jellyfin didn't accept that username and password.")
        default:
            String(localized: "Couldn't reach that server. Check the address and port.")
        }
    }
}
