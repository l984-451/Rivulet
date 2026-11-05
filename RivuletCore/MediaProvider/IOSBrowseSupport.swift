// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IOSBrowseSupport.swift
//  Rivulet
//
//  Small rules the iOS browse screens share: which servers' items play, the Plex bridge the
//  player and downloads still take, show and season stubs, order and watchlist membership.
//

import Foundation
import Synchronization

/// Which servers' items the iOS player can play. A Play control shows only where this says yes;
/// it is the one gate.
nonisolated enum IOSPlaybackGate {
    static let playableKinds: Set<MediaProviderKind> = [.plex, .jellyfin, .emby]

    static func canPlay(_ ref: MediaItemRef) -> Bool {
        MediaProviderKind(providerID: ref.providerID).map(playableKinds.contains) ?? false
    }
}

/// Which servers' items the iOS app can download. A Plex ref needs a server still signed in, since
/// its rating key means nothing on another one.
nonisolated enum IOSDownloadGate {
    static func canDownload(_ ref: MediaItemRef) -> Bool {
        guard let kind = MediaProviderKind(providerID: ref.providerID) else { return false }
        return kind == .plex ? ref.hasKnownPlexServer : true
    }
}

/// Which Plex server a Plex ref names, against the registry's current servers.
nonisolated enum PlexRoute: Equatable, Sendable {
    case selected
    case extra(String)
    /// A Plex id no current server owns; its key must not be tried on any other server.
    case unknown
}

extension MediaItemRef {
    /// The Plex server the ref belongs to; nil for another kind of server.
    nonisolated var plexRoute: PlexRoute? {
        guard providerID.hasPrefix("plex:") else { return nil }
        if Self.selectedPlexIDs.withLock({ $0.contains(providerID) }) { return .selected }
        if Self.extraPlexIDs.withLock({ $0.contains(providerID) }) { return .extra(String(providerID.dropFirst("plex:".count))) }
        return .unknown
    }

    /// A Plex ref whose server is still signed in, so its rating key can be resolved on that server.
    nonisolated var hasKnownPlexServer: Bool { plexRoute.map { $0 != .unknown } ?? false }

    /// `PlexMetadata.serverID` for the item's server: nil for the selected one, else its machine id.
    nonisolated var plexServerID: String? {
        if case .extra(let id)? = plexRoute { id } else { nil }
    }
}

extension MediaItemRef {
    /// Names the item for "this one is being prepared": `PlexMetadata.id`'s spelling on Plex.
    nonisolated var actionKey: String { plexServerID.map { "\($0)/\(itemID)" } ?? itemID }
}

extension MediaKind {
    /// Plex's `type` for a kind the iOS menus act on.
    nonisolated var plexType: String? {
        switch self {
        case .movie: "movie"
        case .show: "show"
        case .season: "season"
        case .episode: "episode"
        default: nil
        }
    }
}

extension MediaItem {
    /// The item as the Plex player and downloads take it. They load the rest by rating key; this
    /// carries what lists and the queue panel draw (titles, numbers, art paths, watch state).
    nonisolated var plexStub: PlexMetadata {
        let isEpisode = kind == .episode
        var stub = PlexMetadata(
            ratingKey: ref.itemID, type: kind.plexType, title: title, summary: overview, year: year,
            thumb: Self.serverPath(artwork.thumbnail ?? artwork.poster), art: Self.serverPath(artwork.backdrop),
            duration: runtime.map { Int($0 * 1000) },
            parentRatingKey: parentRef?.itemID, parentTitle: kind == .season ? seriesTitle : nil,
            parentIndex: isEpisode ? seasonNumber : nil, parentThumb: Self.serverPath(parentArtwork?.poster),
            grandparentRatingKey: grandparentRef?.itemID, grandparentTitle: isEpisode ? seriesTitle : nil,
            grandparentThumb: Self.serverPath(grandparentArtwork?.poster), grandparentArt: Self.serverPath(grandparentArtwork?.backdrop),
            index: isEpisode ? episodeNumber : seasonNumber,
            viewCount: userState.isPlayed ? 1 : nil, viewOffset: userState.viewOffset > 0 ? Int(userState.viewOffset * 1000) : nil,
            lastViewedAt: userState.lastViewedAt.map { Int($0.timeIntervalSince1970) })
        stub.serverID = ref.plexServerID
        return stub
    }

