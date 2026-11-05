// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What iCloud carries for the Plex account: the plex.tv token and the server this device prefers.
/// Connection URLs and server tokens are not here; they are found again from plex.tv.
nonisolated struct PlexSyncBody: Codable, Equatable {
    var token: String
    var accountUserID: Int?
    var preferredServerMachineID: String?
}

extension SyncedAccountKind {
    static var plex: SyncedAccountKind {
        SyncedAccountKind(
            kind: "plex", updatesInPlace: false,
            export: {
                let auth = PlexAuthManager.shared
                guard let token = auth.authToken, !token.isEmpty else { return [] }
                let body = PlexSyncBody(token: token, accountUserID: auth.syncAccountUserID,
                                        preferredServerMachineID: auth.selectedServerMachineID)
                return [AccountExport(id: PlexAuthManager.syncID, kind: "plex", identity: body.accountUserID.map(String.init),
                                      body: SyncBodies.encode(body))]
            },
            adopt: { entry in
                guard let body = SyncBodies.decode(PlexSyncBody.self, entry.body) else { return .refused }
                return await PlexAuthManager.shared.adoptSyncedSession(
                    token: body.token, preferredServerMachineID: body.preferredServerMachineID)
            },
            remove: { _ in PlexAuthManager.shared.signOut(scope: .syncedRemoval) })
    }
}

/// JSON for entry bodies. Sorted keys, so equal content prints equal.
@MainActor
enum SyncBodies {
    static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
