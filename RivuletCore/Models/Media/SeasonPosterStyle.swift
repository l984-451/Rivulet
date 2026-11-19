// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

// Seasons (Settings > Appearance > Details): a show with more than one season lists its
// seasons as posters (choose one to open its page), or as the pills over one long episode
// row. The stored value and the pure rules live here so the row, the page and the tests agree.

import Foundation

nonisolated enum SeasonPosterStyle {

    /// Bool; absent = on (season posters).
    static let enabledKey = "detailSeasonPosters"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Posters only when there is a real choice. Specials count as a season, as the pills count them.
    static func showsPosters(enabled: Bool, seasonCount: Int, pageKind: MediaKind) -> Bool {
        enabled && seasonCount > 1 && pageKind != .season
    }

    /// Index of the season holding `ref` (the next or current episode's parent), else 0.
    static func selectedIndex(seasons: [MediaItemRef], holding ref: MediaItemRef?) -> Int {
        guard let ref else { return 0 }
        return seasons.firstIndex { $0.itemID == ref.itemID } ?? 0
    }

    /// First visible column so `index` is on screen, without scrolling past the end of the row.
    static func firstColumn(toShow index: Int, count: Int, fullCount: Int) -> Int {
        min(max(0, index - (fullCount - 1)), max(0, count - fullCount))
    }

    /// What the poster's corner shows. (No case named `none`: it clashes with Optional.)
    enum Mark: Equatable {
        case unwatched(Int)
        case watched
        case hidden
    }

    static func mark(progress: ChildProgress?, isPlayed: Bool) -> Mark {
        if let progress, progress.total > progress.played {
            return .unwatched(progress.total - progress.played)
        }
        if let progress, progress.total > 0, progress.played >= progress.total { return .watched }
        if isPlayed { return .watched }
        return .hidden
    }
}
