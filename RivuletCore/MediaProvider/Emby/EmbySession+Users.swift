// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  EmbySession+Users.swift
//  Rivulet
//
//  More users of the signed-in Emby server, for the profile picker. `account` stays the one
//  active user every other part of the app reads; the others wait in `savedUsers`, each with
//  its own token under `CredentialScope.serverUser`. Switching swaps one in, so nothing keyed
//  on the active account changes shape. Saved users never ride iCloud Sync: only the active one does.
//

import Foundation

extension EmbySession {

    static let savedUsersKey = "embySavedUsers"

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
        transport: @escaping EmbyClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> Account {
        guard let active = account else { throw MediaProviderError.unauthorized }
        let client = EmbyClient(baseURL: active.serverURL, token: nil, transport: transport)
        let auth = try await client.authenticate(username: username, password: password)
        guard let token = auth.accessToken, let userID = auth.user?.id?.value else { throw MediaProviderError.unauthorized }
        // The address may now reach another server; a user of it does not belong in this picker.
        guard auth.serverId == active.serverID else { throw EmbySignInError.notEmby }
        guard userID != active.userID else { return active }
        let policy = await fetchUserPolicy(EmbyClient(baseURL: active.serverURL, token: token, transport: transport),
                                           userID: userID)
        let user = Account(serverURL: active.serverURL, serverID: active.serverID, serverName: active.serverName,
                           userID: userID, userName: auth.user?.name ?? username, policy: policy)
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
        transport: @escaping EmbyClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) async {
        guard let user = savedUsers.first(where: { $0.userID == userID }) else { return }
        let token = CredentialRegistry.shared.token(for: savedScope(user))
        await CredentialRegistry.shared.clearToken(for: savedScope(user))
        setSavedUsers(savedUsers.filter { $0.userID != userID })
        onChanged?()
        guard let token else { return }
        let client = EmbyClient(baseURL: user.serverURL, token: token, transport: transport)
        Task { try? await client.post("Sessions/Logout") }
    }

    /// Part of signing out of the server: every saved user goes too.
    static func removeAllSavedUsers(transport: @escaping EmbyClient.Transport) async {
        for user in savedUsers { await removeUser(user.userID, transport: transport) }
        setSavedUsers([])
    }

    private static func fetchUserPolicy(_ client: EmbyClient, userID: String) async -> Policy {
        guard let user: EmbyUser = try? await client.get("Users/\(userID)") else { return Policy() }
        return Policy(user.policy)
    }
}
