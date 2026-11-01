// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  YearInReview.swift
//  Rivulet
//
//  A profile's year on its Plex server, built from the server's own history
//  and statistics. Plays come from history, hours from statistics: history
//  carries no durations, and statistics counts carry the same bulk-logged
//  plays history does.
//

import Foundation

nonisolated struct YearInReview: Equatable, Sendable {
    /// A title and the art the page shows for it. Art values are Plex paths.
    struct Title: Equatable, Sendable {
        let name: String
        var detail: String? = nil
        var art: String? = nil
        var poster: String? = nil
        var plays = 0
        var date: Date? = nil
    }

    struct Hours: Equatable, Sendable {
        var tv: Double = 0
        var movies: Double = 0
        var music: Double = 0
        var video: Double { tv + movies }
    }

    struct Day: Equatable, Sendable {
        let date: Date
        let hours: Double
        let topTitle: String?
    }

    let year: Int
    /// `date` is when it was played.
    let firstPlay: Title?
    let hours: Hours
    /// `detail` is "N episodes across S seasons".
    let topShow: Title?
    let topMovies: [Title]
    let biggestDay: Day?
    /// Video plays by the hour they ended, 0 to 23.
    let playsByHour: [Int]
    let topArtist: Title?
    let movieCount: Int
    let episodeCount: Int
    let songCount: Int

    // MARK: - Rules

    /// A video play logged this soon after the previous one is a bulk import, not a watch.
    static let bulkGap = 120
    static let minimumVideoHours = 10.0
    static let minimumMusicHours = 5.0
    static let topMovieCount = 5

    /// The year the card shows on `date`: December shows the year so far, January 1 to 15 the year
    /// just ended, and the rest of the year nothing.
    static func year(showingOn date: Date, calendar: Calendar = .current) -> Int? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        if month == 12 { return year }
        if month == 1, day <= 15 { return year - 1 }
        return nil
    }

    static func interval(of year: Int, calendar: Calendar = .current) -> DateInterval? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        return calendar.dateInterval(of: .year, for: start)
    }

    /// Drops video plays logged within `bulkGap` of the previous video play. Input sorted by time.
    static func dropBulkPlays(_ plays: [PlexHistoryEntry]) -> [PlexHistoryEntry] {
        var last: Int?
        return plays.filter { play in
            guard isVideo(play), let at = play.viewedAt else { return true }
            defer { last = at }
            if let last, at - last < bulkGap { return false }
            return true
        }
    }

    private static func isVideo(_ play: PlexHistoryEntry) -> Bool {
        play.type == "movie" || play.type == "episode"
    }

    /// Nil when the year holds too little to show.
    static func build(
        plays allPlays: [PlexHistoryEntry],
        stats allStats: [PlexMediaStatistic],
        year: Int,
        accountID: Int?,
        calendar: Calendar = .current
    ) -> YearInReview? {
        guard let interval = interval(of: year, calendar: calendar) else { return nil }
        func inYear(_ seconds: Int?) -> Bool {
            guard let seconds else { return false }
            let date = Date(timeIntervalSince1970: TimeInterval(seconds))
            return date >= interval.start && date < interval.end
        }
        let mine = { (id: Int?) in accountID == nil || id == accountID }

        let plays = dropBulkPlays(allPlays
            .filter { inYear($0.viewedAt) && mine($0.accountID) }
            .sorted { ($0.viewedAt ?? 0) < ($1.viewedAt ?? 0) })
        let stats = allStats.filter { inYear($0.at) && mine($0.accountID) }

        var hours = Hours()
        var videoSecondsByDay: [Date: Int] = [:]
        for stat in stats {
            let seconds = stat.duration ?? 0
            switch stat.metadataType {
            case 1: hours.movies += Double(seconds) / 3600
            case 4: hours.tv += Double(seconds) / 3600
            case 10: hours.music += Double(seconds) / 3600
            default: continue
            }
            if stat.metadataType == 1 || stat.metadataType == 4 {
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(stat.at)))
                videoSecondsByDay[day, default: 0] += seconds
            }
        }

        let episodes = plays.filter { $0.type == "episode" }
        let movies = plays.filter { $0.type == "movie" }
        let tracks = plays.filter { $0.type == "track" }
        let video = plays.filter(isVideo)

        let topShow = top(episodes, key: { $0.grandparentKey ?? $0.grandparentTitle }).map { group in
            let seasons = Set(group.compactMap(\.parentIndex)).count
            let latest = group.last
            return Title(name: latest?.grandparentTitle ?? "",
                         detail: "\(group.count) episodes" + (seasons > 1 ? " across \(seasons) seasons" : ""),
                         art: group.last { $0.grandparentArt != nil }?.grandparentArt,
                         poster: latest?.grandparentThumb,
                         plays: group.count)
        }

        let topMovies = ranked(movies, key: { $0.ratingKey ?? $0.title }).prefix(topMovieCount).map { group in
            Title(name: group.last?.title ?? "", poster: group.last { $0.thumb != nil }?.thumb, plays: group.count)
        }

        let firstPlay = video.first.flatMap { play -> Title? in
            guard let at = play.viewedAt else { return nil }
            let isEpisode = play.type == "episode"
            return Title(name: (isEpisode ? play.grandparentTitle : play.title) ?? "",
                         detail: isEpisode ? play.title : nil,
                         art: play.grandparentArt, poster: isEpisode ? play.grandparentThumb : play.thumb,
                         date: Date(timeIntervalSince1970: TimeInterval(at)))
        }

        // Ties go to the earlier day.
        let biggestDay = videoSecondsByDay.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { entry in
            let (day, seconds) = (entry.key, entry.value)
            let onDay = video.filter {
                calendar.isDate(Date(timeIntervalSince1970: TimeInterval($0.viewedAt ?? 0)), inSameDayAs: day)
            }
            let name = top(onDay, key: { $0.grandparentTitle ?? $0.title })?.last
                .flatMap { $0.grandparentTitle ?? $0.title }
            return Day(date: day, hours: Double(seconds) / 3600, topTitle: name)
        }

        var playsByHour = [Int](repeating: 0, count: 24)
        for play in video {
            guard let at = play.viewedAt else { continue }
            playsByHour[calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(at)))] += 1
        }

        let topArtist = hours.music >= minimumMusicHours
            ? top(tracks, key: { $0.grandparentKey ?? $0.grandparentTitle }).map { group in
                Title(name: group.last?.grandparentTitle ?? "",
                      art: group.last { $0.grandparentArt != nil }?.grandparentArt,
                      poster: group.last { $0.grandparentThumb != nil }?.grandparentThumb,
                      plays: group.count)
            }
            : nil

        guard hours.video >= minimumVideoHours, topShow != nil || !topMovies.isEmpty else { return nil }
        return YearInReview(year: year, firstPlay: firstPlay, hours: hours, topShow: topShow,
                            topMovies: Array(topMovies), biggestDay: biggestDay, playsByHour: playsByHour,
                            topArtist: topArtist, movieCount: movies.count, episodeCount: episodes.count,
                            songCount: tracks.count)
    }

    /// Groups by `key`, most plays first, ties to the most recently played. Each group is in play order.
    private static func ranked(_ plays: [PlexHistoryEntry],
                               key: (PlexHistoryEntry) -> String?) -> [[PlexHistoryEntry]] {
        var groups: [String: [PlexHistoryEntry]] = [:]
        for play in plays {
            guard let k = key(play) else { continue }
            groups[k, default: []].append(play)
        }
        return groups.values.sorted {
            ($0.count, $0.last?.viewedAt ?? 0) > ($1.count, $1.last?.viewedAt ?? 0)
        }
    }

    private static func top(_ plays: [PlexHistoryEntry],
                            key: (PlexHistoryEntry) -> String?) -> [PlexHistoryEntry]? {
        ranked(plays, key: key).first
    }
}

