// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CredentialRegistry.swift
//  Rivulet
//
//  Unified, scope-keyed credential storage. Replaces direct PlexAuthManager
//  Keychain access from views. Backed by `KeychainHelper`.
//

import Foundation

/// Identifies the scope of a stored credential. Keychain key derived
/// automatically — stable across app launches.
enum CredentialScope: Hashable, Sendable {
    case plexAccount(accountID: String)
    case server(providerID: String)
    case serverUser(providerID: String, userID: String)

    /// Stable Keychain account string.
    var keychainKey: String {
        switch self {
        case .plexAccount(let id):
            return "plex.account.\(id)"
        case .server(let providerID):
            return "server.token.\(providerID)"
        case .serverUser(let pid, let uid):
            return "server.userToken.\(pid).\(uid)"
        }
    }
}

struct AccountCredential: Hashable, Sendable, Identifiable {
    let id: String                    // accountID
    let displayName: String
    let kind: MediaProviderKind
}

struct ServerCredential: Hashable, Sendable, Identifiable {
    let id: String                    // providerID, e.g. "plex:<machineId>"
    let displayName: String
    let userID: String
    let kind: MediaProviderKind
}

@Observable @MainActor
final class CredentialRegistry {
    static let shared = CredentialRegistry()

    private(set) var accounts: [AccountCredential] = []
    private(set) var serverCredentials: [ServerCredential] = []

    /// Returns the token previously stored under `scope`, or nil.
    nonisolated func token(for scope: CredentialScope) -> String? {
        KeychainHelper.get(scope.keychainKey)
    }

    func setToken(_ token: String, for scope: CredentialScope) async throws {
        guard KeychainHelper.set(token, forKey: scope.keychainKey) else {
            throw MediaProviderError.backendSpecific(underlying: String(localized: "Failed to write credential to Keychain"))
        }
    }

    func clearToken(for scope: CredentialScope) async {
        KeychainHelper.delete(scope.keychainKey)
    }

    func registerAccount(_ account: AccountCredential) {
        if !accounts.contains(account) { accounts.append(account) }
    }

    func unregisterAccount(id: String) {
        accounts.removeAll { $0.id == id }
    }

    func registerServer(_ credential: ServerCredential) {
        serverCredentials.removeAll { $0.id == credential.id }
        serverCredentials.append(credential)
    }

    func unregisterServer(providerID: String) {
        serverCredentials.removeAll { $0.id == providerID }
    }
}
