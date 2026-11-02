// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What Home renders, fetched in one pass by `refresh()`.
struct IOSPlexHome {
    var libraries: [PlexLibrary]
    /// Outer nil: the fetch failed, so the row already showing stays.
    var continueWatching: PlexHub??
    /// Hubs per pinned library key; a library whose fetch failed is left out.
    var hubsByLibrary: [String: [PlexHub]]
}

extension IOSPlexSession {
    // MARK: - Home

    /// Same composition as tvOS `PlexDataStore.projectHomeItems`: the merged,
    /// cache-busted `/hubs/continueWatching` row first, then each library
    /// pinned to Home (`hidden == 0`) contributes its `promoted` hubs, in
    /// library order. The aggregate `/hubs` is wrong here: it merges movie
    /// libraries into one row and carries playlists.
    func fetchHome(serverID: String? = nil) async throws -> IOSPlexHome {
        let (serverURL, token) = try configuration(serverID: serverID)
        let network = network
        var libraries = try await network.getLibraries(serverURL: serverURL, authToken: token)
            .filter(\.isVideoLibrary)
            .map { library in
                var library = library
                library.serverID = serverID
                return library
            }
        #if DEBUG
        libraries = IOSScreenshotMode.demoLibraries(libraries)
        #endif
        async let continueWatching = network.getContinueWatching(serverURL: serverURL, authToken: token)

        let pinned = libraries.filter(\.isPinnedToHome)
        let hubsByLibrary = await withTaskGroup(of: (String, [PlexHub]?).self) { group in
            for library in pinned {
                group.addTask {
                    let hubs = try? await network.getLibraryHubs(
                        serverURL: serverURL, authToken: token, sectionId: library.key
                    )
                    return (library.id, hubs.map { $0.map { Self.onServer($0, serverID) } })
                }
            }
            var result: [String: [PlexHub]] = [:]
            for await (key, hubs) in group { result[key] = hubs }
            return result
        }
        let cw: PlexHub??
        do {
            let hub = try await continueWatching
            cw = .some((hub?.Metadata ?? []).isEmpty ? nil : hub.map { Self.onServer($0, serverID) })
        } catch {
            cw = nil
        }
        #if DEBUG
        if IOSScreenshotMode.isOn {
            let demoCW = (cw ?? nil).map { hub -> PlexHub in
                var hub = hub
                hub.Metadata = IOSScreenshotMode.demoItems(hub.Metadata ?? [], libraries: libraries)
                return hub
            }
            return IOSPlexHome(libraries: libraries, continueWatching: .some(demoCW?.Metadata?.isEmpty == false ? demoCW : nil),
                               hubsByLibrary: hubsByLibrary.mapValues(IOSScreenshotMode.demoHubs))
        }
        #endif
        return IOSPlexHome(libraries: libraries, continueWatching: cw, hubsByLibrary: hubsByLibrary)
    }

    /// Marks a row and its items as `serverID`'s; Home badges the row with its server.
    nonisolated static func onServer(_ hub: PlexHub, _ serverID: String?) -> PlexHub {
        guard serverID != nil else { return hub }
        var hub = hub
        hub.serverID = serverID
        hub.Metadata = hub.Metadata.map { onServer($0, serverID) }
        return hub
    }

    nonisolated static func onServer(_ items: [PlexMetadata], _ serverID: String?) -> [PlexMetadata] {
        guard serverID != nil else { return items }
        return items.map { item in
            var item = item
            item.serverID = serverID
            return item
        }
    }

