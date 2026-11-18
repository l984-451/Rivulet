// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Disk space the app's own data takes, for Settings. Walks the disk: call it off the main thread.
enum StorageUsage {
    /// Bytes on disk under `directory`, recursively.
    nonisolated static func bytes(in directory: URL?) -> Int64 {
        guard let directory,
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    nonisolated static func directory(_ kind: FileManager.SearchPathDirectory) -> URL? {
        FileManager.default.urls(for: kind, in: .userDomainMask).first
    }

    /// Caches, Application Support and temporary files together.
    nonisolated static func totalBytes() -> Int64 {
        bytes(in: directory(.cachesDirectory)) + bytes(in: directory(.applicationSupportDirectory))
            + bytes(in: FileManager.default.temporaryDirectory)
    }

    nonisolated static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
