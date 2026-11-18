// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeHero.swift
//  Rivulet
//
//  The Home hero's slides: the mix of its lists (both apps), the art filter and the cap of
//  ten, and the trending and watchlist sources that look titles up on every server (iOS).
//

import Foundation

nonisolated enum HomeHero {
    static let cap = 10

    /// A slide needs a backdrop, the show's for an episode.
    static func hasBackdrop(_ item: MediaItem) -> Bool {
        (item.artwork.backdrop ?? item.grandparentArtwork?.backdrop) != nil
    }

    /// The hero's lists in turn, each title once, at most ten.
    static func mix(_ lists: [[MediaItem]]) -> [MediaItem] {
        var seen = Set<MediaItemRef>()
        return Array(deduplicated(roundRobin(lists).filter { seen.insert($0.ref).inserted }).prefix(cap))
    }

    /// iOS's slides: the lists `sources` and the hero playlists name, mixed. With nothing in them,
    /// trending, and with no trending match, Home's rows. `allows` leaves out the libraries the hero skips
    /// (`HeroLibraries`), before the cap.
    static func items(sources: Set<HeroSources.Source>, continueWatching: [MediaItem], shelves: [MediaHub],
                      watchlist: [MediaItem], trending: [MediaItem], personal: [PersonalRow],
                      heroPins: [HomePlaylistPins.Pin], isRowHidden: (MediaHub) -> Bool = { _ in false },
                      allows: (MediaItem) -> Bool = { _ in true }) -> [MediaItem] {
        let trending = trending.filter(allows)
        let shelves = shelves.map { hub in
            MediaHub(id: hub.id, providerID: hub.providerID, title: hub.title, style: hub.style,
                     items: hub.items.filter(allows), pagingKey: hub.pagingKey, isPromoted: hub.isPromoted)
        }
        var lists: [[MediaItem]] = []
        for source in HeroSources.Source.allCases where sources.contains(source) {
            switch source {
            case .trending: lists.append(trending)
            case .continueWatching:
                lists.append(continueWatching.prefix(HomeFeed.railLimit).filter { hasBackdrop($0) && allows($0) })
            case .recentlyAdded: lists.append(recentlyAdded(shelves, isRowHidden: isRowHidden))
            case .watchlist: lists.append(watchlist.filter(allows))
            case .favoriteMovies, .favoriteShows:
                let kind: MediaLibrary.LibraryKind = source == .favoriteShows ? .shows : .movies
                lists.append(roundRobin(PersonalRows.favoriteItems(personal, kind)).filter { hasBackdrop($0) && allows($0) })
            }
        }
        lists += heroPins.map { PersonalRows.playlistItems(personal, $0).filter { hasBackdrop($0) && allows($0) } }
        let mixed = mix(lists)
        if !mixed.isEmpty { return mixed }
        return trending.isEmpty ? rowItems(shelves) : trending
    }

    /// One item from each recently added row in turn, so no library's additions bury another's.
    static func recentlyAdded(_ shelves: [MediaHub], isRowHidden: (MediaHub) -> Bool = { _ in false }) -> [MediaItem] {
        let rows = shownOrAll(shelves.filter { $0.id.lowercased().contains("recentlyadded") }, isHidden: isRowHidden)
        return roundRobin(rows.map { Array($0.items.prefix(HomeFeed.railLimit)) }).filter(hasBackdrop)
    }

    /// The rows Home shows; all of them when every one is hidden, so the hero can stand in for the rows (#597).
    static func shownOrAll<T>(_ rows: [T], isHidden: (T) -> Bool) -> [T] {
        let shown = rows.filter { !isHidden($0) }
        return shown.isEmpty ? rows : shown
    }

    /// Up to six featured items, two per row, one per show.
    static func rowItems(_ shelves: [MediaHub]) -> [MediaItem] {
        var seen = Set<MediaItemRef>()
        return Array(shelves
            .flatMap { $0.items.prefix(HomeFeed.railLimit).prefix(2) }
            .filter(hasBackdrop)
            .filter { seen.insert($0.grandparentRef ?? $0.ref).inserted }
            .prefix(6))
    }

    /// A library page's slides: its rows' leading titles, Continue Watching left out.
    static func libraryItems(_ rows: [MediaHub]) -> [MediaItem] {
        rowItems(rows.filter { !$0.isContinueWatchingFamily })
    }

    /// Each title once, the first copy standing (the selected server's, since it comes first).
    /// Two copies are one title when they share an external id (per kind: a movie and a show can share a
    /// TMDB number) or, failing that, a kind, a normalized title and a year.
    static func deduplicated(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        return items.filter { item in
            var keys = ["tmdb", "imdb", "tvdb", "plex"].compactMap { source in
                item.externalIDs?[source].map { "\(item.kind.rawValue):\(source):\($0)" }
            }
            if let year = item.year {
                let title = item.title.lowercased().filter { $0.isLetter || $0.isNumber }
                keys.append("\(item.kind.rawValue):\(title):\(year)")
            }
            guard !keys.contains(where: seen.contains) else { return false }
            seen.formUnion(keys)
            return true
        }
    }

    /// The lists' first elements, then their seconds, and so on.
    static func roundRobin<T>(_ lists: [[T]]) -> [T] {
        (0..<(lists.map(\.count).max() ?? 0)).flatMap { i in lists.compactMap { i < $0.count ? $0[i] : nil } }
    }
}

