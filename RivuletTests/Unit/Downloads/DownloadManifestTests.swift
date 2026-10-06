// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class DownloadManifestTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManifestTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(_ state: DownloadState, fileName: String? = nil, key: String = "971") -> DownloadRecord {
        DownloadRecord(
            serverID: "srv", profileID: "1", ratingKey: key, mediaID: 35314, partID: 35569,
            quality: "original", state: state, expectedBytes: 235_691_435, receivedBytes: 1024,
            etag: "\"42bd27\"", queueItemID: 134, fileName: fileName, posterFileName: "p.jpg",
            subtitleFiles: [.init(fileName: "s.srt", language: "en", title: nil, codec: "srt", isForced: false)],
            metadata: PlexMetadata(ratingKey: key, type: "episode", title: "Pilot", viewOffset: 5000),
            outputLabel: "720x404", createdAt: Date(timeIntervalSince1970: 1_790_000_000), completedAt: nil)
    }

    func test_roundTrip_keepsEveryStateAndField() throws {
        let states: [DownloadState] = [
            .waitingForNetwork, .waitingForServer, .preparing(progress: 40.5), .downloading,
            .paused, .failed(reason: "Server said no"), .completed,
        ]
        let manifest = DownloadManifest(records: states.enumerated().map { record($1, fileName: "f\($0).mkv", key: "\($0)") })
        let url = dir.appendingPathComponent("manifest.json")
        try manifest.save(to: url)

        let loaded = DownloadManifest.load(from: url)
        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(loaded.version, DownloadManifest.currentVersion)
        XCTAssertEqual(loaded.records.map(\.state), states)
        XCTAssertEqual(loaded.records[0].metadata.title, "Pilot")
        XCTAssertEqual(loaded.records[0].metadata.viewOffset, 5000)
        XCTAssertEqual(loaded.records[0].subtitleFiles.first?.codec, "srt")
    }

    func test_load_missingFileIsEmpty() {
        let loaded = DownloadManifest.load(from: dir.appendingPathComponent("nope.json"))
        XCTAssertEqual(loaded, DownloadManifest())
    }

    func test_load_corruptFileIsEmptyAndKeptAside() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.json")
        try Data("{not json".utf8).write(to: url)

        XCTAssertEqual(DownloadManifest.load(from: url).records, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))

        // A good save after recovery loads normally.
        try DownloadManifest(records: [record(.downloading)]).save(to: url)
        XCTAssertEqual(DownloadManifest.load(from: url).records.count, 1)
    }

    func test_reconciled_failsCompletedWithoutFileAndDropsNothing() {
        let manifest = DownloadManifest(records: [
            record(.completed, fileName: "a.mkv", key: "1"),
            record(.completed, fileName: "gone.mkv", key: "2"),
            record(.completed, fileName: nil, key: "3"),
            record(.downloading, fileName: nil, key: "4"),
        ])
        let result = manifest.reconciled(filesPresent: ["a.mkv"])
        XCTAssertEqual(result.records.count, 4)
        XCTAssertEqual(result.records.map(\.state), [
            .completed, .failed(reason: "File missing"), .failed(reason: "File missing"), .downloading,
        ])
    }
}
