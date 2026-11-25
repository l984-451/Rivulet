// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Seerr's request statuses and the rules for what can be requested.
// Pure values, so the status logic is tested without a server.

import Foundation

/// Seerr's `MediaStatus` (server/constants/media.ts). Its published OpenAPI spec is out of date:
/// 6 is Blocklisted and 7 Deleted in the server code, which is what the server sends.
nonisolated enum SeerrMediaStatus: Int, Sendable {
    case unknown = 1, pending, processing, partiallyAvailable, available, blocklisted, deleted
}

/// Seerr's `MediaRequestStatus`.
nonisolated enum SeerrRequestStatus: Int, Sendable {
    case pending = 1, approved, declined, failed, completed
}

/// What the Apple TV can do with a title or a season.
nonisolated enum SeerrAvailability: Equatable, Sendable {
    case requestable
    case requested
    case processing
    case partiallyAvailable
    case available
    case blocklisted

    /// No status, Unknown and Deleted all mean nothing is on its way, so it can be requested again.
    init(mediaStatus: SeerrMediaStatus?) {
        switch mediaStatus {
        case nil, .unknown, .deleted: self = .requestable
        case .pending: self = .requested
        case .processing: self = .processing
        case .partiallyAvailable: self = .partiallyAvailable
        case .available: self = .available
        case .blocklisted: self = .blocklisted
        }
    }

    /// A movie, or a season, that can still be asked for.
    var canRequest: Bool { self == .requestable }

    /// The tile badge. Requestable titles carry none: the section's header says what they are.
    var badge: String? {
        switch self {
        case .requestable: nil
        case .requested: String(localized: "Requested")
        case .processing: String(localized: "Processing")
        case .partiallyAvailable: String(localized: "Partially Available")
        case .available: String(localized: "Available")
        case .blocklisted: String(localized: "Unavailable")
        }
    }
}

/// A movie or show from Seerr's search.
nonisolated struct SeerrTitle: Equatable, Sendable {
    enum Kind: String, Sendable { case movie, tv }

    let tmdbID: Int
    let kind: Kind
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    /// "2021-10-22" for a movie, the first air date for a show.
    let releaseDate: String?
    var availability: SeerrAvailability

    /// Search shows only what is worth requesting: a title Seerr already reports as Available is
    /// in the library, so the library's own results show it.
    static func requestable(_ titles: [SeerrTitle]) -> [SeerrTitle] {
        titles.filter { $0.availability != .available }
    }
}

/// A show as its detail page needs it: its own state and its seasons'.
nonisolated struct SeerrShow: Equatable, Sendable {
    let availability: SeerrAvailability
    let seasons: [SeerrSeason]

    /// What the show's Request pill says: Request while any season can still be asked for,
    /// otherwise the show's own state.
    var pillState: SeerrAvailability {
        if !SeerrSeasons.requestableNumbers(seasons).isEmpty { return .requestable }
        return availability == .requestable ? .requested : availability
    }
}

/// One season of a show, with what Seerr knows about it.
nonisolated struct SeerrSeason: Equatable, Sendable {
    let number: Int
    let name: String
    let episodeCount: Int?
    let availability: SeerrAvailability
}

nonisolated enum SeerrSeasons {
    /// Each season's state, from the show's seasons, the media's per-season status, and the
    /// requests that name it. Specials (season 0) are left out, as Seerr's own page does.
    /// A season named in a live request (pending or approved) is Requested even before Seerr's
    /// media record catches up; a declined or failed request does not hold it.
    static func merge(seasons: [(number: Int, name: String, episodeCount: Int?)],
                      mediaStatus: [Int: SeerrMediaStatus],
                      requested: Set<Int>) -> [SeerrSeason] {
        seasons
            .filter { $0.number > 0 }
            .sorted { $0.number < $1.number }
            .map { season in
                var availability = SeerrAvailability(mediaStatus: mediaStatus[season.number])
                if availability == .requestable, requested.contains(season.number) { availability = .requested }
                return SeerrSeason(number: season.number, name: season.name,
                                   episodeCount: season.episodeCount, availability: availability)
            }
    }

    /// The seasons "All Seasons" asks for: only those not already on their way or here.
    static func requestableNumbers(_ seasons: [SeerrSeason]) -> [Int] {
        seasons.filter(\.availability.canRequest).map(\.number)
    }

    /// The show's state after a request for `numbers`: Requested when nothing is left to ask for.
    static func availability(after numbers: [Int], of seasons: [SeerrSeason],
                             was current: SeerrAvailability) -> SeerrAvailability {
        let left = requestableNumbers(seasons).filter { !numbers.contains($0) }
        if !left.isEmpty { return current }
        return current == .requestable ? .requested : current
    }
}

/// One quality profile on one Radarr or Sonarr server that Seerr requests through.
nonisolated struct SeerrQualityOption: Equatable, Sendable {
    let serverID: Int
    let profileID: Int
    let name: String
    let is4K: Bool
    /// Seerr's own choice: the default server's active profile, what a request gets when it names none.
    let isDefault: Bool

    struct Server: Sendable {
        let id: Int
        let is4K: Bool
        let isDefault: Bool
        let activeProfileID: Int?
    }

    /// Every profile of every server, Seerr's default first, then the rest of the standard
    /// servers by name, then 4K's. A server whose profiles couldn't be read is left out.
    static func options(servers: [Server], profiles: [Int: [(id: Int, name: String)]]) -> [SeerrQualityOption] {
        var options: [SeerrQualityOption] = []
        for server in servers {
            for profile in profiles[server.id] ?? [] {
                options.append(SeerrQualityOption(
                    serverID: server.id, profileID: profile.id, name: profile.name, is4K: server.is4K,
                    isDefault: server.isDefault && !server.is4K && server.activeProfileID == profile.id))
            }
        }
        return options.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.is4K != b.is4K { return !a.is4K }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The menu row: "HD-1080p", "Ultra-HD · 4K", with Seerr's default marked.
    var title: String {
        let base = is4K ? String(localized: "\(name) · 4K") : name
        return isDefault ? String(localized: "\(base) (Default)") : base
    }
}