    /// A server artwork URL as the path Plex lists carry: no host, no token. The metadata CDN's stay absolute.
    private nonisolated static func serverPath(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if components.host?.hasSuffix("plex.tv") == true { return url.absoluteString }
        let query = (components.queryItems ?? []).filter { $0.name != "X-Plex-Token" }
        components.scheme = nil
        components.host = nil
        components.port = nil
        components.queryItems = query.isEmpty ? nil : query
        return components.string
    }

    /// The show an episode or season belongs to, enough for its detail page to load the rest.
    nonisolated var showStub: MediaItem? {
        let source: (ref: MediaItemRef?, art: MediaArtwork?)
        switch kind {
        case .episode: source = (grandparentRef, grandparentArtwork)
        case .season: source = (parentRef, parentArtwork)
        default: return nil
        }
        guard let ref = source.ref else { return nil }
        return stub(ref: ref, kind: .show, title: seriesTitle ?? title, art: source.art)
    }

    /// An episode's season.
    nonisolated var seasonStub: MediaItem? {
        guard kind == .episode, let ref = parentRef else { return nil }
        return MediaItem(
            ref: ref, kind: .season, title: seasonNumber.map { String(localized: "Season \($0)") } ?? title, sortTitle: nil,
            overview: nil, year: nil, runtime: nil, parentRef: grandparentRef, grandparentRef: nil, seriesTitle: seriesTitle,
            episodeNumber: nil, seasonNumber: seasonNumber, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: parentArtwork ?? MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: grandparentArtwork, grandparentArtwork: nil)
    }

    private nonisolated func stub(ref: MediaItemRef, kind: MediaKind, title: String, art: MediaArtwork?) -> MediaItem {
        MediaItem(
            ref: ref, kind: kind, title: title, sortTitle: nil, overview: nil, year: nil, runtime: nil,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: art ?? MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
    }

    /// Watched with no rewatch under way. A resume point outranks the watched flag (#270), so a
    /// title being watched again is not watched yet: the menu offers Mark as Watched, not Unwatched.
    nonisolated var countsAsWatched: Bool { userState.isPlayed && watchProgress == nil }

    /// The movie or show whose clear logo the item wears: an episode's or season's show.
    nonisolated var logoOwner: MediaItemRef {
        switch kind {
        case .episode: grandparentRef ?? ref
        case .season: parentRef ?? ref
        default: ref
        }
    }

    /// Resume point first, then the first unwatched, then the first.
    nonisolated static func nextUp(in episodes: [MediaItem]) -> MediaItem? {
        episodes.first(where: \.isInProgress) ?? episodes.first(where: { !$0.countsAsWatched }) ?? episodes.first
    }
}

extension Array where Element == MediaItem {
    /// By episode or season number; items without one keep the server's order.
    nonisolated func sortedByNumber() -> [MediaItem] {
        func number(_ item: MediaItem) -> Int { item.episodeNumber ?? item.seasonNumber ?? 0 }
        return enumerated().sorted { (number($0.element), $0.offset) < (number($1.element), $1.offset) }.map(\.element)
    }
}

extension LibrarySortOption {
    /// The sort the provider seam takes. Resolution is not offered for provider libraries.
    nonisolated var seamSort: SortOption {
        switch self {
        case .addedAtDesc: .addedAtDesc
        case .addedAtAsc: .addedAtAsc
        case .titleAsc: .titleAsc
        case .titleDesc: .titleDesc
        case .releaseDateDesc: .releaseDateDesc
        case .releaseDateAsc: .releaseDateAsc
        case .ratingDesc: .ratingDesc
        case .lastEpisodeAddedDesc: .lastContentAddedDesc
        case .resolutionDesc, .resolutionAsc: .addedAtDesc
        }
    }
}

/// Whether a title is on the Plex watchlist, answered without a request from the ids a list
/// response carries. An episode or season stands for its show, whose Plex guid the Plex mapper
/// carries under `showPlex`.
nonisolated enum WatchlistMembership {
    static func canAnswer(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie, .show: true
        case .episode, .season: item.externalIDs?["showPlex"] != nil
        default: false
        }
    }

