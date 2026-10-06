// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Every download record, persisted as one versioned JSON file.
nonisolated struct DownloadManifest: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var records: [DownloadRecord] = []

    /// A missing or unreadable file gives an empty manifest.
    static func load(from url: URL) -> DownloadManifest {
        DownloadsJSONFile.load(DownloadManifest.self, from: url) ?? DownloadManifest()
    }

    func save(to url: URL) throws {
        try DownloadsJSONFile.save(self, to: url)
    }

    /// Marks completed records whose file is gone as failed. Never drops a record.
    func reconciled(filesPresent: Set<String>) -> DownloadManifest {
        var copy = self
        for i in copy.records.indices where copy.records[i].state == .completed {
            if let name = copy.records[i].fileName, filesPresent.contains(name) { continue }
            copy.records[i].state = .failed(reason: "File missing")
        }
        return copy
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
