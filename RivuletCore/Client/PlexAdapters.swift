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
    var displayTitle: String { title ?? String(localized: "Untitled") }

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
        return String(localized: "S\(season), E\(episode)")
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
        return minutes >= 60 ? String(localized: "\(minutes / 60) hr \(minutes % 60) min left") : String(localized: "\(minutes) min left")
    }

    /// "1h 52m" runtime.
    var runtimeText: String? {
        guard let duration, duration > 0 else { return nil }
        let minutes = duration / 60_000
        return minutes >= 60 ? String(localized: "\(minutes / 60)h \(minutes % 60)m") : String(localized: "\(minutes)m")
    }

    /// Artwork for a poster tile, matching tvOS `PosterCell`
    /// (`grandparentArtwork?.poster ?? artwork.poster`). An episode's own
    /// `thumb` is a 16:9 still, so the show poster wins.
    var posterPath: String? { grandparentThumb ?? thumb ?? parentThumb }
}

extension MediaLibrary {
    /// SF Symbol for the library's content type.
    var icon: String {
        switch kind {
        case .movies: "film.stack"
        case .shows: "tv"
        default: "rectangle.stack"
        }
    }

    /// The key a per-library setting (sort order) is stored under. The selected Plex server keeps the
    /// bare section id the setting has always used; every other server's library is told apart by its server.
    var settingKey: String {
        MediaItemRef(providerID: providerID, itemID: "").isPlex ? id : "\(providerID)|\(id)"
    }
}

// The same display accessors as PlexMetadata's, over the agnostic item the browse screens hold.
// Resume and watched decisions go through MediaItem.isInProgress / isWatched (WatchProgressPolicy).
extension MediaItem {
    var displayTitle: String { title.isEmpty ? String(localized: "Untitled") : title }

    /// One-line supporting text: episode coordinates and show for an episode, year for everything else.
    var subtitle: String? {
        if kind == .episode {
            return [episodeCode, seriesTitle].compactMap { $0 }.joined(separator: " · ")
        }
        return year.map(String.init)
    }

    /// "S2, E5", the TV app's episode label.
    var episodeCode: String? {
        guard kind == .episode, let season = seasonNumber, let episode = episodeNumber else { return nil }
        return String(localized: "S\(season), E\(episode)")
    }

    /// The show for an episode or season, the item itself otherwise.
    var showTitle: String {
        switch kind {
        case .episode, .season: seriesTitle ?? displayTitle
        default: displayTitle
        }
    }

    /// A movie or episode: what Play starts directly.
    var isPlayable: Bool { kind == .movie || kind == .episode }

    /// Music tiles are 1:1, not 2:3, because album and artist art is square.
    var isMusicItem: Bool { isMusic == true }

    /// Fraction for a drawn progress bar. Its own render rule (0 < f < 1), not
    /// the resume threshold; it wins over the watched glyph.
    var progressBarFraction: Double? {
        guard let fraction = watchProgress, fraction > 0, fraction < 1 else { return nil }
        return fraction
    }

    /// "12 min left" / "1 hr 5 min left" while a resume point exists.
    var timeLeftText: String? {
        guard isInProgress, let runtime, runtime > userState.viewOffset else { return nil }
        let minutes = max(1, Int((runtime - userState.viewOffset) / 60))
        return minutes >= 60 ? String(localized: "\(minutes / 60) hr \(minutes % 60) min left") : String(localized: "\(minutes) min left")
    }

    /// "1h 52m" runtime.
    var runtimeText: String? {
        guard let runtime, runtime > 0 else { return nil }
        let minutes = Int(runtime / 60)
        return minutes >= 60 ? String(localized: "\(minutes / 60)h \(minutes % 60)m") : String(localized: "\(minutes)m")
    }

    /// VoiceOver value for a tile's watch state.
    var watchStateDescription: String {
        if let left = timeLeftText { return left }
        if let fraction = progressBarFraction { return String(localized: "\(Int(fraction * 100)) percent watched") }
        return countsAsWatched ? String(localized: "Watched") : ""
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
        case "intro": String(localized: "Intro")
        case "recap": String(localized: "Recap")
        case "credits": String(localized: "Credits")
        case "commercial": String(localized: "Commercial")
        default: String(localized: "Segment")
        }
    }
}