/// Looks the hero's titles up on every server and remembers the answer: trending for an hour,
/// the watchlist for as long as its entries are the same.
@MainActor
final class HomeHeroSources {
    private static let lifetime: TimeInterval = 3600
    /// TMDB's trending movies and shows, interleaved. Replaced in tests.
    var trendingTitles: () async -> [TitleMatch] = {
        async let movies = TMDBDiscoverService.shared.fetchSection(.movieTrending)
        async let shows = TMDBDiscoverService.shared.fetchSection(.tvTrending)
        return TrendingMatch.interleave(movies: await movies, shows: await shows).map(TitleMatch.init)
    }

    /// Each server's matches as found, so what `shown` leaves out is dropped before the cap, and
    /// before the copies of a title on two servers become one.
    private var trendingCache: (servers: [String], lists: [[MediaItem]], at: Date)?
    private var watchlistCache: (key: [String], servers: [String], lists: [[MediaItem]])?

    func reset() {
        trendingCache = nil
        watchlistCache = nil
    }

    /// `shown` leaves out titles Home or the hero skips (a hidden or left-out library).
    func trending(providers: [any MediaProvider], shown: (MediaItem) -> Bool = { _ in true }) async -> [MediaItem] {
        let servers = providers.map(\.id)
        if let cache = trendingCache, cache.servers == servers, Date.now.timeIntervalSince(cache.at) < Self.lifetime {
            return Self.pick(cache.lists, shown)
        }
        let titles = await trendingTitles()
        guard !titles.isEmpty else { return [] }
        let lists = await owned(titles, providers)
        if lists.contains(where: { !$0.isEmpty }) { trendingCache = (servers, lists, .now) }
        return Self.pick(lists, shown)
    }

    /// The watchlist's entries that any server owns, in watchlist order. `key` names the entries
    /// (their ids), so a changed list asks again.
    func watchlist(titles: [TitleMatch], key: [String], providers: [any MediaProvider],
                   shown: (MediaItem) -> Bool = { _ in true }) async -> [MediaItem] {
        let servers = providers.map(\.id)
        if let cache = watchlistCache, cache.key == key, cache.servers == servers { return Self.pick(cache.lists, shown) }
        let lists = await owned(titles, providers)
        watchlistCache = (key, servers, lists)
        return Self.pick(lists, shown)
    }

    /// Each server's matches with a backdrop, in provider order.
    private func owned(_ titles: [TitleMatch], _ providers: [any MediaProvider]) async -> [[MediaItem]] {
        let lists = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    let found = (try? await provider.ownedItems(matching: titles, limit: titles.count)) ?? []
                    return (index, found.filter(HomeHero.hasBackdrop))
                }
            }
            return await group.reduce(into: [Int: [MediaItem]]()) { $0[$1.0] = $1.1 }
        }
        return providers.indices.map { lists[$0] ?? [] }
    }

    /// The shown matches, one server after another in turn, each title once, at most ten.
    private static func pick(_ lists: [[MediaItem]], _ shown: (MediaItem) -> Bool) -> [MediaItem] {
        Array(HomeHero.deduplicated(HomeHero.roundRobin(lists.map { $0.filter(shown) })).prefix(HomeHero.cap))
    }
}