    /// "tmdb://603"-style guids for the ids a movie or show holds, in the order Discover prefers.
    static func guids(for item: MediaItem) -> [String] {
        guard item.kind == .movie || item.kind == .show else { return [] }
        return ["tmdb", "imdb", "tvdb"].compactMap { source in item.externalIDs?[source].map { "\(source)://\($0)" } }
    }

    static func isListed(_ item: MediaItem, plexGUIDs: Set<String>, contains: (String) -> Bool) -> Bool {
        guard canAnswer(item) else { return false }
        if item.kind == .episode || item.kind == .season {
            return item.externalIDs?["showPlex"].map(plexGUIDs.contains) ?? false
        }
        if let plex = item.externalIDs?["plex"], plexGUIDs.contains(plex) { return true }
        return guids(for: item).contains(where: contains)
    }
}

extension Array {
    nonisolated var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

/// A track's language as a person reads it. Plex names it ("English"); Jellyfin and Emby give a code ("eng").
nonisolated enum LanguageLabel {
    static func display(_ raw: String, locale: Locale = .current) -> String {
        guard raw.count <= 3, raw.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return raw }
        return locale.localizedString(forLanguageCode: raw) ?? raw
    }
}

extension Array where Element == MediaLibrary {
    /// The iPad sidebar's order: servers as given, movies before shows, then by title.
    nonisolated func sidebarOrder(servers: [String]) -> [MediaLibrary] {
        func rank(_ library: MediaLibrary) -> Int { servers.firstIndex(of: library.providerID) ?? servers.count }
        return sorted { lhs, rhs in
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            if lhs.kind != rhs.kind { return lhs.kind == .movies }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

/// The sorts the iOS library page offers, in its order.
nonisolated enum IOSLibrarySorts {
    static let all: [LibrarySortOption] = [.titleAsc, .addedAtDesc, .releaseDateDesc, .ratingDesc]

    /// Plex answers every one of them for a movie or TV library; another server offers what it can apply.
    static func menu(offered: [LibrarySortOption], isPlex: Bool) -> [LibrarySortOption] {
        isPlex ? all : all.filter { offered.contains($0) }
    }
}

extension MediaItemDetail {
    /// Trailers first, then the other extras by kind, each kind in the server's order.
    nonisolated var orderedExtras: [Extra] {
        extras.enumerated().sorted { ($0.element.subtype, $0.offset) < ($1.element.subtype, $1.offset) }.map(\.element)
    }
}

extension PlexProvider {
    /// "More Like This": the similar-title hubs of `/related` flattened and deduped, uncapped, without the
    /// collection and same-actor rows (`splitRelated` serves the tvOS detail page).
    nonisolated static func similarItems(hubs: [PlexHub], currentRatingKey: String) -> [PlexMetadata] {
        var seen: Set<String> = [currentRatingKey]
        return hubs.filter { ($0.hubIdentifier ?? "").contains("similar") }
            .flatMap { $0.Metadata ?? [] }
            .filter { item in item.ratingKey.map { seen.insert($0).inserted } ?? true }
    }
}

extension PlayQueue where Entry == MediaItem {
    /// The same queue as the player takes it. Rows are named by position, so a title twice is two entries.
    nonisolated var playlistQueue: PlayQueue<PlaylistEntry> {
        let entries = entries.enumerated().map { PlaylistEntry(entryID: String($0.offset), item: $0.element) }
        return PlayQueue<PlaylistEntry>(entries: entries, startingAt: index)!
    }
}