    /// One page of a hub's See All grid. The key's own query is the row's
    /// definition; `getHubItems` appends Start and Size to it.
    func hubPage(_ hub: PlexHub, start: Int, size: Int) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        guard let key = hub.key ?? hub.hubKey else { return (hub.Metadata ?? [], hub.Metadata?.count) }
        let (serverURL, token) = try configuration(serverID: hub.serverID)
        let page = try await network.getHubItems(
            serverURL: serverURL, authToken: token, hubKey: key,
            hubIdentifier: hub.hubIdentifier, start: start, count: size
        )
        return (Self.onServer(page.items, hub.serverID), page.totalSize)
    }

    // MARK: - Library

    /// One page of a library grid. Built as a hub key so the Unwatched filter
    /// rides the same Start+Size paging (`getLibraryItemsWithTotal` has no filter).
    func libraryPage(
        _ library: PlexLibrary,
        sort: LibrarySortOption,
        unwatchedOnly: Bool,
        start: Int,
        size: Int
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        let (serverURL, token) = try configuration(serverID: library.serverID)
        let key = "/library/sections/\(library.key)/all?sort=\(sort.apiParameter)"
            + (unwatchedOnly ? "&unwatched=1" : "")
        let page = try await network.getHubItems(
            serverURL: serverURL, authToken: token, hubKey: key, start: start, count: size
        )
        return (Self.onServer(page.items, library.serverID), page.totalSize)
    }

    // MARK: - Detail

    /// Full metadata: markers, chapters, extras, external guids, On Deck.
    func metadata(for item: PlexMetadata) async throws -> PlexMetadata {
        guard let key = item.ratingKey else { return item }
        let (serverURL, token) = try configuration(serverID: item.serverID)
        var full = try await network.getFullMetadata(serverURL: serverURL, authToken: token, ratingKey: key)
        full.serverID = item.serverID
        // On Deck is the next episode on the same server.
        if let onDeck = full.OnDeck?.Metadata { full.OnDeck?.Metadata = Self.onServer(onDeck, item.serverID) }
        return full
    }

    func children(of item: PlexMetadata) async throws -> [PlexMetadata] {
        guard let key = item.ratingKey else { return [] }
        let (serverURL, token) = try configuration(serverID: item.serverID)
        return Self.onServer(try await network.getChildren(serverURL: serverURL, authToken: token, ratingKey: key), item.serverID)
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
    }

    /// "More Like This": the similar-title hubs of `/related`, without the
    /// collection and same-actor rows.
    func related(to item: PlexMetadata) async throws -> [PlexMetadata] {
        guard let key = item.ratingKey else { return [] }
        let (serverURL, token) = try configuration(serverID: item.serverID)
        let hubs = try await network.getRelatedItems(serverURL: serverURL, authToken: token, ratingKey: key)
        var seen: Set<String> = [item.id]
        return Self.onServer(hubs
            .filter { ($0.hubIdentifier ?? "").contains("similar") }
            .flatMap { $0.Metadata ?? [] }, item.serverID)
            .filter { seen.insert($0.id).inserted }
    }

    /// The episode Play should start for a show or season: On Deck when Plex
    /// has one, otherwise the next unfinished episode of the first real season.
    func playableTarget(for item: PlexMetadata) async throws -> PlexMetadata {
        if item.isPlayable { return item }
        let full = try await metadata(for: item)
        if let next = full.OnDeck?.Metadata?.first { return next }
        var season = full
        if full.type == "show" {
            let seasons = try await children(of: full)
            guard let first = seasons.first(where: { ($0.index ?? 0) > 0 }) ?? seasons.first else {
                throw IOSPlexSessionError.noPlayableURL
            }
            season = first
        }
        guard let episode = Self.nextUp(in: try await children(of: season)) else {
            throw IOSPlexSessionError.noPlayableURL
        }
        return episode
    }

    /// Resume point first, then the first unwatched, then the first episode.
    static func nextUp(in episodes: [PlexMetadata]) -> PlexMetadata? {
        episodes.first(where: \.isInProgress)
            ?? episodes.first(where: { !$0.isWatched })
            ?? episodes.first
    }

    // MARK: - Search

    /// Every server, searched at once: the selected server's results first, then
    /// each other server's. Another server failing only loses its own results.
    func search(_ query: String) async throws -> [PlexMetadata] {
        let ids = PlexExtraServers.shared.current.map(\.machineID)
        async let others = withTaskGroup(of: (Int, [PlexMetadata]).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { await (index, (try? self.search(query, serverID: id)) ?? []) }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        let primary = try await search(query, serverID: nil)
        let rest = await others
        return primary + ids.indices.flatMap { rest[$0] ?? [] }
    }

    private func search(_ query: String, serverID: String?) async throws -> [PlexMetadata] {
        let (serverURL, token) = try configuration(serverID: serverID)
        var results = Self.onServer(try await network.search(serverURL: serverURL, authToken: token, query: query, size: 80),
                                    serverID)
        #if DEBUG
        results = IOSScreenshotMode.demoItems(results, libraries: libraries)
        #endif
        // Video results only, one row per item: /search returns every
        // matching type and can repeat an item across result groups.
        var seen = Set<String>()
        return results.filter {
            ["movie", "show", "season", "episode"].contains($0.type ?? "")
                && seen.insert($0.id).inserted
        }
    }

    // MARK: - Watched

    /// Scrobbles a show or season as a whole, like any Plex client.
    func setWatched(_ watched: Bool, for item: PlexMetadata) async throws {
        guard let key = item.ratingKey else { return }
        let (serverURL, token) = try configuration(serverID: item.serverID)
        if watched {
            try await network.markWatched(serverURL: serverURL, authToken: token, ratingKey: key)
            // A merged Continue Watching card's other copies, or one brings it back.
            for copy in continueWatchingCopies[item.id] ?? [] {
                guard let copyKey = copy.ratingKey, let (url, token) = try? configuration(serverID: copy.serverID) else { continue }
                try? await network.markWatched(serverURL: url, authToken: token, ratingKey: copyKey)
            }
        } else {
            try await network.markUnwatched(serverURL: serverURL, authToken: token, ratingKey: key)
        }
        await watchStateDidChange()
    }

    // MARK: - Watchlist

    /// Plex watchlists movies and shows; an episode or season stands for its show.
    func isOnWatchlist(_ item: PlexMetadata) -> Bool {
        let service = PlexWatchlistService.shared
        let plexGUID: String? = switch item.type {
        case "episode": item.grandparentGuid
        case "season": item.parentGuid
        default: item.guid
        }
        if let plexGUID, service.watchlistItems.contains(where: { $0.plexGUID == plexGUID }) { return true }
        guard item.type == "movie" || item.type == "show" else { return false }
        return Self.externalGUIDs(item).contains(where: service.contains(guid:))
    }

    func setWatchlisted(_ on: Bool, item: PlexMetadata) async throws {
        let service = PlexWatchlistService.shared
        let target = try await watchlistTarget(for: item)
        let guids = Self.externalGUIDs(target)
        if on {
            guard let guid = guids.first else { throw IOSPlexSessionError.watchlistUnavailable }
            await service.add(guid: guid, item: PlexWatchlistItem(
                id: guid,
                title: target.title ?? "",
                year: target.year,
                type: target.type == "movie" ? .movie : .show,
                posterURL: artworkURL(for: target, kind: .poster, width: 300, height: 450),
                guids: guids,
                plexGUID: target.guid
            ))
            // `add` reverts silently on failure, so membership is the only success signal.
            guard service.contains(guid: guid) else { throw IOSPlexSessionError.watchlistUnavailable }
        } else {
            let stored = service.watchlistItems.first { $0.plexGUID != nil && $0.plexGUID == target.guid }?.guids ?? []
            guard let guid = (stored + guids).first(where: service.contains(guid:)) else { return }
            await service.remove(guid: guid)
            guard !service.contains(guid: guid) else { throw IOSPlexSessionError.watchlistUnavailable }
        }
    }

    /// Full metadata (with external guids) of the movie or show to watchlist.
    private func watchlistTarget(for item: PlexMetadata) async throws -> PlexMetadata {
        let key: String? = switch item.type {
        case "episode": item.grandparentRatingKey
        case "season": item.parentRatingKey
        default: item.ratingKey
        }
        var show = PlexMetadata(ratingKey: key)
        show.serverID = item.serverID
        return try await metadata(for: show)
    }

    /// Same set tvOS `PlexProvider.externalGUIDs` sends to Discover.
    private static func externalGUIDs(_ item: PlexMetadata) -> [String] {
        let raw = [item.guid].compactMap { $0 } + (item.Guid ?? []).compactMap(\.id)
        var out: [String] = []
        if let id = raw.compactMap(PlexMetadata.extractTmdbId).first { out.append("tmdb://\(id)") }
        if let id = raw.compactMap(PlexMetadata.extractImdbId).first { out.append("imdb://\(id)") }
        if let id = raw.compactMap(PlexMetadata.extractTvdbId).first { out.append("tvdb://\(id)") }
        return out
    }
}
