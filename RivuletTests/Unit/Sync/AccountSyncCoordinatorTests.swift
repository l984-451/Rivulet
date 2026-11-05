// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
private final class FakeVault: AccountVaulting {
    var stored = SyncedAccounts()
    var conflictsToServe = 0
    var failSaves = false
    private(set) var saves = 0
    private(set) var fetches = 0
    /// Run once, on the first fetch's return, to model another device writing in between.
    var raceWrite: (() -> Void)?

    func fetch() async throws -> VaultSnapshot {
        fetches += 1
        let snapshot = VaultSnapshot(accounts: stored, token: nil)
        if let raceWrite { self.raceWrite = nil; raceWrite() }
        return snapshot
    }

    func save(_ accounts: SyncedAccounts, over snapshot: VaultSnapshot) async throws -> VaultSaveResult {
        struct Offline: Error {}
        if failSaves { throw Offline() }
        if conflictsToServe > 0 { conflictsToServe -= 1; return .conflict }
        saves += 1
        stored = accounts
        return .saved
    }
}

@MainActor
private final class FakeDevice {
    var accounts: [String: AccountExport] = [:]
    var adopted: [String] = []
    var removed: [String] = []
    var outcome: AdoptOutcome = .adopted
    private(set) var adoptCalls = 0

    func kind(_ name: String, inPlace: Bool = false) -> SyncedAccountKind {
        SyncedAccountKind(
            kind: name, updatesInPlace: inPlace,
            export: { [unowned self] in self.accounts.values.filter { $0.kind == name }.sorted { $0.id < $1.id } },
            adopt: { [unowned self] entry in
                self.adoptCalls += 1
                guard self.outcome == .adopted else { return self.outcome }
                self.adopted.append(entry.id)
                self.accounts[entry.id] = AccountExport(id: entry.id, kind: entry.kind, identity: entry.identity, body: entry.body ?? Data())
                return .adopted
            },
            remove: { [unowned self] entry in
                self.removed.append(entry.id)
                self.accounts[entry.id] = nil
            })
    }
}

