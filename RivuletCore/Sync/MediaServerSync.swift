// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What iCloud carries for a Jellyfin or Emby sign-in: the stored account and its access token.
@MainActor
struct MediaServerSyncBody<Account: Codable>: Codable {
    var account: Account
    var token: String
}

/// The Jellyfin and Emby vault kinds, beside the Plex and Live TV ones.
extension SyncedAccountKind {
    static var jellyfin: SyncedAccountKind {
        SyncedAccountKind(
            kind: "jellyfin", updatesInPlace: false,
            export: {
                guard let account = JellyfinSession.account,
                      let token = CredentialRegistry.shared.token(for: .server(providerID: account.providerID)) else { return [] }
                return [AccountExport(id: account.providerID, kind: "jellyfin", identity: nil,
                                      body: SyncBodies.encode(MediaServerSyncBody(account: account, token: token)))]
            },
            adopt: { entry in
                guard let body = SyncBodies.decode(MediaServerSyncBody<JellyfinSession.Account>.self, entry.body) else { return .refused }
                return await JellyfinSession.adopt(account: body.account, token: body.token)
            },
            remove: { entry in
                guard JellyfinSession.account?.providerID == entry.id else { return }
                await JellyfinSession.signOut(scope: .syncedRemoval)
            })
    }

    static var emby: SyncedAccountKind {
        SyncedAccountKind(
            kind: "emby", updatesInPlace: false,
            export: {
                guard let account = EmbySession.account,
                      let token = CredentialRegistry.shared.token(for: .server(providerID: account.providerID)) else { return [] }
                return [AccountExport(id: account.providerID, kind: "emby", identity: nil,
                                      body: SyncBodies.encode(MediaServerSyncBody(account: account, token: token)))]
            },
            adopt: { entry in
                guard let body = SyncBodies.decode(MediaServerSyncBody<EmbySession.Account>.self, entry.body) else { return .refused }
                return await EmbySession.adopt(account: body.account, token: body.token)
            },
            remove: { entry in
                guard EmbySession.account?.providerID == entry.id else { return }
                await EmbySession.signOut(scope: .syncedRemoval)
            })
    }
}
