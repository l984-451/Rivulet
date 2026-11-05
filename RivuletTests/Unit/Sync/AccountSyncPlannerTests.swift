// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class AccountSyncPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private var now: Date { t0.addingTimeInterval(1000) }

    private func export(_ id: String, body: String = #"{"v":1}"#, identity: String? = nil) -> AccountExport {
        .init(id: id, kind: AccountSyncCoordinator.kind(of: id), identity: identity, body: Data(body.utf8))
    }

    private func entry(_ id: String, at offset: TimeInterval, deleted: Bool = false, body: String = #"{"v":1}"#,
                       identity: String? = nil) -> SyncedAccounts.Entry {
        .init(id: id, kind: AccountSyncCoordinator.kind(of: id), identity: identity,
              updatedAt: t0.addingTimeInterval(offset), deleted: deleted, body: deleted ? nil : Data(body.utf8))
    }

    private func plan(_ exports: [AccountExport] = [], remote: [SyncedAccounts.Entry] = [],
                      state: AccountSyncState = .init(), inPlace: Set<String> = ["livetv"]) -> AccountSyncPlanner.Plan {
        AccountSyncPlanner.plan(exports: exports, handled: ["plex", "livetv", "jellyfin"], updatesInPlace: inPlace,
                                remote: .init(entries: remote), state: state, now: now)
    }

    func test_freshDeviceAdoptsWhatTheCloudHolds() {
        let p = plan(remote: [entry("plex", at: 5, identity: "42"), entry("livetv:a", at: 6)])
        XCTAssertEqual(Set(p.apply.map(\.id)), ["plex", "livetv:a"])
        XCTAssertFalse(p.needsUpload)
    }

    func test_localOnlyAccountUploadsWithNowAsItsTime() {
        let p = plan([export("plex", identity: "42")])
        XCTAssertTrue(p.needsUpload)
        XCTAssertEqual(p.merged["plex"]?.updatedAt, now)
        XCTAssertTrue(p.apply.isEmpty)
    }

    func test_identicalAccountAdoptsTheCloudTimeAndUploadsNothing() {
        let p = plan([export("livetv:a")], remote: [entry("livetv:a", at: 5)])
        XCTAssertFalse(p.needsUpload)
        XCTAssertEqual(p.state.ledger["livetv:a"]?.updatedAt, t0.addingTimeInterval(5))
    }

    func test_unchangedAccountKeepsItsTimeBetweenCycles() {
        var state = AccountSyncState()
        state.ledger["plex"] = .init(print: SyncedAccounts.bodyPrint(Data(#"{"v":1}"#.utf8))!, updatedAt: t0)
        let p = plan([export("plex")], remote: [entry("plex", at: 0)], state: state)
        XCTAssertFalse(p.needsUpload)
    }

    func test_changedLocalAccountGetsANewTimeAndUploads() {
        var state = AccountSyncState()
        state.ledger["livetv:a"] = .init(print: SyncedAccounts.bodyPrint(Data(#"{"v":1}"#.utf8))!, updatedAt: t0)
        let p = plan([export("livetv:a", body: #"{"v":2}"#)], remote: [entry("livetv:a", at: 0)], state: state)
        XCTAssertTrue(p.needsUpload)
        XCTAssertEqual(p.merged["livetv:a"]?.updatedAt, now)
    }

    func test_tombstoneFromAnotherDeviceSignsThisOneOut() {
        var state = AccountSyncState()
        state.ledger["plex"] = .init(print: SyncedAccounts.bodyPrint(Data(#"{"v":1}"#.utf8))!, updatedAt: t0)
        let p = plan([export("plex", identity: "42")], remote: [entry("plex", at: 50, deleted: true, identity: "42")], state: state)
        XCTAssertEqual(p.remove.map(\.id), ["plex"])
    }

    func test_tombstoneForAnotherPersonsAccountIsIgnored() {
        var state = AccountSyncState()
        state.ledger["plex"] = .init(print: SyncedAccounts.bodyPrint(Data(#"{"v":1}"#.utf8))!, updatedAt: t0)
        let p = plan([export("plex", identity: "42")], remote: [entry("plex", at: 50, deleted: true, identity: "99")], state: state)
        XCTAssertTrue(p.remove.isEmpty)
    }

    func test_signingInAgainBeatsAnEarlierTombstone() {
        let p = plan([export("livetv:a")], remote: [entry("livetv:a", at: 5, deleted: true)])
        XCTAssertTrue(p.remove.isEmpty)
        XCTAssertEqual(p.merged["livetv:a"]?.deleted, false)
        XCTAssertTrue(p.needsUpload)
    }

    func test_removalEverywhereUploadsATombstone() {
        var state = AccountSyncState()
        state.tombstones["livetv:a"] = entry("livetv:a", at: 900, deleted: true)
        let p = plan(remote: [entry("livetv:a", at: 5)], state: state)
        XCTAssertEqual(p.merged["livetv:a"]?.deleted, true)
        XCTAssertTrue(p.needsUpload)
        XCTAssertTrue(p.apply.isEmpty)
    }

    func test_confirmedTombstoneLeavesTheLocalList() {
        var state = AccountSyncState()
        state.tombstones["livetv:a"] = entry("livetv:a", at: 900, deleted: true)
        let p = plan(remote: [entry("livetv:a", at: 900, deleted: true)], state: state)
        XCTAssertNil(p.state.tombstones["livetv:a"])
        XCTAssertFalse(p.needsUpload)
    }

    func test_signedOutOnThisDeviceOnlyIsNotTakenAgain() {
        var state = AccountSyncState()
        state.suppressed = ["plex"]
        let p = plan(remote: [entry("plex", at: 5)], state: state)
        XCTAssertTrue(p.apply.isEmpty)
        XCTAssertFalse(p.needsUpload)
        XCTAssertEqual(p.merged["plex"]?.deleted, false)
    }

    func test_signingInAgainHereEndsTheSuppression() {
        var state = AccountSyncState()
        state.suppressed = ["plex"]
        let p = plan([export("plex", body: #"{"v":2}"#)], remote: [entry("plex", at: 5)], state: state)
        XCTAssertFalse(p.state.suppressed.contains("plex"))
    }

    func test_aDifferentPlexAccountIsNeverOverwrittenOrAdopted() {
        let p = plan([export("plex", body: #"{"v":2}"#, identity: "99")], remote: [entry("plex", at: 5, identity: "42")])
        XCTAssertEqual(p.blocked, ["plex"])
        XCTAssertTrue(p.apply.isEmpty)
        XCTAssertFalse(p.needsUpload)
        XCTAssertEqual(p.merged["plex"]?.identity, "42")
    }

    func test_aNewerCloudSignInDoesNotReplaceAnExistingOne() {
        let p = plan([export("plex", identity: "42")], remote: [entry("plex", at: 5000, body: #"{"v":9}"#, identity: "42")])
        XCTAssertTrue(p.apply.isEmpty)
    }

    func test_aNewerSourceReplacesTheLocalCopy() {
        var state = AccountSyncState()
        state.ledger["livetv:a"] = .init(print: SyncedAccounts.bodyPrint(Data(#"{"v":1}"#.utf8))!, updatedAt: t0)
        let p = plan([export("livetv:a")], remote: [entry("livetv:a", at: 500, body: #"{"v":9}"#)], state: state)
        XCTAssertEqual(p.apply.map(\.id), ["livetv:a"])
    }

    func test_kindsThisDeviceCannotSignInPassThrough() {
        let p = AccountSyncPlanner.plan(exports: [export("plex")], handled: ["plex"], updatesInPlace: [],
                                        remote: .init(entries: [entry("emby:s", at: 5)]), state: .init(), now: now)
        XCTAssertTrue(p.apply.isEmpty)
        XCTAssertNotNil(p.merged["emby:s"])
    }

    func test_anAppleAccountSwitchKeepsExistingAccountsOutOfTheNewCloud() {
        var state = AccountSyncState()
        state.held = ["plex": SyncedAccounts.bodyPrint(Data(#"{"v":1}"#.utf8))!]
        let p = plan([export("plex", identity: "42")], state: state)
        XCTAssertFalse(p.needsUpload)
        XCTAssertNil(p.merged["plex"])
    }

    func test_aHeldAccountUploadsOnceChangedHere() {
        var state = AccountSyncState()
        state.held = ["plex": SyncedAccounts.bodyPrint(Data(#"{"v":1}"#.utf8))!]
        let p = plan([export("plex", body: #"{"v":2}"#, identity: "42")], state: state)
        XCTAssertTrue(p.needsUpload)
        XCTAssertNil(p.state.held["plex"])
    }

    func test_aHeldAccountIsNotSignedOutByTheNewCloudsTombstone() {
        var state = AccountSyncState()
        state.held = ["plex": SyncedAccounts.bodyPrint(Data(#"{"v":1}"#.utf8))!]
        let p = plan([export("plex", identity: "42")], remote: [entry("plex", at: 50, deleted: true, identity: "42")], state: state)
        XCTAssertTrue(p.remove.isEmpty)
    }

    func test_oldTombstonesAreDroppedFromTheUpload() {
        let old = entry("livetv:z", at: -SyncedAccounts.tombstoneLifetime - 5000, deleted: true)
        let p = plan(remote: [old])
        XCTAssertNil(p.merged["livetv:z"])
        XCTAssertTrue(p.needsUpload)
    }
}