@MainActor
final class AccountSyncCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AccountSyncCoordinatorTests"
    private var vault: FakeVault!
    private var device: FakeDevice!
    private var clock = Date(timeIntervalSince1970: 3_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        vault = FakeVault()
        device = FakeDevice()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func coordinator(_ device: FakeDevice? = nil) -> AccountSyncCoordinator {
        let d = device ?? self.device!
        return AccountSyncCoordinator(vault: vault, kinds: [d.kind("plex"), d.kind("livetv", inPlace: true)],
                                      defaults: defaults, now: { [unowned self] in self.clock })
    }

    private func export(_ id: String, _ body: String = #"{"v":1}"#, identity: String? = nil) -> AccountExport {
        .init(id: id, kind: AccountSyncCoordinator.kind(of: id), identity: identity, body: Data(body.utf8))
    }

    func test_signInOnOneDeviceReachesTheOther() async throws {
        device.accounts["plex"] = export("plex", identity: "42")
        try await coordinator().sync()
        XCTAssertNotNil(vault.stored["plex"])

        let second = FakeDevice()
        let secondDefaults = UserDefaults(suiteName: suite + ".b")!
        secondDefaults.removePersistentDomain(forName: suite + ".b")
        let other = AccountSyncCoordinator(vault: vault, kinds: [second.kind("plex")], defaults: secondDefaults, now: { self.clock })
        let changed = try await other.sync()
        XCTAssertTrue(changed)
        XCTAssertEqual(second.adopted, ["plex"])
        secondDefaults.removePersistentDomain(forName: suite + ".b")
    }

    func test_failedAdoptionIsRetriedNextCycleAndDoesNotUpload() async throws {
        vault.stored = SyncedAccounts(entries: [.init(id: "plex", kind: "plex", identity: "42", updatedAt: clock.addingTimeInterval(-50),
                                                       deleted: false, body: Data(#"{"v":1}"#.utf8))])
        device.outcome = .unavailable
        let c = coordinator()
        let changed = try await c.sync()
        XCTAssertFalse(changed)
        XCTAssertEqual(vault.saves, 0)
        device.outcome = .adopted
        try await c.sync()
        XCTAssertEqual(device.adopted, ["plex"])
    }

    private func plexEntry(at offset: TimeInterval, body: String = #"{"v":1}"#) -> SyncedAccounts.Entry {
        .init(id: "plex", kind: "plex", identity: "42", updatedAt: clock.addingTimeInterval(offset),
              deleted: false, body: Data(body.utf8))
    }

    func test_refusedAdoptionIsNotTriedAgainUntilTheRecordChanges() async throws {
        vault.stored = SyncedAccounts(entries: [plexEntry(at: -50)])
        device.outcome = .refused
        let c = coordinator()
        try await c.sync()
        try await c.sync()
        try await c.sync()
        XCTAssertEqual(device.adoptCalls, 1)

        // Another device signs in again: a new record, so one more try.
        vault.stored = SyncedAccounts(entries: [plexEntry(at: -10, body: #"{"v":2}"#)])
        try await c.sync()
        XCTAssertEqual(device.adoptCalls, 2)
    }

    func test_unavailableAdoptionIsTriedEveryCycle() async throws {
        vault.stored = SyncedAccounts(entries: [plexEntry(at: -50)])
        device.outcome = .unavailable
        let c = coordinator()
        try await c.sync()
        try await c.sync()
        XCTAssertEqual(device.adoptCalls, 2)
    }

    func test_aCredentialIsMarkedSharedOnceUploaded() async throws {
        device.accounts["plex"] = export("plex", identity: "42")
        let c = coordinator()
        XCTAssertFalse(c.wasShared("plex"))
        try await c.sync()
        XCTAssertTrue(c.wasShared("plex"))
    }

    func test_aCredentialAdoptedFromTheCloudIsShared() async throws {
        vault.stored = SyncedAccounts(entries: [plexEntry(at: -50)])
        let c = coordinator()
        try await c.sync()
        XCTAssertTrue(c.wasShared("plex"))
    }

    func test_aCredentialThatCouldNotBeUploadedIsNotShared() async throws {
        device.accounts["plex"] = export("plex", identity: "42")
        vault.failSaves = true
        let c = coordinator()
        do { try await c.sync() } catch {}
        XCTAssertFalse(c.wasShared("plex"))
    }

    func test_sharedSurvivesARelaunchAndEndsWithTheSignOut() async throws {
        device.accounts["plex"] = export("plex", identity: "42")
        let c = coordinator()
        try await c.sync()
        XCTAssertTrue(coordinator().wasShared("plex"))
        device.accounts["plex"] = nil
        c.signedOut(id: "plex", identity: "42", everywhere: false)
        XCTAssertFalse(c.wasShared("plex"))
    }

    func test_adoptedAccountIsNotUploadedBackAsNew() async throws {
        let remoteTime = clock.addingTimeInterval(-500)
        vault.stored = SyncedAccounts(entries: [.init(id: "livetv:a", kind: "livetv", identity: nil, updatedAt: remoteTime,
                                                       deleted: false, body: Data(#"{"v":1}"#.utf8))])
        let c = coordinator()
        try await c.sync()
        try await c.sync()
        XCTAssertEqual(vault.saves, 0)
        XCTAssertEqual(vault.stored["livetv:a"]?.updatedAt, remoteTime)
    }

    func test_removalEverywhereTravelsAndSignsTheOtherDeviceOut() async throws {
        device.accounts["livetv:a"] = export("livetv:a")
        let c = coordinator()
        try await c.sync()

        let second = FakeDevice()
        second.accounts["livetv:a"] = export("livetv:a")
        let secondDefaults = UserDefaults(suiteName: suite + ".b")!
        secondDefaults.removePersistentDomain(forName: suite + ".b")
        let other = AccountSyncCoordinator(vault: vault, kinds: [second.kind("livetv", inPlace: true)], defaults: secondDefaults, now: { self.clock })
        try await other.sync()

        clock.addTimeInterval(60)
        device.accounts["livetv:a"] = nil
        c.signedOut(id: "livetv:a", identity: nil, everywhere: true)
        try await c.sync()
        XCTAssertEqual(vault.stored["livetv:a"]?.deleted, true)

        clock.addTimeInterval(60)
        try await other.sync()
        XCTAssertEqual(second.removed, ["livetv:a"])
        XCTAssertTrue(second.adopted.isEmpty)
        secondDefaults.removePersistentDomain(forName: suite + ".b")
    }

    func test_removalOnThisDeviceOnlyLeavesTheCloudAndStaysGone() async throws {
        device.accounts["livetv:a"] = export("livetv:a")
        let c = coordinator()
        try await c.sync()

        device.accounts["livetv:a"] = nil
        c.signedOut(id: "livetv:a", identity: nil, everywhere: false)
        clock.addTimeInterval(60)
        try await c.sync()
        try await c.sync()
        XCTAssertEqual(vault.stored["livetv:a"]?.deleted, false)
        XCTAssertTrue(device.adopted.isEmpty)
        XCTAssertNil(device.accounts["livetv:a"])
    }

    func test_signingInAgainAfterADeviceOnlyRemovalIsAllowed() async throws {
        device.accounts["livetv:a"] = export("livetv:a")
        let c = coordinator()
        try await c.sync()
        device.accounts["livetv:a"] = nil
        c.signedOut(id: "livetv:a", identity: nil, everywhere: false)
        try await c.sync()
        XCTAssertTrue(c.isSuppressed("livetv:a"))

        device.accounts["livetv:a"] = export("livetv:a", #"{"v":2}"#)
        clock.addTimeInterval(60)
        try await c.sync()
        XCTAssertFalse(c.isSuppressed("livetv:a"))
        XCTAssertNotNil(vault.stored["livetv:a"]?.body)
    }

    func test_aWriteFromAnotherDeviceBetweenFetchAndSaveIsMergedNotLost() async throws {
        device.accounts["plex"] = export("plex", identity: "42")
        vault.conflictsToServe = 1
        vault.raceWrite = { [unowned self] in
            self.vault.stored = SyncedAccounts(entries: [.init(
                id: "livetv:b", kind: "livetv", identity: nil, updatedAt: self.clock, deleted: false, body: Data(#"{"v":1}"#.utf8))])
        }
        try await coordinator().sync()
        XCTAssertNotNil(vault.stored["plex"])
        XCTAssertNotNil(vault.stored["livetv:b"])
        XCTAssertEqual(vault.fetches, 2)
        XCTAssertEqual(device.adopted, ["livetv:b"])
    }

    func test_aNetworkErrorLeavesLocalStateAlone() async {
        struct Down: Error {}
        @MainActor final class FailingVault: AccountVaulting {
            func fetch() async throws -> VaultSnapshot { throw Down() }
            func save(_ accounts: SyncedAccounts, over snapshot: VaultSnapshot) async throws -> VaultSaveResult { throw Down() }
        }
        device.accounts["plex"] = export("plex")
        let c = AccountSyncCoordinator(vault: FailingVault(), kinds: [device.kind("plex")], defaults: defaults, now: { self.clock })
        do { try await c.sync(); XCTFail("expected an error") } catch {}
        XCTAssertNotNil(device.accounts["plex"])
    }

    func test_appleAccountSwitchDoesNotUploadWhatThisDeviceHad() async throws {
        device.accounts["plex"] = export("plex", identity: "42")
        let c = coordinator()
        c.accountChanged()
        try await c.sync()
        XCTAssertNil(vault.stored["plex"])
        device.accounts["plex"] = export("plex", #"{"v":2}"#, identity: "42")
        try await c.sync()
        XCTAssertNotNil(vault.stored["plex"])
    }

    func test_stateSurvivesARelaunch() async throws {
        let c = coordinator()
        c.signedOut(id: "livetv:a", identity: nil, everywhere: false)
        XCTAssertTrue(coordinator().isSuppressed("livetv:a"))
    }
}
