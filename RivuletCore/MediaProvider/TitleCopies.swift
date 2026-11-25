// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A movie or episode to find on other servers.
nonisolated struct TitleQuery: Sendable, Equatable {
    struct Show: Sendable, Equatable {
        let title: String
        let year: Int?
        let ids: [String: String]
        let plexGUID: String?
    }

    let title: String
    let year: Int?
    /// "tmdb", "imdb", "tvdb".
    let ids: [String: String]
    /// A plex:// guid, which every Plex server indexes.
    let plexGUID: String?
    /// An episode's show and numbers; nil for a movie.
    var show: Show?
    var season: Int?
    var episode: Int?
}

extension TitleQuery {
    /// A movie from its detail, or an episode from its own and its show's.
    init?(_ detail: MediaItemDetail, show: MediaItemDetail?) {
        let item = detail.item
        switch item.kind {
        case .movie:
            self.init(title: item.title, year: item.year, ids: detail.externalIDs, plexGUID: Self.plex(detail.plexGUID))
        case .episode:
            guard let show, let season = item.seasonNumber, let episode = item.episodeNumber else { return nil }
            self.init(title: item.title, year: item.year, ids: detail.externalIDs, plexGUID: nil,
                      show: Show(title: show.item.title, year: show.item.year, ids: show.externalIDs,
                                 plexGUID: Self.plex(show.plexGUID)),
                      season: season, episode: episode)
        default:
            return nil
        }
    }

    private static func plex(_ guid: String?) -> String? {
        guid.flatMap { $0.hasPrefix("plex://") ? $0 : nil }
    }
}

/// The same movie or episode on every server the account reaches, Plex, Jellyfin or Emby, in any
/// library: what Versions lists beside the item on screen, and how Watch Together finds a room's title.
@MainActor
enum TitleCopies {
    /// One server's copies with their files, and whether every request answered.
    struct Found: Sendable {
        var details: [MediaItemDetail] = []
        var complete = true
    }

    /// Rating keys of a plex:// guid on one server; nil when the server is not Plex.
    typealias GUIDLookup = @MainActor @Sendable (_ guid: String, _ server: any MediaProvider) async throws -> [String]?

    static let plexGUIDLookup: GUIDLookup = { guid, server in
        guard let plex = server as? PlexProvider else { return nil }
        return try await PlexNetworkManager.shared.findByGuids(
            serverURL: plex.serverURL, authToken: plex.authToken, guids: [guid]).compactMap(\.ratingKey)
    }

    /// The other copies of a title, and whether every server answered (only a complete result is cached).
    struct Result: Sendable {
        var copies: [VersionPicker.Copy] = []
        var complete = true
    }

    // MARK: - One server

    /// `query` on one server, leaving out `excluding`: by plex:// guid on Plex, else a title search
    /// that `sameTitle` confirms. An episode is found through its show, by season and episode number.
    static func copies(of query: TitleQuery, on provider: any MediaProvider, excluding: Set<MediaItemRef> = [],
                       guidLookup: GUIDLookup? = nil) async -> Found {
        let lookup = guidLookup ?? plexGUIDLookup
        if let show = query.show, let season = query.season, let episode = query.episode {
            return await episodeCopies(of: show, season: season, episode: episode, on: provider,
                                       excluding: excluding, lookup: lookup)
        }
        var found = Found()
        let owned = await plexMatches(query.plexGUID, on: provider, excluding: excluding, lookup: lookup)
        if let owned, !owned.isEmpty {
            return await details(owned, on: provider)
        }
        if owned == nil { found.complete = false }
        guard let hits = try? await provider.search(query.title) else { return Found(complete: false) }
        let candidates = hits.filter {
            $0.kind == .movie && !excluding.contains($0.ref) && foldedTitle($0.title) == foldedTitle(query.title)
        }
        // The search ranks the exact title first; a handful covers remakes.
        let checked = await details(Array(candidates.prefix(4).map(\.ref)), on: provider)
        found.complete = found.complete && checked.complete
        found.details = checked.details.filter {
            sameTitle(query.title, year: query.year, ids: query.ids, as: $0.item.title, year: $0.item.year, ids: $0.externalIDs)
        }
        return found
    }

