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
    /// Paused from the list; waits for Resume.
    case pausedByUser
    case failed(reason: String)
    case completed
}

/// One download, keyed by server and item id, never by URL or token.
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
    /// The server: "plex:<machine id>", "jellyfin:<server id>" or "emby:<server id>". Plex ids here are
    /// always the machine id (`DownloadIdentity`), never the registry's URL hash. A bare "plex:" is a
    /// legacy record made before the server was known; it matches any Plex server and is filled in.
    var providerID: String
    /// The Plex Home profile that made it (nil: no profiles).
    var profileID: String?
    /// The server account that made it on kinds that have one (the Jellyfin or Emby user); nil on Plex.
    var accountID: String?
    var itemID: String
    /// The version downloaded: Plex `Media.id` or the provider's source id. Nil until planned.
    var sourceID: String?
    var partID: Int?
    /// `StreamingQuality` raw value. Only Plex converts; every other server downloads the original.
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
    /// What lists show (title, hierarchy, numbers), without any token in its artwork URLs.
    var item: MediaItem
    /// What the player reads offline (markers included): Plex's full metadata, or for any other
    /// server the display shape built from its detail (duration, chapters, tracks, markers).
    var metadata: PlexMetadata
    /// The server's output label for converted downloads, e.g. "720x404".
    var outputLabel: String?
    var createdAt: Date = Date()
    var completedAt: Date?
}

extension DownloadRecord {
    nonisolated var kind: MediaProviderKind? { MediaProviderKind(providerID: providerID) }
    nonisolated var isPlex: Bool { kind == .plex }
}
