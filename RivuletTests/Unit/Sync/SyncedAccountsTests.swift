// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SyncedAccountsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ id: String, at offset: TimeInterval, deleted: Bool = false, body: String = "{}",
                       identity: String? = nil) -> SyncedAccounts.Entry {
        .init(id: id, kind: AccountSyncCoordinator.kind(of: id), identity: identity,
              updatedAt: t0.addingTimeInterval(offset), deleted: deleted, body: deleted ? nil : Data(body.utf8))
    }

    func test_newerEntryWins() {
        let local = SyncedAccounts(entries: [entry("plex", at: 10, body: #"{"a":1}"#)])
        let remote = SyncedAccounts(entries: [entry("plex", at: 5, body: #"{"a":2}"#)])
        XCTAssertEqual(SyncedAccounts.merge(local: local, remote: remote)["plex"]?.updatedAt, t0.addingTimeInterval(10))
        XCTAssertEqual(SyncedAccounts.merge(local: remote, remote: local)["plex"]?.updatedAt, t0.addingTimeInterval(10))
    }

    func test_tombstoneWinsATie() {
        let live = SyncedAccounts(entries: [entry("livetv:x", at: 5)])
        let gone = SyncedAccounts(entries: [entry("livetv:x", at: 5, deleted: true)])
        XCTAssertEqual(SyncedAccounts.merge(local: live, remote: gone)["livetv:x"]?.deleted, true)
        XCTAssertEqual(SyncedAccounts.merge(local: gone, remote: live)["livetv:x"]?.deleted, true)
    }

    func test_laterEntryBeatsAnEarlierTombstone() {
        let gone = SyncedAccounts(entries: [entry("livetv:x", at: 5, deleted: true)])
        let readded = SyncedAccounts(entries: [entry("livetv:x", at: 9)])
        XCTAssertEqual(SyncedAccounts.merge(local: readded, remote: gone)["livetv:x"]?.deleted, false)
    }

    func test_entriesOnlyOneSideHasAreKept() {
        let local = SyncedAccounts(entries: [entry("plex", at: 1)])
        let remote = SyncedAccounts(entries: [entry("jellyfin:s1", at: 1)])
        XCTAssertEqual(SyncedAccounts.merge(local: local, remote: remote).entries.map(\.id), ["jellyfin:s1", "plex"])
    }

    func test_oldTombstonesAreDroppedRecentOnesKept() {
        let now = t0.addingTimeInterval(SyncedAccounts.tombstoneLifetime + 100)
        let doc = SyncedAccounts(entries: [
            entry("livetv:old", at: 0, deleted: true),
            entry("livetv:new", at: SyncedAccounts.tombstoneLifetime, deleted: true),
            entry("livetv:live", at: 0),
        ])
        XCTAssertEqual(doc.pruned(now: now).entries.map(\.id), ["livetv:new", "livetv:live"])
    }

    func test_bodyPrintIgnoresKeyOrder() {
        XCTAssertEqual(SyncedAccounts.bodyPrint(Data(#"{"a":1,"b":[1,2]}"#.utf8)),
                       SyncedAccounts.bodyPrint(Data(#"{"b":[1,2],"a":1}"#.utf8)))
        XCTAssertNotEqual(SyncedAccounts.bodyPrint(Data(#"{"a":1}"#.utf8)), SyncedAccounts.bodyPrint(Data(#"{"a":2}"#.utf8)))
        XCTAssertNil(SyncedAccounts.bodyPrint(Data("not json".utf8)))
    }

    func test_documentRoundTripsThroughJSON() throws {
        let doc = SyncedAccounts(entries: [entry("plex", at: 3, body: #"{"token":"t"}"#, identity: "42"),
                                           entry("livetv:x", at: 4, deleted: true)])
        let data = try JSONEncoder().encode(doc)
        XCTAssertEqual(try JSONDecoder().decode(SyncedAccounts.self, from: data), doc)
    }
}

final class SignOutScopeTests: XCTestCase {
    func test_aCredentialNeverSharedIsRevokedAsToday() {
        XCTAssertTrue(SignOutScope.thisDevice.revokesToken(everShared: false))
        XCTAssertFalse(SignOutScope.thisDevice.tombstones(synced: false))
    }

    func test_thisDeviceOnlyNeverRevokesACredentialThatWasEverShared() {
        XCTAssertFalse(SignOutScope.thisDevice.revokesToken(everShared: true))
        XCTAssertFalse(SignOutScope.thisDevice.tombstones(synced: true))
    }

    func test_everywhereRevokesAndTombstones() {
        XCTAssertTrue(SignOutScope.everywhere.revokesToken(everShared: true))
        XCTAssertTrue(SignOutScope.everywhere.tombstones(synced: true))
    }

    func test_removalFromAnotherDeviceTouchesNothing() {
        XCTAssertFalse(SignOutScope.syncedRemoval.revokesToken(everShared: true))
        XCTAssertFalse(SignOutScope.syncedRemoval.revokesToken(everShared: false))
        XCTAssertFalse(SignOutScope.syncedRemoval.tombstones(synced: true))
    }

    func test_choiceIsAskedOnlyWhenTheItemIsActuallySynced() {
        XCTAssertTrue(SyncAvailability.isSynced(enabled: true, status: .on, suppressed: false, blocked: false))
        XCTAssertFalse(SyncAvailability.isSynced(enabled: false, status: .off, suppressed: false, blocked: false))
        XCTAssertFalse(SyncAvailability.isSynced(enabled: true, status: .noAccount, suppressed: false, blocked: false))
        XCTAssertFalse(SyncAvailability.isSynced(enabled: true, status: .on, suppressed: true, blocked: false))
        XCTAssertFalse(SyncAvailability.isSynced(enabled: true, status: .on, suppressed: false, blocked: true))
    }
}