    private static func episodeCopies(of show: TitleQuery.Show, season: Int, episode: Int,
                                      on provider: any MediaProvider, excluding: Set<MediaItemRef>,
                                      lookup: GUIDLookup) async -> Found {
        var complete = true
        var shows = await plexMatches(show.plexGUID, on: provider, excluding: excluding, lookup: lookup)
        if shows == nil { complete = false }
        if shows?.isEmpty ?? true {
            guard let hits = try? await provider.search(show.title) else { return Found(complete: false) }
            shows = hits.filter {
                $0.kind == .show && !excluding.contains($0.ref)
                    && sameTitle(show.title, year: show.year, ids: [:], as: $0.title, year: $0.year, ids: [:])
            }.map(\.ref)
        }
        let walked = await inParallel(shows ?? []) { showRef -> MediaItemRef?? in
            do {
                let seasons = try await provider.children(of: showRef)
                guard let match = seasons.first(where: { $0.seasonNumber == season }) else { return .some(nil) }
                let episodes = try await provider.children(of: match.ref)
                return .some(episodes.first { $0.episodeNumber == episode }?.ref)
            } catch {
                return .none
            }
        }
        if walked.contains(where: { $0 == nil }) { complete = false }
        let refs = walked.compactMap { $0 ?? nil }.filter { !excluding.contains($0) }
        var found = await details(refs, on: provider)
        found.complete = found.complete && complete
        return found
    }

    /// The server's items with a plex:// guid, one per item (a server can hold a title in several
    /// libraries). Empty when the server is not Plex or there is no guid; nil when the request failed.
    private static func plexMatches(_ guid: String?, on provider: any MediaProvider,
                                    excluding: Set<MediaItemRef>, lookup: GUIDLookup) async -> [MediaItemRef]? {
        guard let guid else { return [] }
        let keys: [String]?
        do { keys = try await lookup(guid, provider) } catch { return nil }
        var seen = Set<MediaItemRef>()
        return (keys ?? [])
            .map { MediaItemRef(providerID: provider.id, itemID: $0) }
            .filter { !excluding.contains($0) && seen.insert($0).inserted }
    }

    private static func details(_ refs: [MediaItemRef], on provider: any MediaProvider) async -> Found {
        let answers = await inParallel(refs) { try? await provider.fullDetail(for: $0) }
        return Found(details: answers.compactMap { $0 }, complete: !answers.contains { $0 == nil })
    }

    // MARK: - Versions

    /// Every server Versions and Watch Together look on: the selected Plex server first, then the rest.
    static func servers(in registry: MediaProviderRegistry) -> [any MediaProvider] {
        [registry.plexProvider].compactMap { $0 } + registry.secondaryProviders
    }

    /// The servers that can hold another copy: the shown item's own needs a second library of its
    /// kind, any other server one. `libraries` counts them by server id; a server missing from it is asked.
    static func servers(_ servers: [any MediaProvider], besides shownOn: String,
                        libraries: [String: Int]) -> [any MediaProvider] {
        servers.filter { server in
            guard let count = libraries[server.id] else { return true }
            return count >= (server.id == shownOn ? 2 : 1)
        }
    }

    /// The servers that can hold another copy of `shown`, from every server's libraries.
    static func servers(for shown: MediaItem, libraries: [MediaLibrary],
                        registry: MediaProviderRegistry? = nil) -> [any MediaProvider] {
        let registry = registry ?? .shared
        return servers(servers(in: registry), besides: current(shown.ref, in: registry).providerID,
                       libraries: libraryCounts(libraries, holding: shown.kind))
    }

    /// Libraries that can hold a movie (or, for any other kind, a show), counted by server.
    nonisolated static func libraryCounts(_ libraries: [MediaLibrary], holding kind: MediaKind) -> [String: Int] {
        let kinds: Set<MediaLibrary.LibraryKind> = kind == .movie ? [.movies, .mixed] : [.shows, .mixed]
        return libraries.filter { kinds.contains($0.kind) }.reduce(into: [:]) { $0[$1.providerID, default: 0] += 1 }
    }

    /// A selected-server ref under the registry's current id: a restored session can mint a new one
    /// mid-session while the page keeps the old.
    static func current(_ ref: MediaItemRef, in registry: MediaProviderRegistry) -> MediaItemRef {
        guard ref.isPlex, let id = registry.plexProvider?.id else { return ref }
        return MediaItemRef(providerID: id, itemID: ref.itemID)
    }

    /// What a page's Versions plays: the movie or episode itself, or a show's or season's Play episode.
    static func subject(of page: MediaItemDetail, playTarget: MediaItem?,
                        registry: MediaProviderRegistry? = nil) async -> MediaItemDetail? {
        guard page.item.kind == .show || page.item.kind == .season else { return page }
        guard let target = playTarget,
              let provider = (registry ?? .shared).provider(for: target.ref.providerID) else { return nil }
        return try? await provider.fullDetail(for: target.ref)
    }

