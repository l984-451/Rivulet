// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
@testable import Rivulet

/// The Plex-only build's record, exactly as its synthesized Codable read and wrote it.
struct V1Record: Codable {
    struct SubtitleFile: Codable {
        var fileName: String
        var language: String?
        var title: String?
        var codec: String?
        var isForced: Bool
    }
    var id: String
    var serverID: String
    var profileID: String?
    var ratingKey: String
    var mediaID: Int
    var partID: Int?
    var quality: String
    var state: DownloadState
    var expectedBytes: Int64?
    var receivedBytes: Int64
    var etag: String?
    var cellularAllowed: Bool?
    var queueItemID: Int?
    var fileName: String?
    var posterFileName: String?
    var subtitleFiles: [SubtitleFile]
    var metadata: PlexMetadata
    var outputLabel: String?
    var createdAt: Date
    var completedAt: Date?
}

struct V1Manifest: Codable {
    var version = 1
    var records: [V1Record]
}

struct V1Entry: Codable {
    var serverID: String
    var profileID: String?
    var ratingKey: String
    var offsetMs: Int
    var durationMs: Int?
    var watched: Bool
    var at: Date
}

struct V1Log: Codable {
    var entries: [V1Entry]
}
