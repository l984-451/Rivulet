// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The document in the CloudKit record: one entry per signed-in account or Live TV source, with
/// secrets in `body`. An entry removed on all devices stays as a tombstone so the removal travels.
nonisolated struct SyncedAccounts: Codable, Equatable {
    var version = 1
    var entries: [Entry] = []

    nonisolated struct Entry: Codable, Equatable {
        /// "plex", "jellyfin:<serverID>", "emby:<serverID>", or "livetv:<sourceId>".
        var id: String
        var kind: String
        /// Who the account belongs to (the Plex account id), so a second account never overwrites the first.
        var identity: String?
        var updatedAt: Date
        var deleted: Bool
        /// The kind's JSON. nil in a tombstone.
        var body: Data?

        var bodyPrint: String? { body.flatMap(SyncedAccounts.bodyPrint) }
    }

    /// Tombstones older than this are dropped.
    static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600

    subscript(id: String) -> Entry? { entries.first { $0.id == id } }

    /// Per id the newer entry wins. On a tie a tombstone wins, so a removal is never undone by a clock tie.
    /// Entries only one side has are kept, including kinds this device cannot handle.
    static func merge(local: SyncedAccounts, remote: SyncedAccounts) -> SyncedAccounts {
        var byID: [String: Entry] = Dictionary(remote.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in local.entries {
            guard let other = byID[entry.id] else { byID[entry.id] = entry; continue }
            if entry.updatedAt > other.updatedAt || (entry.updatedAt == other.updatedAt && entry.deleted && !other.deleted) {
                byID[entry.id] = entry
            }
        }
        return SyncedAccounts(entries: byID.values.sorted { $0.id < $1.id })
    }

    func pruned(now: Date) -> SyncedAccounts {
        var copy = self
        copy.entries.removeAll { $0.deleted && now.timeIntervalSince($0.updatedAt) > Self.tombstoneLifetime }
        return copy
    }

    /// A hash of a JSON body that ignores key order. nil when the body is not JSON.
    static func bodyPrint(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return PreferenceMirror.fingerprint(object)
    }
}
