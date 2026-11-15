// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PersistentDiagnosticsTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: PersistentLog

    func test_log_startsWithLaunchMarker() {
        let log = PersistentLog(directory: dir, version: "9.9 (1)")
        log.append("playback", "hello", isError: false)
        log.append("http", "boom", isError: true)
        let tail = log.tail()
        XCTAssertTrue(tail.current[0].hasPrefix("=== launch \(DiagLaunch.id) v9.9 (1)"))
        XCTAssertTrue(tail.current[1].hasSuffix("[playback] hello"))
        XCTAssertTrue(tail.current[2].contains(" E [http] boom"))
        XCTAssertEqual(tail.previousEnd, "no previous launch")
    }

    func test_log_stayUnderCapAndKeepsMarkerAndNewestLines() {
        let log = PersistentLog(directory: dir, maxBytes: 4_000, version: "1")
        for i in 0..<400 { log.append("c", "line \(i) " + String(repeating: "x", count: 40), isError: false) }
        let tail = log.tail()
        let bytes = try? Data(contentsOf: dir.appendingPathComponent("log-current.txt")).count
        XCTAssertLessThanOrEqual(bytes ?? .max, 4_000 + 200)
        XCTAssertTrue(tail.current[0].hasPrefix("=== launch"))
        XCTAssertTrue(tail.current.contains("[earlier lines dropped]"))
        XCTAssertTrue(tail.current.last!.contains("line 399"))
    }

    func test_log_nextLaunchKeepsPreviousAndItsLastLifecycleState() {
        let first = PersistentLog(directory: dir, version: "1")
        for i in 0..<30 { first.append("c", "padding line number \(i) to pass the size floor", isError: false) }
        first.mark("foreground")
        first.flush()
        let second = PersistentLog(directory: dir, version: "2")
        let tail = second.tail()
        XCTAssertTrue(tail.previous.last!.hasSuffix("[life] foreground"))
        XCTAssertEqual(tail.previousEnd, "foreground")
        XCTAssertEqual(tail.current.count, 1)
    }

    func test_log_emptyLaunchDoesNotReplacePreviousStory() {
        let first = PersistentLog(directory: dir, version: "1")
        for i in 0..<30 { first.append("c", "padding line number \(i) to pass the size floor", isError: false) }
        first.mark("background")
        first.flush()
        _ = PersistentLog(directory: dir, version: "2")   // crashes at once
        let third = PersistentLog(directory: dir, version: "3")
        XCTAssertEqual(third.tail().previousEnd, "background")
    }

    // MARK: PlaybackHistory

    func test_history_capsAndPersists() {
        let file = dir.appendingPathComponent("history.json")
        let history = PlaybackHistory(file: file, cap: 3)
        var ids: [String] = []
        for i in 0..<5 {
            var record = PlaybackSessionRecord()
            record.route = "aether"
            record.videoCodec = "hevc\(i)"
            ids.append(record.id)
            history.begin(record)
        }
        history.update(ids[4]) { $0.stallCount = 2; $0.stallSeconds = 7.5; $0.end = .ended }
        history.flush()

        let reloaded = PlaybackHistory(file: file, cap: 3).report()
        XCTAssertEqual(reloaded.map { $0["videoCodec"] as? String }, ["hevc2", "hevc3", "hevc4"])
        XCTAssertEqual(reloaded[2]["stallCount"] as? Int, 2)
        XCTAssertEqual(reloaded[2]["end"] as? String, "ended")
    }

    func test_history_reportMarksUnfinishedSessions() {
        let history = PlaybackHistory(file: dir.appendingPathComponent("h.json"))
        var old = PlaybackSessionRecord()
        old.launch = "previous"
        history.begin(old)
        history.begin(PlaybackSessionRecord())
        let report = history.report()
        XCTAssertEqual(report[0]["end"] as? String, "interrupted_app_exited")
        XCTAssertEqual(report[0]["this_launch"] as? Bool, false)
        XCTAssertEqual(report[1]["end"] as? String, "running_at_report")
        XCTAssertNil(report[1]["id"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(report))
    }

    func test_bitrateClass() {
        XCTAssertEqual(PlaybackSessionRecord.bitrateClass(kbps: nil), "unknown")
        XCTAssertEqual(PlaybackSessionRecord.bitrateClass(kbps: 3_999), "<4M")
        XCTAssertEqual(PlaybackSessionRecord.bitrateClass(kbps: 40_000), "25-60M")
        XCTAssertEqual(PlaybackSessionRecord.bitrateClass(kbps: 80_000), ">60M")
    }

    // MARK: gzip

    func test_gzip_roundTripsAndHasValidTrailer() throws {
        let payload = Data(String(repeating: "{\"a\":1}", count: 500).utf8)
        let gz = try XCTUnwrap(DiagnosticsUploader.gzip(payload))
        XCTAssertEqual(Array(gz.prefix(3)), [0x1f, 0x8b, 8])
        let deflated = gz.dropFirst(10).dropLast(8)
        let inflated = try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(inflated, payload)
        let trailer = Array(gz.suffix(8))
        let crc = trailer[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        XCTAssertEqual(crc, DiagnosticsUploader.crc32(payload))
        XCTAssertEqual(DiagnosticsUploader.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}
