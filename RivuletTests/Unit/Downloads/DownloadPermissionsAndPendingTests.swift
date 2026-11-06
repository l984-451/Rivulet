// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class DownloadPermissionsAndPendingTests: XCTestCase {
    // MARK: - Permissions

    func test_aFailedReadIsAskedAgainAndNeverHidesDownload() async {
        let stub = StubMediaProvider(id: "jellyfin:a", kind: .jellyfin)
        stub.downloadAnswers = [.failure(MediaProviderError.unreachable), .success(true)]
        var permissions = DownloadPermissions()
        await permissions.ask([stub])
        XCTAssertFalse(permissions.allowed.contains("jellyfin:a"))
        XCTAssertFalse(permissions.answered.contains("jellyfin:a"), "a failed read is not an answer")
        await permissions.ask([stub])
        XCTAssertTrue(permissions.allowed.contains("jellyfin:a"))
        XCTAssertEqual(stub.downloadAsks, 2)
    }

    func test_anExplicitNoIsRememberedAndNotAskedAgain() async {
        let stub = StubMediaProvider(id: "emby:a", kind: .emby)
        stub.downloadAnswers = [.success(false), .success(true)]
        var permissions = DownloadPermissions()
        await permissions.ask([stub])
        await permissions.ask([stub])
        XCTAssertFalse(permissions.allowed.contains("emby:a"))
        XCTAssertEqual(stub.downloadAsks, 1)
    }

    func test_anAnsweredYesIsNotAskedAgain() async {
        let stub = StubMediaProvider(id: "jellyfin:a", kind: .jellyfin)
        stub.downloadAnswers = [.success(true)]
        var permissions = DownloadPermissions()
        await permissions.ask([stub])
        await permissions.ask([stub])
        XCTAssertEqual(stub.downloadAsks, 1)
        XCTAssertTrue(permissions.allowed.contains("jellyfin:a"))
    }

    func test_resetForgetsEverything() async {
        let stub = StubMediaProvider(id: "jellyfin:a", kind: .jellyfin)
        stub.downloadAnswers = [.success(true), .success(false)]
        var permissions = DownloadPermissions()
        await permissions.ask([stub])
        permissions.reset()
        await permissions.ask([stub])
        XCTAssertFalse(permissions.allowed.contains("jellyfin:a"))
    }

    // MARK: - Pending work

    private func record(_ id: String, _ state: DownloadState) -> DownloadRecord {
        DownloadRecord(id: id, providerID: "jellyfin:srv", itemID: id, quality: "original", state: state,
                       item: DownloadFixtures.item(id, providerID: "jellyfin:srv"), metadata: PlexMetadata(ratingKey: id))
    }

    func test_pending_isUnsettledVisibleAndWithoutATask() {
        let records = [record("run", .waitingForServer), record("hidden", .waitingForServer), record("done", .completed),
                       record("active", .downloading), record("paused", .pausedByUser), record("failed", .failed(reason: "x"))]
        let pending = DownloadRules.pending(records, visibleIDs: ["run", "done", "active", "paused", "failed"], activeIDs: ["active"])
        XCTAssertEqual(pending.map(\.id), ["run"])
    }

    func test_pending_aHiddenRecordDoesNotKeepTheTickerAlive() {
        let pending = DownloadRules.pending([record("hidden", .waitingForServer)], visibleIDs: [], activeIDs: [])
        XCTAssertTrue(pending.isEmpty)
    }
}
