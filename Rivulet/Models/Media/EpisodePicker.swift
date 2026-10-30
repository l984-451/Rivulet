// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Which episode Play means on a season or show. Shared by the carousel and home heroes.

import Foundation

enum EpisodePicker {

    /// The episode Play starts in a season: the one in progress, else the first unplayed,
    /// else the first (a watched season restarts). Nil only when `episodes` is empty.
    static func firstUnplayed(in episodes: [MediaItem]) -> MediaItem? {
        let ordered = inPlaybackOrder(episodes)
        return ordered.first(where: { $0.userState.isInProgress })
            ?? ordered.first(where: { !$0.userState.isPlayed })
            ?? ordered.first
    }

    /// What Play on `item` starts: itself for a movie or episode, On Deck for a show (else the
    /// first season's pick), the pick for a season. Nil means the caller plays `item` as-is.
    /// The Play button and its title both use it, so they always agree.
    static func resolvePlayTarget(
        for item: MediaItem, provider: MediaProvider
    ) async -> MediaItem? {
        guard item.isAvailable != false else { return nil }
        switch item.kind {
        case .movie, .episode:
            return item
        case .show:
            if let onDeck = try? await provider.fullDetail(for: item.ref).nextEpisode {
                return onDeck
            }
            guard let firstSeason = try? await provider.children(of: item.ref).first
            else { return nil }
            let episodes = (try? await provider.children(of: firstSeason.ref)) ?? []
            return firstUnplayed(in: episodes)
        case .season:
            let episodes = (try? await provider.children(of: item.ref)) ?? []
            return firstUnplayed(in: episodes)
        default:
            return nil
        }
    }

    /// The Play button's title for `target` (what Play starts) on a page of
    /// kind `page`. A show or season page names the episode; an item's own
    /// page does not.
    static func playTitle(for target: MediaItem, on page: MediaKind) -> String {
        let onParent = (page == .show || page == .season) && target.kind == .episode
        let first = target.episodeNumber == 1 && (page == .season || target.seasonNumber == 1)
        return playTitle(
            resumes: target.isInProgress,
            watched: target.isWatched,
            season: onParent ? target.seasonNumber : nil,
            episode: onParent ? target.episodeNumber : nil,
            isFirstEpisode: onParent && first)
    }

    /// Apple's wording, our rule: a resume point (`WatchProgressPolicy`) says
    /// Resume and outranks the watched flag; a watched target says Play Again;
    /// an untouched first episode says Play First Episode; else Play.
    static func playTitle(
        resumes: Bool, watched: Bool, season: Int? = nil, episode: Int? = nil, isFirstEpisode: Bool = false
    ) -> String {
        let code = season.flatMap { s in episode.map { " S\(s), E\($0)" } } ?? ""
        if resumes { return "Resume" + code }
        if watched { return "Play Again" }
        if isFirstEpisode { return "Play First Episode" }
        return "Play" + code
    }

    /// Sorts by season then episode; an item missing either number keeps its server position.
    static func inPlaybackOrder(_ episodes: [MediaItem]) -> [MediaItem] {
        episodes.enumerated().sorted { lhs, rhs in
            let l = (lhs.element.seasonNumber, lhs.element.episodeNumber)
            let r = (rhs.element.seasonNumber, rhs.element.episodeNumber)
            guard let ls = l.0, let le = l.1, let rs = r.0, let re = r.1 else {
                return lhs.offset < rhs.offset   // stable: preserve server order
            }
            return (ls, le) < (rs, re)
        }.map(\.element)
    }
}

extension MediaUserState {
    /// A resume point and not played. The one place that adds `!isPlayed`, so On Deck moves
    /// past a finished episode. Position-only check: this type has no runtime.
    var isInProgress: Bool {
        WatchProgressPolicy.hasResumePoint(offsetSeconds: viewOffset) && !isPlayed
    }
}
