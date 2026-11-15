// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CloudKit
import Foundation

nonisolated enum VaultError: Error, Equatable {
    /// The record has a payload this build cannot read: overwriting it could destroy another version's data.
    case unreadable
    case newerVersion
}

/// The CloudKit record that carries `SyncedAccounts`: one record in the private database, the
/// document in an encrypted field. Only a schema version sits in the clear.
@MainActor
final class AccountVault: AccountVaulting {
    private static let recordType = "Accounts"
    private static let recordID = CKRecord.ID(recordName: "accounts-v1")
    /// Built on first use: a build without the CloudKit entitlement raises when a container is made.
    private lazy var container = CKContainer(identifier: "iCloud.com.gstudios.rivulet.sync")
    private var database: CKDatabase { container.privateCloudDatabase }

    /// Reads the record, or refuses: a payload this build cannot read, or a newer version, must never be replaced.
    static func accounts(from record: CKRecord) throws -> SyncedAccounts {
        if let version = record["version"] as? Int, version > SyncedAccounts().version { throw VaultError.newerVersion }
        guard let data = record.encryptedValues["payload"] as? Data,
              let accounts = try? decoder.decode(SyncedAccounts.self, from: data) else { throw VaultError.unreadable }
        if accounts.version > SyncedAccounts().version { throw VaultError.newerVersion }
        return accounts
    }

    /// An iCloud account is signed in and CloudKit may be used. (Not the same as iCloud Drive being on.)
    func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    /// Who the iCloud account is, as a stable name that is only ever hashed.
    func accountIdentity() async -> String? {
        try? await container.userRecordID().recordName
    }

    func fetch() async throws -> VaultSnapshot {
        do {
            let record = try await database.record(for: Self.recordID)
            return VaultSnapshot(accounts: try Self.accounts(from: record), token: record)
        } catch let error as CKError where error.code == .unknownItem {
            return VaultSnapshot(accounts: SyncedAccounts(), token: nil)
        }
    }

    func save(_ accounts: SyncedAccounts, over snapshot: VaultSnapshot) async throws -> VaultSaveResult {
        let record = (snapshot.token as? CKRecord) ?? CKRecord(recordType: Self.recordType, recordID: Self.recordID)
        record["version"] = accounts.version
        record.encryptedValues["payload"] = try Self.encoder.encode(accounts)
        do {
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            if case .failure(let error) = result.saveResults[Self.recordID] { throw error }
            return .saved
        } catch let error as CKError where error.code == .serverRecordChanged {
            return .conflict
        }
    }

    // Dates keep the default (exact) encoding: a second-rounded time would never equal the one held locally.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
