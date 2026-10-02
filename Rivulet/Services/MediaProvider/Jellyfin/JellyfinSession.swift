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

        let auth: JFAuthenticationResult = try await anonymous.post(
            "Users/AuthenticateByName", body: JFAuthenticateByName(username: username, pw: password)
        )
        guard let token = auth.accessToken, let userID = auth.user?.id else {
            throw MediaProviderError.unauthorized
        }

        let account = Account(
            serverURL: serverURL,
            serverID: serverID,
            serverName: info.serverName ?? "Jellyfin",
            userID: userID,
            userName: auth.user?.name ?? username
        )
        try await CredentialRegistry.shared.setToken(token, for: .server(providerID: account.providerID))
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: accountKey)
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        onChanged?()
        return account
    }

    /// Forgets everything locally, then revokes the token server-side without
    /// waiting. An unreachable server (the likeliest reason to sign out) must
    /// not hold the row for the 60s request timeout, and a second press finds
    /// nothing left to sign out.
    static func signOut(
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async {
        guard let account else { return }
        let scope = CredentialScope.server(providerID: account.providerID)
        let token = CredentialRegistry.shared.token(for: scope)
        await CredentialRegistry.shared.clearToken(for: scope)
        UserDefaults.standard.removeObject(forKey: accountKey)
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        onChanged?()

        guard let token else { return }
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
}
