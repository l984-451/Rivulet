// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CloudKit
import XCTest
@testable import Rivulet

@MainActor
final class AccountVaultTests: XCTestCase {
    private func record(version: Int?, payload: Data?) -> CKRecord {
        let record = CKRecord(recordType: "Accounts", recordID: CKRecord.ID(recordName: "accounts-v1"))
        if let version { record["version"] = version }
        if let payload { record.encryptedValues["payload"] = payload }
        return record
    }

    func test_aReadableRecordParses() throws {
        let doc = SyncedAccounts(entries: [.init(id: "plex", kind: "plex", identity: "1", updatedAt: Date(timeIntervalSince1970: 5),
                                                  deleted: false, body: Data("{}".utf8))])
        let data = try JSONEncoder().encode(doc)
        XCTAssertEqual(try AccountVault.accounts(from: record(version: 1, payload: data)), doc)
    }

    func test_aPayloadThatDoesNotDecodeIsNeverOverwritten() {
        XCTAssertThrowsError(try AccountVault.accounts(from: record(version: 1, payload: Data("garbage".utf8)))) {
            XCTAssertEqual($0 as? VaultError, .unreadable)
        }
    }

    func test_aRecordWithoutAPayloadIsNeverOverwritten() {
        XCTAssertThrowsError(try AccountVault.accounts(from: record(version: 1, payload: nil))) {
            XCTAssertEqual($0 as? VaultError, .unreadable)
        }
    }

    func test_aNewerVersionIsNeverOverwritten() throws {
        let data = try JSONEncoder().encode(SyncedAccounts())
        XCTAssertThrowsError(try AccountVault.accounts(from: record(version: 2, payload: data))) {
            XCTAssertEqual($0 as? VaultError, .newerVersion)
        }
    }
}
