// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class OfflineProgressLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ key: String = "971", profile: String? = "1", offset: Int, watched: Bool = false, at seconds: TimeInterval) -> OfflineProgressLog.Entry {
        .init(providerID: "plex:srv", profileID: profile, itemID: key, offsetMs: offset, durationMs: 1_320_778,
              watched: watched, at: t0.addingTimeInterval(seconds))
    }

    func test_record_coalescesPerItemKeepingLatest() {
        var log = OfflineProgressLog()
        log.record(entry(offset: 10_000, at: 0))
        log.record(entry(offset: 30_000, at: 20))
        log.record(entry(offset: 20_000, at: 10)) // arrives late, older

        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].offsetMs, 30_000)
        XCTAssertEqual(log.entries[0].at, t0.addingTimeInterval(20))
    }

    func test_record_keepsWatchedOnceSet() {
        var log = OfflineProgressLog()
        log.record(entry(offset: 1_300_000, watched: true, at: 0))
        log.record(entry(offset: 5_000, watched: false, at: 60))

        XCTAssertEqual(log.entries.count, 1)
        XCTAssertTrue(log.entries[0].watched)
        XCTAssertEqual(log.entries[0].offsetMs, 5_000)
    }

    func test_record_separatesItemsAndProfiles() {
        var log = OfflineProgressLog()
        log.record(entry("1", offset: 1, at: 0))
        log.record(entry("2", offset: 1, at: 0))
        log.record(entry("1", profile: "2", offset: 1, at: 0))
        log.record(entry("1", profile: nil, offset: 1, at: 0))
        XCTAssertEqual(log.entries.count, 4)
    }

    func test_acknowledgmentAndLateFailureAreScopedToTheOriginalOwner() {
        let key = OfflineProgressLog.Key(providerID: "emby:test", profileID: "a", accountID: "one", itemID: "42")
        let otherProfile = OfflineProgressLog.Key(providerID: "emby:test", profileID: "b", accountID: "one", itemID: "42")
        let otherAccount = OfflineProgressLog.Key(providerID: "emby:test", profileID: "a", accountID: "two", itemID: "42")
        func pending(_ owner: OfflineProgressLog.Key) -> OfflineProgressLog.Entry {
            owner.entry(offsetMs: 1000, durationMs: nil, watched: false, at: t0)
        }
        var log = OfflineProgressLog()
        log.record(pending(key))
        log.record(pending(otherProfile))
        XCTAssertTrue(log.reached(key, at: t0))
        XCTAssertFalse(log.record(pending(key)))
        XCTAssertTrue(log.record(pending(otherAccount)))
        XCTAssertEqual(log.entries, [pending(otherProfile), pending(otherAccount)])

        let newer = key.entry(offsetMs: 2000, durationMs: nil, watched: false, at: t0.addingTimeInterval(1))
        log.record(newer)
        XCTAssertFalse(log.reached(key, at: t0))
        XCTAssertTrue(log.entries.contains(newer))
    }

    func test_shouldReplay_onlyWhenServerHasNoLaterView() {
        let e = entry(offset: 1, at: 100)
        XCTAssertTrue(OfflineProgressLog.shouldReplay(e, serverLastViewedAt: nil))
        XCTAssertTrue(OfflineProgressLog.shouldReplay(e, serverLastViewedAt: t0.addingTimeInterval(50)))
        XCTAssertFalse(OfflineProgressLog.shouldReplay(e, serverLastViewedAt: t0.addingTimeInterval(100)))
        XCTAssertFalse(OfflineProgressLog.shouldReplay(e, serverLastViewedAt: t0.addingTimeInterval(200)))
    }

    func test_resumeOffset_serverWinsUnlessPendingIsNewer() {
        let pending = entry(offset: 2_400_000, at: 100)
        let server = { (seconds: TimeInterval) in self.t0.addingTimeInterval(seconds) }
        XCTAssertEqual(OfflineProgressLog.resumeOffsetMs(serverOffsetMs: 600_000, serverLastViewedAt: server(50), pending: pending), 2_400_000)
        XCTAssertEqual(OfflineProgressLog.resumeOffsetMs(serverOffsetMs: 600_000, serverLastViewedAt: server(200), pending: pending), 600_000)
        // Finished elsewhere: no server offset means start over.
        XCTAssertNil(OfflineProgressLog.resumeOffsetMs(serverOffsetMs: nil, serverLastViewedAt: server(200), pending: pending))
        XCTAssertNil(OfflineProgressLog.resumeOffsetMs(serverOffsetMs: nil, serverLastViewedAt: server(200), pending: nil))
    }

    func test_replay_sendsOnceDropsGoneAndSkipsLaterServerViews() async {
        let entries = [entry("1", offset: 1, at: 100), entry("2", offset: 2, at: 100), entry("3", offset: 3, at: 100)]
        var sentKeys: [String] = []
        var removed: [String] = []
        let sent = await OfflineProgressLog.replay(
            entries,
            serverLastViewedAt: { e in
                if e.itemID == "2" { throw PlexAPIError.notFound }
                return e.itemID == "3" ? self.t0.addingTimeInterval(500) : nil
            },
            send: { sentKeys.append($0.itemID) },
            remove: { removed.append(contentsOf: $0.map(\.itemID)) })
        XCTAssertTrue(sent)
        XCTAssertEqual(sentKeys, ["1"])
        XCTAssertEqual(removed, ["1", "2", "3"])
    }

    func test_replay_transportErrorKeepsRest_5xxKeepsEntry_4xxDrops() async {
        let entries = [entry("403", offset: 1, at: 0), entry("500", offset: 1, at: 0), entry("ok", offset: 1, at: 0),
                       entry("offline", offset: 1, at: 0), entry("after", offset: 1, at: 0)]
        var removed: [String] = []
        let sent = await OfflineProgressLog.replay(
            entries,
            serverLastViewedAt: { _ in nil },
            send: { e in
                switch e.itemID {
                case "403": throw PlexAPIError.httpError(statusCode: 403, data: nil)
                case "500": throw PlexAPIError.httpError(statusCode: 500, data: nil)
                case "offline": throw URLError(.notConnectedToInternet)
                default: break
                }
            },
            remove: { removed.append(contentsOf: $0.map(\.itemID)) })
        XCTAssertTrue(sent)
        XCTAssertEqual(removed, ["403", "ok"])
    }

    func test_replay_checkpointsThePrefixAndRetainsTransientFailures() async {
        for status in [401, 408, 421, 425, 429] {
            let entries = ["ok", "retry", "later"].map { entry($0, offset: 1, at: 0) }
            var attempts: [String] = []
            var checkpoints: [[String]] = []
            let sent = await OfflineProgressLog.replay(entries, serverLastViewedAt: { _ in nil }, send: {
                attempts.append($0.itemID)
                if $0.itemID == "retry" { throw PlexAPIError.httpError(statusCode: status, data: nil) }
            }, remove: { checkpoints.append($0.map(\.itemID)) })
            XCTAssertTrue(sent)
            XCTAssertEqual(attempts, ["ok", "retry"])
            XCTAssertEqual(checkpoints, [["ok"]])
        }
    }

    func test_checkpointsSaveBoundedBatchesAndKeepAReplacedEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.json")
        var log = OfflineProgressLog()
        for id in 0..<100 { log.record(entry(String(id), offset: id, at: 0)) }
        let snapshot = log.entries
        try log.save(to: url)
        var sizes: [Int] = []
        let newer = entry("1", offset: 1000, at: 10)
        let sent = await OfflineProgressLog.replay(snapshot, serverLastViewedAt: { _ in nil }, send: { current in
            if current.itemID == "2" {
                log.record(newer)
                try log.save(to: url)
            }
            if current.itemID == String(OfflineProgressLog.checkpointSize) {
                let durable = OfflineProgressLog.load(from: url)
                XCTAssertEqual(durable.entries, [newer] + Array(snapshot.dropFirst(OfflineProgressLog.checkpointSize)))
            }
        }, remove: { batch in
            sizes.append(batch.count)
            XCTAssertTrue(log.remove(replayed: batch))
            do { try log.save(to: url) } catch { XCTFail("Checkpoint failed: \(error)") }
        })
        XCTAssertTrue(sent)
        XCTAssertEqual(sizes, [16, 16, 16, 16, 16, 16, 4])
        XCTAssertEqual(OfflineProgressLog.load(from: url).entries, [newer])
    }

    func test_saveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineProgressLogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("progress.json")
        var log = OfflineProgressLog()
        log.record(entry(offset: 42, watched: true, at: 0))
        try log.save(to: url)
        XCTAssertEqual(OfflineProgressLog.load(from: url), log)
        XCTAssertEqual(OfflineProgressLog.load(from: dir.appendingPathComponent("none.json")), OfflineProgressLog())
    }
}
