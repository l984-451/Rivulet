// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Going back to the Plex-only build must not cost anyone their files: its decoder reads a v2 manifest
/// and offline log (it ignores keys it does not know), and no launch sweeps files it could not account for.
final class DownloadRollbackTests: XCTestCase {
    private var dir: URL!
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadRollbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(_ id: String, provider: String, source: String?, key: String = "971", file: String? = nil) -> DownloadRecord {
        DownloadRecord(
            id: id, providerID: provider, profileID: "1", itemID: key, sourceID: source, partID: source == nil ? nil : 7,
            quality: "original", state: .completed, expectedBytes: 100, receivedBytes: 100, etag: "\"e\"",
            fileName: file ?? "\(id).mkv", posterFileName: "\(id).poster.jpg",
            item: DownloadFixtures.item(key, providerID: provider), metadata: PlexMetadata(ratingKey: key, type: "movie", title: "T"),
            createdAt: created, completedAt: created)
    }

    private func writeV2(_ records: [DownloadRecord]) throws -> URL {
        let url = dir.appendingPathComponent("manifest.json")
        try DownloadManifest(records: records).save(to: url)
        return url
    }

    // MARK: - The old decoder reads v2

    func test_v2Manifest_decodesThroughTheV1Struct() throws {
        let url = try writeV2([
            record("a", provider: "plex:MACHINE", source: "35314"),
            record("b", provider: "jellyfin:srv", source: "9f67-guid", key: "9f67-guid"),
            record("c", provider: "emby:srv", source: "mediasource_813", key: "813"),
            record("d", provider: "plex:", source: nil),
        ])
        let old = try? JSONDecoder().decode(V1Manifest.self, from: Data(contentsOf: url))
        XCTAssertNotNil(old, "the previous build must still decode the manifest")
        let records = try XCTUnwrap(old).records
        XCTAssertEqual(records.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(records.map(\.ratingKey), ["971", "9f67-guid", "813", "971"])
        // Plex keeps its machine id; another server's id can never equal one, so the old build leaves it alone.
        XCTAssertEqual(records.map(\.serverID), ["MACHINE", "jellyfin:srv", "emby:srv", ""])
        XCTAssertEqual(records.map(\.mediaID), [35314, 0, 0, 0])
        XCTAssertEqual(records[0].partID, 7)
        XCTAssertEqual(records[0].fileName, "a.mkv")
        XCTAssertEqual(records[0].posterFileName, "a.poster.jpg")
        XCTAssertEqual(records[0].state, .completed)
        XCTAssertEqual(records[0].metadata.title, "T")
        XCTAssertEqual(records[0].profileID, "1")
        XCTAssertEqual(records[0].expectedBytes, 100)
    }

    func test_v2Manifest_keepsEveryFileThroughTheOldBuildsSweep() throws {
        let records = [record("11111111-1111-1111-1111-111111111111", provider: "plex:M", source: "1"),
                       record("22222222-2222-2222-2222-222222222222", provider: "jellyfin:srv", source: "x", key: "x")]
        let url = try writeV2(records)
        let old = try? JSONDecoder().decode(V1Manifest.self, from: Data(contentsOf: url))
        let ids = Set((old?.records ?? []).map(\.id))
        let files = ["11111111-1111-1111-1111-111111111111.mkv", "11111111-1111-1111-1111-111111111111.poster.jpg",
                     "22222222-2222-2222-2222-222222222222.m4v", "22222222-2222-2222-2222-222222222222.sub0.srt"]
        // The old init: a file named for a UUID that no record owns is removed.
        let swept = files.filter { name in
            let owner = String(name.prefix { $0 != "." })
            return UUID(uuidString: owner) != nil && !ids.contains(owner)
        }
        XCTAssertEqual(swept, [])
    }

    func test_v2OfflineLog_decodesThroughTheV1Struct() throws {
        var log = OfflineProgressLog()
        log.record(.init(providerID: "plex:MACHINE", profileID: "1", itemID: "971", offsetMs: 5, durationMs: 9, watched: false, at: created))
        log.record(.init(providerID: "jellyfin:srv", profileID: nil, accountID: "u1", itemID: "abc", offsetMs: 7, durationMs: nil,
                         watched: true, at: created))
        let url = dir.appendingPathComponent("log.json")
        try log.save(to: url)
        let old = try? JSONDecoder().decode(V1Log.self, from: Data(contentsOf: url))
        XCTAssertNotNil(old, "the previous build must still decode the offline log")
        let entries = try XCTUnwrap(old).entries
        XCTAssertEqual(entries.map(\.serverID), ["MACHINE", "jellyfin:srv"])
        XCTAssertEqual(entries.map(\.ratingKey), ["971", "abc"])
        XCTAssertEqual(entries.map(\.offsetMs), [5, 7])
        XCTAssertEqual(entries.map(\.watched), [false, true])
    }

    func test_v2Manifest_stillReadsBackAsV2() throws {
        let original = [record("a", provider: "jellyfin:srv", source: "g", key: "g"), record("b", provider: "plex:M", source: "3")]
        let loaded = DownloadManifest.load(from: try writeV2(original))
        XCTAssertNil(loaded.migratedFrom)
        XCTAssertEqual(loaded.records, original)
        XCTAssertEqual(loaded.records.map(\.providerID), ["jellyfin:srv", "plex:M"])
        XCTAssertEqual(loaded.records.map(\.sourceID), ["g", "3"])
    }

    // MARK: - No sweep behind an unreadable manifest

    func test_launchLoad_aManifestThatWillNotDecodeIsNeverSafeToSweepFrom() throws {
        let url = dir.appendingPathComponent("manifest.json")
        try Data(#"{"version":9,"records":[{"nope":1}]}"#.utf8).write(to: url)
        let first = DownloadManifest.loadForLaunch(from: url)
        XCTAssertTrue(first.manifest.records.isEmpty)
        XCTAssertFalse(first.safeToSweep)
        // It was moved aside, so the next launch finds none; the kept copy still says to leave the files alone.
        let second = DownloadManifest.loadForLaunch(from: url)
        XCTAssertFalse(second.safeToSweep)
    }

    func test_launchLoad_aReadableOrAbsentManifestMaySweep() throws {
        XCTAssertTrue(DownloadManifest.loadForLaunch(from: dir.appendingPathComponent("none.json")).safeToSweep)
        let loaded = DownloadManifest.loadForLaunch(from: try writeV2([record("a", provider: "plex:M", source: "1")]))
        XCTAssertTrue(loaded.safeToSweep)
        XCTAssertEqual(loaded.manifest.records.count, 1)
    }

    func test_orphanedFiles_areUUIDNamedFilesNoRecordOwns() {
        let owned = "11111111-1111-1111-1111-111111111111"
        let stray = "33333333-3333-3333-3333-333333333333"
        let names: Set<String> = ["\(owned).mkv", "\(owned).poster.jpg", "\(stray).m4v", "\(stray).resume", "manifest.json",
                                  "offline-progress.json", "pending-removals.json", "manifest.json.corrupt"]
        let record = record(owned, provider: "plex:M", source: "1")
        XCTAssertEqual(DownloadRules.orphanedFiles(names, records: [record]).sorted(), ["\(stray).m4v", "\(stray).resume"])
    }

    // MARK: - Coming back after a rollback

    func test_aV1FileTheOldBuildRewrote_keepsAnotherServersRecordOnThatServer() throws {
        var old = V1Record(
            id: "a", serverID: "jellyfin:srv", profileID: nil, ratingKey: "g", mediaID: 0, partID: nil, quality: "original",
            state: .completed, expectedBytes: nil, receivedBytes: 5, etag: nil, cellularAllowed: nil, queueItemID: nil,
            fileName: "a.mkv", posterFileName: nil, subtitleFiles: [], metadata: PlexMetadata(ratingKey: "g", type: "movie", title: "G"),
            outputLabel: nil, createdAt: created, completedAt: nil)
        let url = dir.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(V1Manifest(records: [old])).write(to: url)
        var loaded = DownloadManifest.load(from: url).records
        XCTAssertEqual(loaded.first?.providerID, "jellyfin:srv")
        XCTAssertEqual(loaded.first?.item.ref, MediaItemRef(providerID: "jellyfin:srv", itemID: "g"))
        XCTAssertNil(loaded.first?.sourceID)

        old.serverID = "emby:srv"
        try JSONEncoder().encode(V1Manifest(records: [old])).write(to: url)
        loaded = DownloadManifest.load(from: url).records
        XCTAssertEqual(loaded.first?.providerID, "emby:srv")
    }
}
