// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

//
//  Presentation conveniences the iOS views read off the shared Plex models.
//
//  Decoding happens once, in RivuletCore's PlexMetadata; only display-shaped
//  accessors live here, iOS-only because they encode iOS presentation choices
//  (SF Symbol names, caption wording) that tvOS renders differently.
//
//  Nothing here may reimplement a rule. Resume and watched decisions go
//  through PlexMetadata.isInProgress / isWatched (WatchProgressPolicy).
//

extension PlexMetadata {
    var displayTitle: String { title ?? "Untitled" }

    /// One-line supporting text: episode coordinates and show for an episode,
    /// year for everything else.
    var subtitle: String? {
        if type == "episode" {
            return [episodeCode, grandparentTitle].compactMap { $0 }.joined(separator: " · ")
        }
        return year.map(String.init)
    }

    /// "S2, E5", the TV app's episode label.
    var episodeCode: String? {
        guard type == "episode", let season = parentIndex, let episode = index else { return nil }
        return "S\(season), E\(episode)"
    }

    /// The show for an episode or season, the item itself otherwise.
    var showTitle: String {
        switch type {
        case "episode": grandparentTitle ?? displayTitle
        case "season": parentTitle ?? displayTitle
        default: displayTitle
        }
    }

    var isPlayable: Bool { type == "movie" || type == "episode" || type == "clip" }

    /// Music tiles are 1:1, not 2:3, because album and artist art is square.
    var isMusic: Bool { ["artist", "album", "track"].contains(type ?? "") }

    var durationSeconds: TimeInterval { TimeInterval(duration ?? 0) / 1000 }
    var resumeSeconds: TimeInterval { TimeInterval(viewOffset ?? 0) / 1000 }

    /// Fraction for a drawn progress bar. Its own render rule (0 < f < 1), not
    /// the resume threshold; it wins over the watched glyph.
    var progressBarFraction: Double? {
        guard let fraction = watchProgress, fraction > 0, fraction < 1 else { return nil }
        return fraction
    }

    /// "12 min left" / "1 hr 5 min left" while a resume point exists.
    var timeLeftText: String? {
        guard isInProgress, let duration, let offset = viewOffset, duration > offset else { return nil }
        let minutes = max(1, (duration - offset) / 60_000)
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min left" : "\(minutes) min left"
    }

    /// "1h 52m" runtime.
    var runtimeText: String? {
        guard let duration, duration > 0 else { return nil }
        let minutes = duration / 60_000
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Artwork for a poster tile, matching tvOS `PosterCell`
    /// (`grandparentArtwork?.poster ?? artwork.poster`). An episode's own
    /// `thumb` is a 16:9 still, so the show poster wins.
    var posterPath: String? { grandparentThumb ?? thumb ?? parentThumb }
}

extension PlexLibrary {
    /// SF Symbol for the library's content type.
    var icon: String {
        switch type {
        case "movie": "film.stack"
        case "show": "tv"
        case "artist": "music.note.list"
        default: "rectangle.stack"
        }
    }
}

extension PlexHub {
    var displayTitle: String { title ?? "" }

    /// Rails stop at 20; the header's See All pages the rest.
    var items: [PlexMetadata] { Array((Metadata ?? []).prefix(20)) }

    /// Matched on identifier like tvOS `PlexDataStore.isContinueWatchingFamily`,
    /// never on the localized title. On Deck is in the family.
    var isContinueWatching: Bool {
        let id = (hubIdentifier ?? "").lowercased()
        return id.contains("continue") || id.contains("inprogress") || id.contains("ondeck")
    }
}

/// Same module, so this is not a retroactive conformance: RivuletCore folders
/// compile INTO each app target rather than forming a separate module.
extension PlexDevice: Identifiable {
    var id: String { clientIdentifier }
}

extension PlexMarker {
    /// The player chrome's names for the shared second-based accessors.
    var start: TimeInterval { startTimeSeconds }
    var end: TimeInterval { endTimeSeconds }

    /// IntroDB backfill markers carry synthetic negative ids (IntroDBClient).
    var isCommunity: Bool { (id ?? 0) < 0 }

    /// Stable identity for skip-button state across metadata refreshes, where
    /// Plex's numeric marker ids are not guaranteed to repeat.
    var stableID: String { "\(type ?? "marker")-\(id ?? startTimeOffset ?? 0)" }

    var displayName: String {
        switch type {
        case "intro": "Intro"
        case "recap": "Recap"
        case "credits": "Credits"
        case "commercial": "Commercial"
        default: "Segment"
        }
    }
}
