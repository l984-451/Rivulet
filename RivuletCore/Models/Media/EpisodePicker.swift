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

    /// The episode after `current`: the next by number in its season, else
    /// the first of the next season. Episodes without a number are skipped.
    static func nextEpisode(after current: MediaItem, in seasonEpisodes: [MediaItem],
                            nextSeasonEpisodes: [MediaItem]?) -> MediaItem? {
        guard let number = current.episodeNumber else { return nil }
        return byEpisodeNumber(seasonEpisodes).first { ($0.episodeNumber ?? 0) > number }
            ?? byEpisodeNumber(nextSeasonEpisodes ?? []).first
    }

    private static func byEpisodeNumber(_ episodes: [MediaItem]) -> [MediaItem] {
        episodes.filter { $0.episodeNumber != nil }
            .sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
    }

    /// The current season's episodes in order, and the episode after `current`.
    /// Specials a server lists inside a season carry their own season number
    /// and are left out, so they never become the next episode.
    static func upNext(after current: MediaItem, provider: any MediaProvider) async -> (season: [MediaItem], next: MediaItem?) {
        guard current.kind == .episode, let seasonRef = current.parentRef,
              let children = try? await provider.children(of: seasonRef) else { return ([], nil) }
        let season = byEpisodeNumber(children.filter { $0.seasonNumber == current.seasonNumber })
        var nextSeasonEpisodes: [MediaItem]?
        if let number = current.episodeNumber, let seasonNumber = current.seasonNumber,
           !season.contains(where: { ($0.episodeNumber ?? 0) > number }),
           let showRef = current.grandparentRef,
           let seasons = try? await provider.children(of: showRef),
           let nextSeason = seasons
               .filter({ ($0.seasonNumber ?? Int.min) > seasonNumber })
               .min(by: { ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0) }) {
            nextSeasonEpisodes = try? await provider.children(of: nextSeason.ref)
                .filter { $0.seasonNumber == nextSeason.seasonNumber }
        }
        return (season, nextEpisode(after: current, in: season, nextSeasonEpisodes: nextSeasonEpisodes))
    }

    /// `resolvePlayTarget` for a show whose detail, seasons and episodes are already loaded.
    static func showPlayTarget(
        nextEpisode: MediaItem?, seasons: [MediaItem], episodes: [MediaItem]
    ) -> MediaItem? {
        if let nextEpisode { return nextEpisode }
        guard let firstSeason = seasons.first else { return nil }
        return firstUnplayed(in: episodes.filter { $0.parentRef == firstSeason.ref })
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
        // One string per form, never "Resume" + code: word order differs by language.
        if let season, let episode {
            if resumes { return String(localized: "Resume S\(season), E\(episode)") }
        } else if resumes {
            return String(localized: "Resume")
        }
        if watched { return String(localized: "Play Again") }
        if isFirstEpisode { return String(localized: "Play First Episode") }
        if let season, let episode { return String(localized: "Play S\(season), E\(episode)") }
        return String(localized: "Play")
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
