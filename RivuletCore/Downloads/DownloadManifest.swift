// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Every download record, persisted as one versioned JSON file.
nonisolated struct DownloadManifest: Codable, Sendable, Equatable {
    /// 2: records are keyed by provider id and item id. 1 was Plex only (machine id, rating key).
    static let currentVersion = 2
    // The previous build reads this file too (a rollback must not lose the downloads): every record
    // also carries the keys its decoder requires, see `PreviousBuildRecord`.

    var version: Int = currentVersion
    var records: [DownloadRecord] = []
    /// The version an older file was read at, so the owner saves the migrated copy. Not stored.
    private(set) var migratedFrom: Int?

    init(records: [DownloadRecord] = []) {
        self.records = records
    }

    private enum CodingKeys: String, CodingKey { case version, records }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(records.map(PreviousBuildRecord.init), forKey: .records)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode(Int.self, forKey: .version)
        guard stored >= Self.currentVersion else {
            let legacy = try container.decode([LegacyDownloadRecord].self, forKey: .records)
            self.init(records: legacy.map(\.migrated))
            migratedFrom = stored
            return
        }
        self.init(records: try container.decode([DownloadRecord].self, forKey: .records))
    }

    /// A missing or unreadable file gives an empty manifest.
    static func load(from url: URL) -> DownloadManifest {
        DownloadsJSONFile.load(DownloadManifest.self, from: url) ?? DownloadManifest()
    }

    func save(to url: URL) throws {
        try DownloadsJSONFile.save(self, to: url)
    }

    /// The manifest at launch, and whether the files beside it may be swept for orphans. Not when a file
    /// was there and would not decode, nor on later launches while its `.corrupt` copy sits beside it:
    /// then the files are the only copy.
    static func loadForLaunch(from url: URL) -> (manifest: DownloadManifest, safeToSweep: Bool) {
        let files = FileManager.default
        let existed = files.fileExists(atPath: url.path)
        let manifest = load(from: url)
        // `load` moves a file it cannot decode aside.
        let unreadable = existed && !files.fileExists(atPath: url.path)
        let keptAside = files.fileExists(atPath: url.appendingPathExtension("corrupt").path)
        return (manifest, !unreadable && !keptAside)
    }

    /// Marks completed records whose file is gone as failed. Never drops a record.
    func reconciled(filesPresent: Set<String>) -> DownloadManifest {
        var copy = self
        for i in copy.records.indices where copy.records[i].state == .completed {
            if let name = copy.records[i].fileName, filesPresent.contains(name) { continue }
            copy.records[i].state = .failed(reason: String(localized: "File missing"))
        }
        return copy
    }
}

/// A record as the previous build reads it: everything it requires, beside the new keys it ignores.
/// `serverID` is the Plex machine id there; another server's id can never equal one, so that build
/// leaves such a record alone and its files stay.
nonisolated struct PreviousBuildRecord: Encodable {
    let record: DownloadRecord

    private enum Keys: String, CodingKey { case serverID, ratingKey, mediaID }

    func encode(to encoder: Encoder) throws {
        try record.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(record.isPlex ? DownloadIdentity.plexMachineID(of: record.providerID) ?? "" : record.providerID,
                             forKey: .serverID)
        try container.encode(record.itemID, forKey: .ratingKey)
        try container.encode(record.sourceID.flatMap(Int.init) ?? 0, forKey: .mediaID)
    }
}

/// JSON files under the Downloads directory, written atomically.
nonisolated enum DownloadsJSONFile {
    /// Nil when missing or corrupt; a corrupt file is kept beside it as `.corrupt`.
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        let corrupt = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: corrupt)
        try? FileManager.default.moveItem(at: url, to: corrupt)
        return nil
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