    /// The other copies of `subject`, a movie or an episode, on `servers`. An episode's show detail
    /// is read from its server. Lookups for the same title at once share one; complete ones are cached.
    static func versions(of subject: MediaItemDetail, on servers: [any MediaProvider],
                         registry: MediaProviderRegistry? = nil, cache: Cache? = nil,
                         guidLookup: GUIDLookup? = nil) async -> Result {
        let registry = registry ?? .shared, cache = cache ?? .shared
        let shown = current(subject.item.ref, in: registry)
        let key = ([shown.providerID + "/" + shown.itemID] + servers.map(\.id)).joined(separator: "|")
        return await cache.result(for: key) {
            var excluding: Set<MediaItemRef> = [shown]
            var show: MediaItemDetail?
            if subject.item.kind == .episode, let showRef = subject.item.grandparentRef {
                excluding.insert(current(showRef, in: registry))
                show = try? await registry.provider(for: showRef.providerID)?.fullDetail(for: showRef)
                guard show != nil else { return Result(complete: false) }
            }
            guard let query = TitleQuery(subject, show: show) else { return Result() }
            let answers = await inParallel(servers) { server in
                (server.displayName, await copies(of: query, on: server, excluding: excluding, guidLookup: guidLookup))
            }
            var result = Result(complete: answers.allSatisfy { $0.1.complete })
            for (server, found) in answers {
                result.copies += found.details.filter { !$0.mediaSources.isEmpty }.map {
                    VersionPicker.Copy(item: $0.item, server: server, sources: $0.mediaSources, library: $0.library)
                }
            }
            return result
        }
    }

    /// Complete results by title and server set, for `lifetime`. A failed request leaves its
    /// title out, so the next open asks again. The host empties it when watch state changes
    /// (a copy's resume point is in its result) and libraries can change under it, hence the expiry.
    @MainActor
    final class Cache {
        static let shared = Cache()
        static let lifetime: TimeInterval = 600
        private var results: [String: (result: Result, stored: Date)] = [:]
        private var running: [String: Task<Result, Never>] = [:]
        private var generation = 0

        func result(for key: String, now: Date = Date()) -> Result? {
            guard let entry = results[key] else { return nil }
            guard now.timeIntervalSince(entry.stored) < Self.lifetime else {
                results[key] = nil
                return nil
            }
            return entry.result
        }

        func store(_ result: Result, for key: String, now: Date = Date()) {
            guard result.complete else { return }
            // A session opens far fewer titles than this; the cap only bounds a pathological one.
            if results.count >= 200 { results.removeAll() }
            results[key] = (result, now)
        }

        func removeAll() {
            results.removeAll()
            running.removeAll()
            generation += 1
        }

        /// The cached result, else the lookup already running for `key`, else `lookup` started now.
        /// A caller's cancellation leaves a shared lookup running for the others.
        func result(for key: String, lookup: @escaping @MainActor () async -> Result) async -> Result {
            if let cached = result(for: key) { return cached }
            if let task = running[key] { return await task.value }
            let task = Task { await lookup() }
            running[key] = task
            let started = generation
            let result = await task.value
            // Emptied meanwhile: the answer may predate the change, so it is returned but not kept.
            guard generation == started else { return result }
            running[key] = nil
            store(result, for: key)
            return result
        }
    }

    // MARK: - The title rule

    /// Lower case, with runs of anything but letters and digits as one space.
    nonisolated static func foldedTitle(_ title: String) -> String {
        title.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// Some catalogue both sides are in names a different title.
    nonisolated static func idsConflict(_ a: [String: String], _ b: [String: String]) -> Bool {
        a.contains { key, value in b[key].map { $0 != value } ?? false }
    }

    /// A title match: same words, years at most one apart, no id saying otherwise.
    nonisolated static func sameTitle(_ title: String, year: Int?, ids: [String: String],
                                      as otherTitle: String, year otherYear: Int?, ids otherIDs: [String: String]) -> Bool {
        guard foldedTitle(title) == foldedTitle(otherTitle), !idsConflict(ids, otherIDs) else { return false }
        guard let year, let otherYear else { return true }
        return abs(year - otherYear) <= 1
    }

    /// `body` over every element at once; answers in `elements` order.
    private static func inParallel<Element: Sendable, Answer: Sendable>(
        _ elements: [Element], _ body: @escaping @Sendable (Element) async -> Answer
    ) async -> [Answer] {
        await withTaskGroup(of: (Int, Answer).self) { group in
            for (index, element) in elements.enumerated() {
                group.addTask { (index, await body(element)) }
            }
            var answers: [(Int, Answer)] = []
            for await answer in group { answers.append(answer) }
            return answers.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
