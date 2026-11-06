// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// A manifest and an offline log written by the Plex-only build (version 1) load into the
/// provider-keyed shape with nothing lost, and are written back as version 2.
final class DownloadMigrationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func episode() -> V1Record {
        var meta = PlexMetadata(ratingKey: "971", type: "episode", title: "Pilot", viewOffset: 5000)
        meta.grandparentTitle = "Abbott Elementary"
        meta.grandparentRatingKey = "960"
        meta.parentRatingKey = "961"
        meta.parentIndex = 1
        meta.index = 1
        meta.thumb = "/library/metadata/971/thumb/1"
        meta.Media = [PlexMedia(id: 35314, duration: 1_320_778, bitrate: 4000, width: 1920, height: 1080, aspectRatio: nil,
                                audioChannels: 2, audioCodec: "aac", videoCodec: "h264", videoResolution: "1080",
                                container: "mkv", videoFrameRate: nil,
                                Part: [PlexPart(id: 35569, key: "/library/parts/35569/1/file.mkv", duration: nil, file: nil,
                                                size: 235_691_435, container: "mkv", Stream: nil)])]
        return V1Record(
            id: "11111111-1111-1111-1111-111111111111", serverID: "27061058f07a", profileID: "1", ratingKey: "971",
            mediaID: 35314, partID: 35569, quality: "original", state: .completed, expectedBytes: 235_691_435,
            receivedBytes: 235_691_435, etag: "\"42bd27\"", cellularAllowed: true, queueItemID: 134,
            fileName: "11111111-1111-1111-1111-111111111111.mkv", posterFileName: "11111111-1111-1111-1111-111111111111.poster.jpg",
            subtitleFiles: [.init(fileName: "x.sub0.srt", language: "en", title: "English", codec: "srt", isForced: false)],
            metadata: meta, outputLabel: "720x404", createdAt: created, completedAt: created.addingTimeInterval(120))
    }

    private func write(_ manifest: V1Manifest) throws -> URL {
        let url = dir.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: url)
        return url
    }

    // MARK: - Manifest

    func test_v1Manifest_keepsEveryFieldOfAnEpisode() throws {
        let loaded = DownloadManifest.load(from: try write(V1Manifest(records: [episode()])))

        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.migratedFrom, 1)
        let r = try XCTUnwrap(loaded.records.first)
        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(r.id, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(r.providerID, "plex:27061058f07a")
        XCTAssertEqual(r.profileID, "1")
        XCTAssertNil(r.accountID)
        XCTAssertEqual(r.itemID, "971")
        XCTAssertEqual(r.sourceID, "35314")
        XCTAssertEqual(r.partID, 35569)
        XCTAssertEqual(r.quality, "original")
        XCTAssertEqual(r.state, .completed)
        XCTAssertEqual(r.expectedBytes, 235_691_435)
        XCTAssertEqual(r.receivedBytes, 235_691_435)
        XCTAssertEqual(r.etag, "\"42bd27\"")
        XCTAssertEqual(r.cellularAllowed, true)
        XCTAssertEqual(r.queueItemID, 134)
        XCTAssertEqual(r.fileName, "11111111-1111-1111-1111-111111111111.mkv")
        XCTAssertEqual(r.posterFileName, "11111111-1111-1111-1111-111111111111.poster.jpg")
        XCTAssertEqual(r.subtitleFiles, [.init(fileName: "x.sub0.srt", language: "en", title: "English", codec: "srt", isForced: false)])
        XCTAssertEqual(r.outputLabel, "720x404")
        XCTAssertEqual(r.createdAt, created)
        XCTAssertEqual(r.completedAt, created.addingTimeInterval(120))
        // The player's metadata comes across whole.
        XCTAssertEqual(r.metadata.title, "Pilot")
        XCTAssertEqual(r.metadata.viewOffset, 5000)
        XCTAssertEqual(r.metadata.Media?.first?.id, 35314)
        XCTAssertEqual(r.metadata.Media?.first?.Part?.first?.key, "/library/parts/35569/1/file.mkv")
    }

    func test_v1Manifest_buildsTheListItemFromTheMetadata() throws {
        let r = try XCTUnwrap(DownloadManifest.load(from: try write(V1Manifest(records: [episode()]))).records.first)
        XCTAssertEqual(r.item.ref, MediaItemRef(providerID: "plex:27061058f07a", itemID: "971"))
        XCTAssertEqual(r.item.kind, .episode)
        XCTAssertEqual(r.item.title, "Pilot")
        XCTAssertEqual(r.item.seriesTitle, "Abbott Elementary")
        XCTAssertEqual(r.item.seasonNumber, 1)
        XCTAssertEqual(r.item.episodeNumber, 1)
        XCTAssertEqual(r.item.grandparentRef, MediaItemRef(providerID: "plex:27061058f07a", itemID: "960"))
        // No token or server address is kept in the item.
        XCTAssertNil(r.item.artwork.poster)
        XCTAssertNil(r.item.artwork.thumbnail)
        XCTAssertNil(r.item.parentArtwork)
    }

    func test_v1Manifest_keepsEveryStateAndOrder() throws {
        let states: [DownloadState] = [
            .waitingForNetwork, .waitingForServer, .preparing(progress: 40.5), .downloading,
            .paused, .pausedByUser, .failed(reason: "Server said no"), .completed,
        ]
        var records: [V1Record] = []
        for (i, state) in states.enumerated() {
            var r = episode()
            r.id = "id-\(i)"
            r.ratingKey = "\(i)"
            r.state = state
            records.append(r)
        }
        let loaded = DownloadManifest.load(from: try write(V1Manifest(records: records)))
        XCTAssertEqual(loaded.records.map(\.state), states)
        XCTAssertEqual(loaded.records.map(\.itemID), (0..<states.count).map(String.init))
    }

    func test_v1Manifest_unplannedAndUnknownServerRecords() throws {
        var r = episode()
        r.mediaID = 0
        r.partID = nil
        r.serverID = ""
        r.state = .waitingForServer
        r.fileName = nil
        let loaded = try XCTUnwrap(DownloadManifest.load(from: try write(V1Manifest(records: [r]))).records.first)
        XCTAssertNil(loaded.sourceID)
        XCTAssertNil(loaded.partID)
        XCTAssertEqual(loaded.providerID, "plex:")
        XCTAssertEqual(loaded.state, .waitingForServer)
    }

    func test_v1Manifest_aMovieAndAConvertedDownload() throws {
        var movie = episode()
        movie.metadata = PlexMetadata(ratingKey: "55", type: "movie", title: "American Made", year: 2017)
        movie.ratingKey = "55"
        movie.quality = "2000"
        movie.queueItemID = 7
        movie.state = .preparing(progress: 12)
        let r = try XCTUnwrap(DownloadManifest.load(from: try write(V1Manifest(records: [movie]))).records.first)
        XCTAssertEqual(r.item.kind, .movie)
        XCTAssertEqual(r.item.year, 2017)
        XCTAssertEqual(r.quality, "2000")
        XCTAssertEqual(r.queueItemID, 7)
        XCTAssertEqual(r.state, .preparing(progress: 12))
    }

    func test_migratedManifest_savesAsVersion2AndReloadsEqual() throws {
        let url = try write(V1Manifest(records: [episode()]))
        let loaded = DownloadManifest.load(from: url)
        try loaded.save(to: url)

        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(raw["version"] as? Int, 2)
        let record = try XCTUnwrap((raw["records"] as? [[String: Any]])?.first)
        XCTAssertNotNil(record["providerID"])
        XCTAssertNotNil(record["itemID"])

        let again = DownloadManifest.load(from: url)
        XCTAssertNil(again.migratedFrom)
        XCTAssertEqual(again.records, loaded.records)
    }

    func test_v2Manifest_isNotMigrated() throws {
        let url = dir.appendingPathComponent("v2.json")
        let record = DownloadRecord(providerID: "jellyfin:srv", itemID: "abc", sourceID: "abc", quality: "original",
                                    state: .downloading, item: DownloadFixtures.item("abc", providerID: "jellyfin:srv"),
                                    metadata: PlexMetadata(ratingKey: "abc"))
        try DownloadManifest(records: [record]).save(to: url)
        let loaded = DownloadManifest.load(from: url)
        XCTAssertNil(loaded.migratedFrom)
        XCTAssertEqual(loaded.records.first?.providerID, "jellyfin:srv")
    }

    // MARK: - Offline progress

    func test_v1ProgressLog_keepsEveryEntry() throws {
        let log = V1Log(entries: [
            V1Entry(serverID: "27061058f07a", profileID: "1", ratingKey: "971", offsetMs: 640_000, durationMs: 1_320_778,
                    watched: false, at: created),
            V1Entry(serverID: "27061058f07a", profileID: nil, ratingKey: "55", offsetMs: 7_000_000, durationMs: nil,
                    watched: true, at: created.addingTimeInterval(60)),
            V1Entry(serverID: "", profileID: "2", ratingKey: "9", offsetMs: 1, durationMs: 2, watched: false, at: created),
        ])
        let url = dir.appendingPathComponent("offline-progress.json")
        try JSONEncoder().encode(log).write(to: url)

        let loaded = OfflineProgressLog.load(from: url)
        XCTAssertEqual(loaded.entries.count, 3)
        XCTAssertEqual(loaded.entries[0], OfflineProgressLog.Entry(
            providerID: "plex:27061058f07a", profileID: "1", itemID: "971", offsetMs: 640_000, durationMs: 1_320_778,
            watched: false, at: created))
        XCTAssertEqual(loaded.entries[1], OfflineProgressLog.Entry(
            providerID: "plex:27061058f07a", profileID: nil, itemID: "55", offsetMs: 7_000_000, durationMs: nil,
            watched: true, at: created.addingTimeInterval(60)))
        XCTAssertEqual(loaded.entries[2].providerID, "plex:")
        XCTAssertEqual(loaded.entries[2].profileID, "2")
    }

    func test_progressLog_writesTheNewKeys() throws {
        var log = OfflineProgressLog()
        log.record(.init(providerID: "emby:s", profileID: nil, accountID: "u1", itemID: "813", sourceID: "mediasource_813",
                         offsetMs: 5, durationMs: 9, watched: false, at: created))
        let url = dir.appendingPathComponent("log.json")
        try log.save(to: url)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entry = try XCTUnwrap((raw["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["providerID"] as? String, "emby:s")
        XCTAssertEqual(entry["accountID"] as? String, "u1")
        XCTAssertEqual(OfflineProgressLog.load(from: url), log)
    }

    func test_progressLog_separatesServersAndAccounts() {
        var log = OfflineProgressLog()
        let at = created
        log.record(.init(providerID: "jellyfin:a", profileID: nil, accountID: "u1", itemID: "1", offsetMs: 1, durationMs: nil, watched: false, at: at))
        log.record(.init(providerID: "emby:a", profileID: nil, accountID: "u1", itemID: "1", offsetMs: 1, durationMs: nil, watched: false, at: at))
        log.record(.init(providerID: "jellyfin:a", profileID: nil, accountID: "u2", itemID: "1", offsetMs: 1, durationMs: nil, watched: false, at: at))
        log.record(.init(providerID: "jellyfin:a", profileID: nil, accountID: "u1", itemID: "1", offsetMs: 9, durationMs: nil, watched: false, at: at.addingTimeInterval(5)))
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries[0].offsetMs, 9)
    }
}
