// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchProgress.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import Foundation
import SwiftData

/// Type of media being tracked
enum WatchMediaType: String, Codable {
    case movie
    case episode
    case liveTV
}

/// Tracks watch progress for Continue Watching functionality
@Model
final class WatchProgress {
    @Attribute(.unique) var id: UUID
    var mediaType: WatchMediaType
    var plexRatingKey: String?    // Plex item identifier
    var channelId: UUID?          // For live TV (last watched channel)
    var progressSeconds: Double
    var durationSeconds: Double
    var lastWatched: Date
    var isComplete: Bool

    // Cached metadata for display without network
    var title: String
    var subtitle: String?         // Episode title or channel name
    var thumbnailURL: String?
    var year: Int?
    var showTitle: String?        // For episodes: the show name

    init(mediaType: WatchMediaType, title: String) {
        self.id = UUID()
        self.mediaType = mediaType
        self.title = title
        self.progressSeconds = 0
        self.durationSeconds = 0
        self.lastWatched = Date()
        self.isComplete = false
    }

    /// Progress as percentage (0.0 - 1.0)
    var progressPercentage: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(progressSeconds / durationSeconds, 1.0)
    }

    /// Formatted remaining time
    var remainingTimeFormatted: String {
        let remaining = max(durationSeconds - progressSeconds, 0)
        let minutes = Int(remaining) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(localized: "\(hours)h \(mins)m remaining")
        }
        return String(localized: "\(minutes)m remaining")
    }

    /// Update progress and mark complete if > 90%
    func updateProgress(seconds: Double, duration: Double) {
        self.progressSeconds = seconds
        self.durationSeconds = duration
        self.lastWatched = Date()
        self.isComplete = progressPercentage > 0.9
    }
}