// MARK: - Pages

extension YearInReview {
    enum Page: Equatable, Sendable {
        case intro, started(Title), hours, topShow(Title), topMovies, biggestDay(Day), whenYouWatch
        case topArtist(Title), outro
    }

    /// The pages in order, leaving out any with nothing to say.
    var pages: [Page] {
        var pages: [Page] = [.intro]
        if let firstPlay { pages.append(.started(firstPlay)) }
        pages.append(.hours)
        if let topShow { pages.append(.topShow(topShow)) }
        if !topMovies.isEmpty { pages.append(.topMovies) }
        if let biggestDay { pages.append(.biggestDay(biggestDay)) }
        if watchTime != nil { pages.append(.whenYouWatch) }
        if let topArtist { pages.append(.topArtist(topArtist)) }
        pages.append(.outro)
        return pages
    }

    enum PartOfDay: String, Sendable {
        case morning, afternoon, evening, lateNight = "late-night"
    }

    /// The part of the day with the most video plays, and the busiest hour. Nil with no plays.
    var watchTime: (part: PartOfDay, peakHour: Int)? {
        guard let peak = playsByHour.indices.max(by: { playsByHour[$0] < playsByHour[$1] }),
              playsByHour[peak] > 0 else { return nil }
        func part(_ hour: Int) -> PartOfDay {
            switch hour {
            case 5...11: return .morning
            case 12...16: return .afternoon
            case 17...21: return .evening
            default: return .lateNight
            }
        }
        var totals: [PartOfDay: Int] = [:]
        for (hour, plays) in playsByHour.enumerated() { totals[part(hour), default: 0] += plays }
        let busiest = [PartOfDay.morning, .afternoon, .evening, .lateNight].max { totals[$0, default: 0] < totals[$1, default: 0] }
        return (busiest ?? part(peak), peak)
    }
}

