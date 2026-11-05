// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class DownloadRulesTests: XCTestCase {
    private func part(_ id: Int, key: String? = "/library/parts/1/1/file.mkv") -> PlexPart {
        PlexPart(id: id, key: key, duration: nil, file: nil, size: 1000, container: "mkv", Stream: nil)
    }

    private func media(kbps: Int?, parts: [PlexPart]) -> PlexMedia {
        PlexMedia(id: 7, duration: nil, bitrate: kbps, width: nil, height: nil, aspectRatio: nil,
                  audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: "1080",
                  container: "mkv", videoFrameRate: nil, Part: parts)
    }

    private func step(_ kbps: Int) -> QualityStep { QualityStep.step(kbps: kbps)! }

    private func record(_ id: String, _ state: DownloadState) -> DownloadRecord {
        DownloadRecord(id: id, providerID: "plex:srv", itemID: id, sourceID: "1", quality: "original",
                       state: state, item: DownloadFixtures.item(id), metadata: PlexMetadata(ratingKey: id))
    }

    // MARK: - Plan

    func test_plan_originalSinglePart() {
        XCTAssertEqual(DownloadRules.plan(step: nil, media: media(kbps: 5000, parts: [part(11)])), .original(partID: 11))
    }

    func test_plan_stepBelowSourceConverts() {
        XCTAssertEqual(DownloadRules.plan(step: step(2000), media: media(kbps: 5000, parts: [part(11)])), .converted(step(2000)))
    }

    func test_plan_stepAtOrAboveSourceDownloadsOriginal() {
        XCTAssertEqual(DownloadRules.plan(step: step(8000), media: media(kbps: 5000, parts: [part(11)])), .original(partID: 11))
        XCTAssertEqual(DownloadRules.plan(step: step(4000), media: media(kbps: 4000, parts: [part(11)])), .original(partID: 11))
    }

    func test_plan_unknownSourceBitrateConverts() {
        let unknown = PlexMedia(id: 7, duration: nil, bitrate: nil, width: nil, height: nil, aspectRatio: nil,
                                audioChannels: nil, audioCodec: nil, videoCodec: nil, videoResolution: nil,
                                container: nil, videoFrameRate: nil, Part: [PlexPart(id: 1, key: "/k", duration: nil,
                                file: nil, size: nil, container: nil, Stream: nil)])
        XCTAssertEqual(DownloadRules.plan(step: step(720), media: unknown), .converted(step(720)))
    }

    func test_plan_multiPartOriginalIsRefused_butConvertedIsNot() {
        let split = media(kbps: 5000, parts: [part(1), part(2)])
        XCTAssertEqual(DownloadRules.plan(step: nil, media: split), .refused(DownloadRules.multiPartReason))
        XCTAssertEqual(DownloadRules.plan(step: step(2000), media: split), .converted(step(2000)))
    }

    func test_plan_noFile() {
        XCTAssertEqual(DownloadRules.plan(step: nil, media: nil), .refused(DownloadRules.noFileReason))
        XCTAssertEqual(DownloadRules.plan(step: nil, media: media(kbps: 1, parts: [part(1, key: nil)])),
                       .refused(DownloadRules.noFileReason))
    }

    // MARK: - Queue state

    func test_queueState_mapsEveryStatus() {
        func item(_ status: PlexDownloadQueueItem.Status, progress: Double? = nil, error: String? = nil) -> PlexDownloadQueueItem {
            PlexDownloadQueueItem(id: 1, status: status, progress: progress, errorText: error)
        }
        XCTAssertEqual(DownloadRules.state(for: item(.deciding)), .preparing(progress: 0))
        XCTAssertEqual(DownloadRules.state(for: item(.processing, progress: 40)), .preparing(progress: 40))
        XCTAssertEqual(DownloadRules.state(for: item(.waiting)), .waitingForServer)
        XCTAssertEqual(DownloadRules.state(for: item(.available)), .downloading)
        XCTAssertEqual(DownloadRules.state(for: item(.error, error: "Low disk space")), .failed(reason: "Low disk space"))
        XCTAssertEqual(DownloadRules.state(for: item(.expired)), .failed(reason: DownloadRules.conversionGoneReason))
        XCTAssertEqual(DownloadRules.state(for: item(.unknown("new"))), .preparing(progress: 0))
    }

    // MARK: - Transfer errors

    func test_transferError_forceQuitPauses() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [
            NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication,
        ])
        XCTAssertEqual(DownloadRules.state(afterTransferError: error), .paused)
    }

    func test_transferError_expensiveNetworkWaits() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.expensive.rawValue,
        ])
        XCTAssertEqual(DownloadRules.state(afterTransferError: error), .waitingForNetwork)
    }

    func test_transferError_connectivityWaitsForServer() {
        for code in [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                     NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed] {
            XCTAssertEqual(DownloadRules.state(afterTransferError: NSError(domain: NSURLErrorDomain, code: code)),
                           .waitingForServer, "code \(code)")
        }
    }

    func test_transferError_otherFails() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile)
        guard case .failed = DownloadRules.state(afterTransferError: error) else { return XCTFail() }
    }

    func test_rejectedStatus_retryableWaits_restFail() {
        XCTAssertEqual(DownloadRules.state(afterRejectedStatus: 503, converted: false), .waitingForServer)
        XCTAssertEqual(DownloadRules.state(afterRejectedStatus: 500, converted: false), .waitingForServer)
        XCTAssertEqual(DownloadRules.state(afterRejectedStatus: 429, converted: false), .waitingForServer)
        XCTAssertEqual(DownloadRules.state(afterRejectedStatus: 503, converted: true), .preparing(progress: 100))
        XCTAssertEqual(DownloadRules.state(afterRejectedStatus: 403, converted: false), .failed(reason: DownloadRules.remotePassReason))
        XCTAssertEqual(DownloadRules.state(afterRejectedStatus: 0, converted: true), .failed(reason: DownloadRules.shortFileReason))
    }

    // MARK: - Path

    func test_pathAction() {
        for task in [true, false] {
            for setting in [true, false] {
                XCTAssertEqual(DownloadRules.pathAction(away: false, cellularAllowed: setting, taskAllowsCellular: task), .run)
            }
        }
        XCTAssertEqual(DownloadRules.pathAction(away: true, cellularAllowed: true, taskAllowsCellular: true), .run)
        XCTAssertEqual(DownloadRules.pathAction(away: true, cellularAllowed: true, taskAllowsCellular: false), .restart)
        XCTAssertEqual(DownloadRules.pathAction(away: true, cellularAllowed: false, taskAllowsCellular: true), .stop)
        XCTAssertEqual(DownloadRules.pathAction(away: true, cellularAllowed: false, taskAllowsCellular: false), .wait)
    }

    func test_failureReason_retriesTransientStatuses() {
        XCTAssertEqual(DownloadRules.failureReason(httpStatus: 403), DownloadRules.remotePassReason)
        XCTAssertNotNil(DownloadRules.failureReason(httpStatus: 401))
        XCTAssertNotNil(DownloadRules.failureReason(httpStatus: 404))
        XCTAssertNil(DownloadRules.failureReason(httpStatus: 503))
        XCTAssertNil(DownloadRules.failureReason(httpStatus: 429))
        XCTAssertNil(DownloadRules.failureReason(httpStatus: 500))
    }

    // MARK: - Reconciliation

    func test_reconcile_attachesOneTaskPerOpenRecord_cancelsTheRest() {
        let records = [record("a", .downloading), record("b", .paused), record("done", .completed)]
        let plan = DownloadRules.reconcile(records, tasks: [
            (id: 5, recordID: "a"), (id: 3, recordID: "a"), (id: 7, recordID: "ghost"),
            (id: 8, recordID: nil), (id: 9, recordID: "done"),
        ])
        XCTAssertEqual(plan.attach, ["a": 3])
        XCTAssertEqual(plan.cancel.sorted(), [5, 7, 8, 9])
    }

    func test_reconcile_recordsWithoutTasksAreNotAttached() {
        let plan = DownloadRules.reconcile([record("b", .paused)], tasks: [])
        XCTAssertEqual(plan, DownloadRules.Reconciliation())
    }

    // MARK: - Host change

    func test_hostChanged() {
        let lan = URL(string: "https://192-168-1-140.abc.plex.direct:32400/library/parts/1/2/file.mkv?download=1")
        XCTAssertFalse(DownloadRules.hostChanged(taskURL: lan, serverURL: "https://192-168-1-140.abc.plex.direct:32400"))
        XCTAssertTrue(DownloadRules.hostChanged(taskURL: lan, serverURL: "https://71-2-3-4.abc.plex.direct:32400"))
        XCTAssertTrue(DownloadRules.hostChanged(taskURL: lan, serverURL: "https://192-168-1-140.abc.plex.direct:443"))
        XCTAssertFalse(DownloadRules.hostChanged(taskURL: nil, serverURL: "https://x.plex.direct:32400"))
    }

    // MARK: - Visibility

    private func owned(_ id: String, provider: String = "jellyfin:srv", profile: String? = nil, account: String? = "u1") -> DownloadRecord {
        DownloadRecord(id: id, providerID: provider, profileID: profile, accountID: account, itemID: id, sourceID: id,
                       quality: "original", state: .completed, item: DownloadFixtures.item(id, providerID: provider),
                       metadata: PlexMetadata(ratingKey: id))
    }

    func test_visible_aProfileSeesItsOwnAndUnownedDownloads() {
        let records = [owned("a", profile: "1"), owned("b", profile: "2"), owned("c", profile: nil)]
        XCTAssertEqual(DownloadRules.visible(records, profileID: "1", restricted: false, signedInAccounts: [:]).map(\.id), ["a", "c"])
        XCTAssertEqual(DownloadRules.visible(records, profileID: nil, restricted: false, signedInAccounts: [:]).map(\.id), ["a", "b", "c"])
    }

    func test_visible_aRestrictedProfileSeesOnlyPlex() {
        let records = [owned("j"), owned("e", provider: "emby:srv"), owned("p", provider: "plex:M", account: nil)]
        XCTAssertEqual(DownloadRules.visible(records, profileID: nil, restricted: true, signedInAccounts: [:]).map(\.id), ["p"])
    }

    func test_visible_anotherAccountOnTheSameServerHidesTheDownload() {
        let records = [owned("mine", account: "u1"), owned("theirs", account: "u2")]
        let seen = DownloadRules.visible(records, profileID: nil, restricted: false, signedInAccounts: ["jellyfin:srv": "u1"])
        XCTAssertEqual(seen.map(\.id), ["mine"])
    }

    func test_visible_signedOutOfTheServerKeepsDownloadsPlayable() {
        let records = [owned("a", account: "u1")]
        XCTAssertEqual(DownloadRules.visible(records, profileID: nil, restricted: false, signedInAccounts: [:]).map(\.id), ["a"])
    }

    // MARK: - Size and reasons

    func test_totalLength_prefersTheRangeTotal() {
        XCTAssertEqual(DownloadRules.totalLength(status: 206, contentRange: "bytes 0-0/5839739171", contentLength: 1), 5_839_739_171)
        XCTAssertEqual(DownloadRules.totalLength(status: 200, contentRange: nil, contentLength: 235_691_435), 235_691_435)
        XCTAssertNil(DownloadRules.totalLength(status: 200, contentRange: nil, contentLength: -1))
        XCTAssertNil(DownloadRules.totalLength(status: 206, contentRange: nil, contentLength: 1))
        XCTAssertNil(DownloadRules.totalLength(status: 206, contentRange: "bytes 0-0/*", contentLength: 1))
    }

    func test_failureReason_otherServersSpeakForThemselves() {
        XCTAssertEqual(DownloadRules.failureReason(httpStatus: 403, kind: .jellyfin), DownloadRules.notAllowedReason)
        XCTAssertEqual(DownloadRules.failureReason(httpStatus: 403, kind: .emby), DownloadRules.notAllowedReason)
        XCTAssertEqual(DownloadRules.failureReason(httpStatus: 403), DownloadRules.remotePassReason)
        XCTAssertFalse(DownloadRules.failureReason(httpStatus: 401, kind: .jellyfin)?.contains("Plex") ?? true)
        XCTAssertTrue(DownloadRules.failureReason(httpStatus: 401)?.contains("Plex") ?? false)
        XCTAssertEqual(DownloadRules.failureReason(httpStatus: 404, kind: .emby), DownloadRules.failureReason(httpStatus: 404))
        XCTAssertNil(DownloadRules.failureReason(httpStatus: 503, kind: .jellyfin))
    }

    func test_rejectedStatus_followsTheServersKind() {
        XCTAssertEqual(DownloadRules.state(afterRejectedStatus: 403, converted: false, kind: .jellyfin),
                       .failed(reason: DownloadRules.notAllowedReason))
        XCTAssertEqual(DownloadRules.state(afterRejectedStatus: 403, converted: false),
                       .failed(reason: DownloadRules.remotePassReason))
        XCTAssertEqual(DownloadRules.state(afterRejectedStatus: 503, converted: false, kind: .emby), .waitingForServer)
    }
}
