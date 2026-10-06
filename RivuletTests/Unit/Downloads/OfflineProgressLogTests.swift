// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class OfflineProgressLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ key: String = "971", profile: String? = "1", offset: Int, watched: Bool = false, at seconds: TimeInterval) -> OfflineProgressLog.Entry {
        .init(serverID: "srv", profileID: profile, ratingKey: key, offsetMs: offset, durationMs: 1_320_778,
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
                if e.ratingKey == "2" { throw PlexAPIError.notFound }
                return e.ratingKey == "3" ? self.t0.addingTimeInterval(500) : nil
            },
            send: { sentKeys.append($0.ratingKey) },
            remove: { removed.append($0.ratingKey) })
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
                switch e.ratingKey {
                case "403": throw PlexAPIError.httpError(statusCode: 403, data: nil)
                case "500": throw PlexAPIError.httpError(statusCode: 500, data: nil)
                case "offline": throw URLError(.notConnectedToInternet)
                default: break
                }
            },
            remove: { removed.append($0.ratingKey) })
        XCTAssertTrue(sent)
        XCTAssertEqual(removed, ["403", "ok"])
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