// MARK: - Loading

/// Fetches and caches each profile's year for the session. Nothing is written to disk
/// except which years a profile removed from Home.
@MainActor
enum YearInReviewStore {
    private static var results: [String: YearInReview?] = [:]
    private static var inFlight: [String: Task<YearInReview?, Never>] = [:]

    private static func key(token: String, year: Int) -> String { "\(year)|\(token)" }

    /// The finished result, or nil (outer) while it has never been loaded.
    static func cached(token: String, year: Int) -> YearInReview?? {
        results[key(token: token, year: year)]
    }

    /// The server owner's account id on their own server.
    static let ownerAccountID = 1

    /// Loads once per token and year; a failure (401 for a shared server, say) reads as nothing to show.
    /// A token that sees more than one account is the owner's, which is account 1; anyone else's
    /// is scoped to its own rows by the server.
    static func load(serverURL: String, token: String, year: Int) async -> YearInReview? {
        let key = key(token: token, year: year)
        if let done = results[key] { return done }
        if let running = inFlight[key] { return await running.value }
        let task = Task<YearInReview?, Never> {
            guard let interval = YearInReview.interval(of: year) else { return nil }
            let network = PlexNetworkManager.shared
            do {
                let (s, accounts) = try await network.getDailyMediaStatistics(serverURL: serverURL, authToken: token,
                                                                              since: interval.start)
                let accountID = accounts.count > 1 ? ownerAccountID : nil
                let p = try await network.getWatchHistory(serverURL: serverURL, authToken: token,
                                                          since: interval.start, until: interval.end,
                                                          accountID: accountID)
                return await Task.detached(priority: .utility) {
                    YearInReview.build(plays: p, stats: s, year: year, accountID: accountID)
                }.value
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        results[key] = .some(result)
        return result
    }

    // MARK: Removed from Home

    private static func removedKey(year: Int, profileID: Int) -> String {
        "yearInReviewRemoved.\(year).\(profileID)"
    }

    static func isRemoved(year: Int, profileID: Int) -> Bool {
        UserDefaults.standard.bool(forKey: removedKey(year: year, profileID: profileID))
    }

    static func remove(year: Int, profileID: Int) {
        UserDefaults.standard.set(true, forKey: removedKey(year: year, profileID: profileID))
    }
}
