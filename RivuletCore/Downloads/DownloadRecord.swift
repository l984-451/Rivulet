// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Where a download stands. Waiting is a state, never a failure.
nonisolated enum DownloadState: Codable, Sendable, Equatable {
    case waitingForNetwork
    case waitingForServer
    /// Server conversion progress, 0 to 100.
    case preparing(progress: Double)
    case downloading
    /// Stopped by a force quit; resumes when the app opens.
    case paused
    case failed(reason: String)
    case completed
}

/// One download, keyed by server machine id and ratingKey, never by URL or token.
nonisolated struct DownloadRecord: Codable, Sendable, Equatable, Identifiable {
    /// A sidecar subtitle saved next to an Original download.
    nonisolated struct SubtitleFile: Codable, Sendable, Equatable {
        var fileName: String
        var language: String?
        var title: String?
        var codec: String?
        var isForced: Bool
    }

    var id: String = UUID().uuidString
    var serverID: String
    var profileID: String?
    var ratingKey: String
    var mediaID: Int
    var partID: Int?
    /// `StreamingQuality` raw value.
    var quality: String
    var state: DownloadState
    var expectedBytes: Int64?
    var receivedBytes: Int64 = 0
    var etag: String?
    /// The cellular flag the transfer's request was made with; resume data keeps it.
    var cellularAllowed: Bool?
    var queueItemID: Int?
    /// File names inside the Downloads directory.
    var fileName: String?
    var posterFileName: String?
    var subtitleFiles: [SubtitleFile] = []
    /// Full metadata (markers included) so playback works offline.
    var metadata: PlexMetadata
    /// The server's output label for converted downloads, e.g. "720x404".
    var outputLabel: String?
    var createdAt: Date = Date()
    var completedAt: Date?
}
