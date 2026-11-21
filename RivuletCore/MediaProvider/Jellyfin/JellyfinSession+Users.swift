// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  JellyfinSession+Users.swift
//  Rivulet
//
//  More users of the signed-in Jellyfin server, for the profile picker. `account` stays the one
//  active user every other part of the app reads; the others wait in `savedUsers`, each with
//  its own token under `CredentialScope.serverUser`. Switching swaps one in, so nothing keyed
//  on the active account changes shape. Saved users never ride iCloud Sync: only the active one does.
//

import Foundation

extension JellyfinSession {

    static let savedUsersKey = "jellyfinSavedUsers"

    /// The server's other signed-in users, active one excluded, in the order they were added.
    static var savedUsers: [Account] {
        guard let data = UserDefaults.standard.data(forKey: savedUsersKey),
              let users = try? JSONDecoder().decode([Account].self, from: data) else { return [] }
        return users
    }

    /// Every signed-in user of the server, the active one first.
    static var users: [Account] { [account].compactMap { $0 } + savedUsers }

    private static func setSavedUsers(_ users: [Account]) {
        if users.isEmpty {
            UserDefaults.standard.removeObject(forKey: savedUsersKey)
        } else if let data = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(data, forKey: savedUsersKey)
        }
    }

    private static func savedScope(_ user: Account) -> CredentialScope {
        .serverUser(providerID: user.providerID, userID: user.userID)
    }

    /// Signs another user of the active server in and keeps them for the picker; the active
    /// user stays. Signing in the active user again changes nothing.
    @discardableResult
    static func addUser(
        username: String,
        password: String,
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> Account {
        guard let active = account else { throw MediaProviderError.unauthorized }
        let anonymous = JellyfinClient(baseURL: active.serverURL, token: nil, transport: transport)
        let auth: JFAuthenticationResult = try await anonymous.post(
            "Users/AuthenticateByName", body: JFAuthenticateByName(username: username, pw: password)
        )
        return try await keep(auth, username: username, on: active)
    }

    /// `addUser` by Quick Connect: `showCode` gets the code to approve on a device signed in as
    /// that user, then this polls until it is approved or the task is cancelled.
    @discardableResult
    static func addUserWithQuickConnect(
        pollInterval: Duration = .seconds(3),
        showCode: (String) -> Void,
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> Account {
        guard let active = account else { throw MediaProviderError.unauthorized }
        let anonymous = JellyfinClient(baseURL: active.serverURL, token: nil, transport: transport)
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
        return try await keep(auth, username: "", on: active)
    }

    private static func keep(_ auth: JFAuthenticationResult, username: String, on active: Account) async throws -> Account {
        guard let token = auth.accessToken, let userID = auth.user?.id else { throw MediaProviderError.unauthorized }
        // The address may now reach another server; a user of it does not belong in this picker.
        if let serverID = auth.serverId, serverID != active.serverID { throw JellyfinSignInError.notJellyfin }
        guard userID != active.userID else { return active }
        let user = Account(serverURL: active.serverURL, serverID: active.serverID, serverName: active.serverName,
                           userID: userID, userName: auth.user?.name ?? username)
        try await CredentialRegistry.shared.setToken(token, for: savedScope(user))
        setSavedUsers(savedUsers.filter { $0.userID != userID } + [user])
        onChanged?()
        return user
    }

    /// Makes a saved user the active one; the active user takes their place in `savedUsers`.
    /// False when the user or a token is missing, and nothing changes then.
    @discardableResult
    static func switchUser(to userID: String) async -> Bool {
        guard let active = account, active.userID != userID,
              let next = savedUsers.first(where: { $0.userID == userID }),
              let nextToken = CredentialRegistry.shared.token(for: savedScope(next)),
              let activeToken = CredentialRegistry.shared.token(for: .server(providerID: active.providerID)),
              let data = try? JSONEncoder().encode(next)
        else { return false }
        do {
            try await CredentialRegistry.shared.setToken(activeToken, for: savedScope(active))
            try await CredentialRegistry.shared.setToken(nextToken, for: .server(providerID: next.providerID))
        } catch {
            return false
        }
        await CredentialRegistry.shared.clearToken(for: savedScope(next))
        setSavedUsers(savedUsers.filter { $0.userID != userID } + [active])
        UserDefaults.standard.set(data, forKey: accountKey)
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        MusicProviderRegistry.shared.populateFromCurrentAuth()
        onChanged?()
        CloudSync.shared.accountsChanged()
        return true
    }

    /// Forgets a saved user here and ends their server session without waiting.
    static func removeUser(
        _ userID: String,
        transport: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async {
        guard let user = savedUsers.first(where: { $0.userID == userID }) else { return }
        let token = CredentialRegistry.shared.token(for: savedScope(user))
        await CredentialRegistry.shared.clearToken(for: savedScope(user))
        setSavedUsers(savedUsers.filter { $0.userID != userID })
        onChanged?()
        guard let token else { return }
        let client = JellyfinClient(baseURL: user.serverURL, token: token, transport: transport)
        Task { try? await client.post("Sessions/Logout") }
    }

    /// Part of signing out of the server: every saved user goes too.
    static func removeAllSavedUsers(transport: @escaping JellyfinClient.Transport) async {
        for user in savedUsers { await removeUser(user.userID, transport: transport) }
        setSavedUsers([])
    }
}
