// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PauseScreenContent.swift
//  Rivulet
//
//  What the pause screen says, as pure functions, and the setting that picks its look.
//  `PauseScreenView` draws it; `PlayerContainerViewController` feeds it.
//

import Foundation

/// The pause screen's look (Settings > Playback > Pause Screen). The raw values are
/// persisted and stay English; `title` is what Settings shows.
enum PauseScreenStyle: String, CaseIterable {
    /// The paused picture stays, under a scrim, pushing in slowly.
    case frame
    /// The paused picture dims, sharp, and the details sit on a glass card.
    case glass

    static let storageKey = "pauseScreenStyle"
    static let fallback: PauseScreenStyle = .frame

    /// Read when the pause screen appears, so a change applies on the next pause.
    static var current: PauseScreenStyle {
        PauseScreenStyle(rawValue: SettingsStore.string(storageKey, default: fallback.rawValue)) ?? fallback
    }

    var title: String {
        switch self {
        case .frame: return String(localized: "pauseScreen.frame", defaultValue: "Frame")
        case .glass: return String(localized: "pauseScreen.glass", defaultValue: "Glass")
        }
    }

    /// The style after this one, for the Settings row's cycle.
    var next: PauseScreenStyle {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

/// The pause screen's text, from the player's display metadata. Plex items fill
/// `PlexMetadata` from the server; Jellyfin and Emby items arrive as
/// `ProviderPlaybackMetadata`'s shim, which sets the same fields (type, title,
/// show title, season and episode numbers, year, rating, summary).
enum PauseScreenText {
    /// The title the logo stands for: the show, for an episode.
    static func title(for metadata: PlexMetadata) -> String {
        if metadata.type == "episode", let show = nonEmpty(metadata.grandparentTitle) { return show }
        return nonEmpty(metadata.title) ?? String(localized: "Unknown")
    }

    /// An episode's "Season 2, Episode 5 · The Long Tide"; anything else's "2019 · R".
    static func detailLine(for metadata: PlexMetadata) -> String? {
        if metadata.type == "episode" {
            return episodeLine(season: metadata.parentIndex, episode: metadata.index, name: metadata.title)
        }
        return movieLine(year: metadata.year, rating: metadata.displayContentRating)
    }

    /// Drops whatever part is missing. Season 0 (specials) names no season, and
    /// a name that only repeats the number ("Episode 5") is not repeated.
    static func episodeLine(season: Int?, episode: Int?, name: String?) -> String? {
        let season = season.flatMap { $0 > 0 ? $0 : nil }
        var name = nonEmpty(name)
        if let episode, let shown = name,
           shown.caseInsensitiveCompare(String(localized: "Episode \(episode)")) == .orderedSame
            || shown.caseInsensitiveCompare("Episode \(episode)") == .orderedSame {
            name = nil
        }
        switch (season, episode, name) {
        case let (s?, e?, n?): return String(localized: "Season \(s), Episode \(e) · \(n)")
        case let (s?, e?, nil): return String(localized: "Season \(s), Episode \(e)")
        case let (nil, e?, n?): return String(localized: "Episode \(e) · \(n)")
        case let (nil, e?, nil): return String(localized: "Episode \(e)")
        case let (s?, nil, n?): return String(localized: "Season \(s) · \(n)")
        case let (s?, nil, nil): return String(localized: "Season \(s)")
        case let (nil, nil, n?): return n
        case (nil, nil, nil): return nil
        }
    }

    /// "2019 · R". Two tokens, not a sentence, so they are joined rather than localized.
    static func movieLine(year: Int?, rating: String?) -> String? {
        let parts = [year.map(String.init), nonEmpty(rating)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The item's own summary, or nothing.
    static func synopsis(for metadata: PlexMetadata) -> String? {
        nonEmpty(metadata.summary)
    }

    /// "38 min left · Ends at 10:41 PM", nil without a duration. `endTime` formats
    /// the end (the short time style); a parameter so tests can pin it.
    static func timeLine(position: TimeInterval, duration: TimeInterval, now: Date,
                         endTime: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String? {
        guard duration > 0 else { return nil }
        let left = max(0, duration - max(0, position))
        let end = endTime(now.addingTimeInterval(left))
        return String(localized: "\(FolderRowDetail.length(left)) left · Ends at \(end)")
    }

    /// How far in, 0 to 1, for the mini progress bar.
    static func progress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
