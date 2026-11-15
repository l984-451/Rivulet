// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CryptoKit
import Foundation

/// What the app last learned about the saved Plex Home profile, kept in the
/// Keychain so a launch starts on that profile's token and never the account's.
nonisolated struct PlexProfileSession: Codable, Equatable {
    enum Access: Codable, Equatable {
        /// The profile is the signed-in account: content uses the account's server token.
        case account
        /// Entered with no PIN: the server token that entry produced.
        case token(String)
        /// Needs plex.tv to let the profile in again before any content shows.
        case withheld
    }

    /// Whose token a launch may load content with.
    enum Content: Equatable {
        case account
        case profile(String)
        case withheld
        /// A saved profile this build has never resolved: plex.tv is asked before
        /// any content loads, and the account's token is used only if it cannot be.
        case unresolved
    }

    let userID: Int
    /// SHA-256 of the account token it was made under, so another account reads nothing.
    let accountTokenHash: String
    let access: Access

    init(userID: Int, accountToken: String, access: Access) {
        self.userID = userID
        accountTokenHash = Self.hash(accountToken)
        self.access = access
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a Home user is the signed-in account itself. The admin flag stands
    /// in only until the account's id is known: a Home member's own account is not the admin.
    static func isAccount(userID: Int, admin: Bool, accountUserID: Int?) -> Bool {
        accountUserID.map { $0 == userID } ?? admin
    }

    /// What an entry through plex.tv leaves for the next launch. Only one made
    /// without a PIN leaves a token.
    static func access(isAccount: Bool, usedPin: Bool, serverToken: String) -> Access {
        isAccount ? .account : usedPin ? .withheld : .token(serverToken)
    }

    static let keychainKey = "plexProfileSession"
    static let savedUserIDKey = "selectedPlexUserId"
    /// UserDefaults: the Home user whose token loaded the cached content (0 is the
    /// account). Present once this build has resolved the saved profile.
    static let contentUserIDKey = "plexContentUserID"

    /// The one rule for the content token. A saved profile gets its own stored
    /// token or none, never the account's.
    static func content(accountToken: String?, savedUserID: Int?,
                        session: PlexProfileSession?, everResolved: Bool) -> Content {
        guard let accountToken else { return .withheld }
        guard let savedUserID else { return .account }
        guard let session else { return everResolved ? .withheld : .unresolved }
        guard session.userID == savedUserID, session.accountTokenHash == hash(accountToken) else { return .withheld }
        switch session.access {
        case .account: return .account
        case .token(let token): return .profile(token)
        case .withheld: return .withheld
        }
    }

    /// The token plex.tv-account content (Watchlist, favourite channels) uses: the
    /// account's while it is the profile in use, else that profile's own switched
    /// token, else none. Never the account's token for another profile.
    static func accountContentToken(accountToken: String?, contentUserID: Int,
                                    contentUnlocked: Bool, profileToken: String?) -> String? {
        guard contentUnlocked, let accountToken else { return nil }
        return contentUserID == 0 ? accountToken : profileToken
    }

    private static let profileTokenPrefix = "plexProfilePlexToken_"

    /// A Home profile's own plex.tv token, from its profile switch. Keychain only.
    @MainActor static func profilePlexToken(userID: Int) -> String? {
        KeychainHelper.get(profileTokenPrefix + String(userID))
    }

    @MainActor static func saveProfilePlexToken(_ token: String, userID: Int) {
        KeychainHelper.set(token, forKey: profileTokenPrefix + String(userID))
    }

    @MainActor static func deleteProfilePlexTokens() {
        KeychainHelper.deleteAll(withPrefix: profileTokenPrefix)
    }

    @MainActor static func load() -> PlexProfileSession? {
        KeychainHelper.get(keychainKey).flatMap { try? JSONDecoder().decode(Self.self, from: Data($0.utf8)) }
    }

    @MainActor func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        KeychainHelper.set(String(decoding: data, as: UTF8.self), forKey: Self.keychainKey)
    }

    @MainActor static func delete() {
        KeychainHelper.delete(keychainKey)
    }
}
