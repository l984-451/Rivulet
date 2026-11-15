// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PauseScreenContent.swift
//  Rivulet
//
//  What the pause screen says, as pure functions.
//  `PauseScreenView` draws it; `PlayerContainerViewController` feeds it.
//

import Foundation

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

    /// The most whole sentences that `fits`, so a long summary ends on a full stop
    /// rather than an ellipsis. All of it when even the first sentence won't fit
    /// (the label then truncates).
    static func fittedSynopsis(_ text: String, fits: (String) -> Bool) -> String {
        guard !fits(text) else { return text }
        var sentenceEnds: [String.Index] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { _, range, _, _ in
            sentenceEnds.append(range.upperBound)
        }
        for end in sentenceEnds.reversed() {
            let candidate = text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty, candidate.count < text.count, fits(candidate) { return candidate }
        }
        return text
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
