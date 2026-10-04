// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProvider.swift
//  Rivulet
//
//  Plex implementation of MediaProvider. Wraps PlexNetworkManager and the
//  existing Plex* singletons; maps PlexMetadata -> agnostic types via
//  PlexMediaMapper at every boundary.
//

import Foundation

final class PlexProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .plex
    nonisolated let displayName: String
    private(set) var connectionState: ConnectionState = .connected

    let serverURL: String
    let authToken: String
    let networkManager: PlexNetworkManager
    let dataStore: PlexDataStore
    let watchlistAPI: PlexWatchlistAPI

    init(
        machineIdentifier: String,
        displayName: String,
        serverURL: String,
        authToken: String,
        networkManager: PlexNetworkManager = .shared,
        dataStore: PlexDataStore = .shared,
        watchlistAPI: PlexWatchlistAPI = PlexWatchlistAPI()
    ) {
        self.id = "plex:\(machineIdentifier)"
        self.displayName = displayName
        self.serverURL = serverURL
        self.authToken = authToken
        self.networkManager = networkManager
        self.dataStore = dataStore
        self.watchlistAPI = watchlistAPI
    }

    // MARK: - Browse

    func libraries() async throws -> [MediaLibrary] {
        try await plexCall {
            let plexLibs = try await networkManager.getLibraries(
                serverURL: serverURL, authToken: authToken
            )
            return plexLibs.map { PlexMediaMapper.library($0, providerID: id) }
        }
    }

    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        try await plexCall {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL, authToken: authToken,
                sectionId: library.id,
                start: page.offset,
                size: page.limit,
                sort: plexSortString(for: sort)
            )
            let mapped = result.items.map {
                PlexMediaMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken)
            }
            let total = result.totalSize ?? mapped.count
            let next: Page? = (page.offset + page.limit < total)
                ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
            return PagedResult(items: mapped, total: total, nextPage: next)
        }
    }

    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] {
        try await plexCall {
            let kids = try await networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
            return kids.map {
                PlexMediaMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func search(_ query: String) async throws -> [MediaItem] {
        // PlexNetworkManager doesn't expose a dedicated search method as of Wave 1.
        // Plex search routes through /hubs/search via custom request shapes;
        // wiring it here without a network-layer helper would duplicate that
        // logic. Throwing rather than returning empty so callers can
        // distinguish "search not implemented" from "no results."
        // Post-Wave-1 task adds a search method to PlexNetworkManager and
        // wires it through.
        throw MediaProviderError.backendSpecific(
            underlying: "Plex search not implemented in Wave 1"
        )
    }

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        try await plexCall {
            let meta = try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
            return PlexMediaMapper.detail(
                meta, providerID: id,
                serverURL: serverURL, authToken: authToken
            )
        }
    }

    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory? {
        // The item carries no external guid in the agnostic model, so fetch the
        // metadata (which has Guid + type + the LOCAL partial CSM), then resolve
        // the full advisory from Plex Discover. Fall back to the local partial.
        var meta = try await networkManager.getFullMetadata(
            serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
        )
        // Common Sense Media is SHOW-level: episodes/seasons carry none and often
        // lack the show's external guids. Resolve to the parent show.
        if let showKey = (meta.type == "episode" ? meta.grandparentRatingKey
                          : (meta.type == "season" ? meta.parentRatingKey : nil)) {
            meta = try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: showKey)
        }
        let localPartial = meta.CommonSenseMedia?.first.map(PlexMediaMapper.contentAdvisory(from:))
        let guids = (meta.Guid ?? []).compactMap { $0.id }
        guard let guid = guids.first(where: { $0.hasPrefix("tmdb://") })
            ?? guids.first(where: { $0.hasPrefix("imdb://") })
            ?? guids.first else { return localPartial }
        let full = await PlexContentAdvisoryService()
            .advisory(forGuid: guid, isMovie: meta.type == "movie", accountToken: authToken)
        return full ?? localPartial
    }

    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        try await plexCall {
            func item(_ meta: PlexMetadata) -> MediaItem {
                PlexMediaMapper.item(meta, providerID: self.id,
                                    serverURL: self.serverURL, authToken: self.authToken)
            }
            let hubs = try await networkManager.getRelatedItems(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            let split = Self.splitRelated(hubs: hubs, currentRatingKey: ref.itemID, kind: kind)
            var collection: CollectionRow?
            if let title = split.collectionTitle, !split.members.isEmpty {
                // Only a hub that reports `more` gets the trailing tile, and a
                // failed lookup keeps the row without it.
                var tile: MediaItem?
                if let tagId = split.tagId, let sectionId = split.sectionId,
                   let meta = try? await networkManager.getCollection(
                       serverURL: serverURL, authToken: authToken, sectionId: sectionId, tagId: tagId
                   ) {
                    tile = item(meta)
                }
                collection = CollectionRow(title: title, members: split.members.map(item), collection: tile)
            }
            return RelatedContent(items: split.related.map(item), collection: collection)
        }
    }

    /// The detail page's two rows, cut from one `/related` answer.
    nonisolated struct RelatedSplit {
        let related: [PlexMetadata]
        let collectionTitle: String?
        let members: [PlexMetadata]
        /// Set only when the collection hub reports `more`: the hub key's
        /// `tagId` and library section, which find the collection itself.
        let tagId: String?
        let sectionId: String?
    }

    /// Picks the item's collection hub: the first `collection.related.*` hub
    /// typed like the item, for movies and shows only, since a show's first
    /// collection hub can be movie-typed. Every other collection hub is
    /// dropped and the item itself is removed. The remaining hubs flatten
    /// into Related, deduped, minus the collection's members, capped at 12.
    nonisolated static func splitRelated(hubs: [PlexHub], currentRatingKey: String, kind: MediaKind) -> RelatedSplit {
        let itemType: String? = switch kind {
        case .movie: "movie"
        case .show: "show"
        default: nil
        }
        func isCollectionHub(_ hub: PlexHub) -> Bool {
            hub.hubIdentifier?.hasPrefix("collection.related.") == true
        }
        let collectionHub = itemType.flatMap { type in
            hubs.first { isCollectionHub($0) && $0.type == type }
        }
        let members = (collectionHub?.Metadata ?? []).filter { $0.ratingKey != currentRatingKey }

        // A title sits in one row only: the picked hub's members are seeded as
        // seen, so a member a people hub also lists stays out of Related.
        var seen: Set<String> = [currentRatingKey]
        seen.formUnion((collectionHub?.Metadata ?? []).compactMap(\.ratingKey))
        let related = hubs.filter { !isCollectionHub($0) }
            .flatMap { $0.Metadata ?? [] }
            .filter { item in
                guard let key = item.ratingKey else { return true }
                return seen.insert(key).inserted
            }

        var tagId: String?
        var sectionId: String?
        if collectionHub?.more == true,
           let key = collectionHub?.key,
           let components = URLComponents(string: key) {
            // /library/sections/1/all?type=1&tagId=353397&sort=...
            let path = components.path.split(separator: "/").map(String.init)
            if let tag = components.queryItems?.first(where: { $0.name == "tagId" })?.value,
               let i = path.firstIndex(of: "sections"), path.indices.contains(i + 1) {
                tagId = tag
                sectionId = path[i + 1]
            }
        }
        return RelatedSplit(
            related: Array(related.prefix(12)),
            collectionTitle: collectionHub?.title,
            members: members,
            tagId: tagId,
            sectionId: sectionId
        )
    }

    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] {
        try await plexCall {
            let episodes = try await networkManager.getAllLeaves(
                serverURL: serverURL, authToken: authToken, ratingKey: showRef.itemID
            )
            return episodes.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }

    // MARK: - Home rails

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await plexCall {
            // getContinueWatching returns a single PlexHub? whose Metadata is the items.
            let hub = try await networkManager.getContinueWatching(
                serverURL: serverURL, authToken: authToken, count: limit
            )
            let metadata = hub?.Metadata ?? []
            return metadata.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        try await plexCall {
            let items = try await networkManager.getRecentlyAdded(
                serverURL: serverURL, authToken: authToken, limit: limit
            )
            return items.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }

    /// Plex-native curated hubs. HomeComposer calls this via type-check;
    /// other providers compose hubs from primitives.
    func hubs() async throws -> [MediaHub] {
        try await plexCall {
            let plexHubs = try await networkManager.getHubs(
                serverURL: serverURL, authToken: authToken
            )
            return plexHubs.map {
                PlexMediaMapper.hub($0, providerID: id,
                                   serverURL: serverURL, authToken: authToken)
            }
        }
    }

    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        try await plexCall {
            let plexHubs = try await networkManager.getLibraryHubs(
                serverURL: serverURL, authToken: authToken, sectionId: library.id
            )
            return plexHubs.map {
                PlexMediaMapper.hub($0, providerID: id,
                                   serverURL: serverURL, authToken: authToken)
            }
        }
    }

    // MARK: - Playback

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?) async throws -> StreamInfo {
        let detail = try await fullDetail(for: itemRef)
        guard let chosen = VersionRanking.choose(sourceID.map(VersionChoice.source) ?? .best,
                                                 from: detail.mediaSources) else {
            throw MediaProviderError.notFound
        }
        return StreamInfo(source: chosen, playSessionID: nil, trackInfoAvailable: true)
    }

    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter {
        PlexTimelineReporter(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: itemRef.itemID,
            networkManager: networkManager
        )
    }

    // MARK: - Per-item track selection

    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {
        guard let streamID = Int(trackID) else {
            throw MediaProviderError.backendSpecific(underlying: "audio trackID must be numeric for Plex (got \(trackID))")
        }
        let partID = try await resolvePartID(sourceID: sourceID, ratingKey: itemRef.itemID)
        await networkManager.setSelectedAudioStream(
            serverURL: serverURL,
            authToken: authToken,
            partId: partID,
            audioStreamID: streamID
        )
    }

    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {
        // `nil` means "off"; Plex encodes that as 0.
        let streamID: Int
        if let trackID {
            guard let parsed = Int(trackID) else {
                throw MediaProviderError.backendSpecific(underlying: "subtitle trackID must be numeric for Plex (got \(trackID))")
            }
            streamID = parsed
        } else {
            streamID = 0
        }
        let partID = try await resolvePartID(sourceID: sourceID, ratingKey: itemRef.itemID)
        await networkManager.setSelectedSubtitleStream(
            serverURL: serverURL,
            authToken: authToken,
            partId: partID,
            subtitleStreamID: streamID
        )
    }

    /// Plex's per-user-per-part PUT endpoint takes the Plex `Part.id`, but our
    /// agnostic `MediaSource.id` carries `Media.id`. Round-trip the ratingKey
    /// to the network manager so we can pick the matching Media + first Part.
    private func resolvePartID(sourceID: String, ratingKey: String) async throws -> Int {
        let metadata = try await plexCall {
            try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: ratingKey
            )
        }
        let media: PlexMedia? = {
            if let id = Int(sourceID), let match = metadata.Media?.first(where: { $0.id == id }) {
                return match
            }
            return metadata.Media?.first
        }()
        guard let media, let part = media.Part?.first else {
            throw MediaProviderError.notFound
        }
        return part.id
    }

    // MARK: - Watch state

    func markPlayed(_ itemRef: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.markWatched(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
        }
    }

    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.markUnwatched(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
        }
    }

    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        try await plexCall {
            try await networkManager.reportProgress(
                serverURL: serverURL, authToken: authToken,
                ratingKey: itemRef.itemID, timeMs: Int(position * 1000), state: "playing"
            )
        }
    }

    // MARK: - Watchlist

    var supportsWatchlist: Bool { true }

    /// The metadata the watchlist actually keys on. The agnostic `MediaItemRef`
    /// carries no external guid, so it has to be fetched — the same gap
    /// `contentAdvisory` above works around. Episodes and seasons resolve to
    /// their show, because Plex watchlists movies and shows, never an episode.
    private func watchlistTarget(_ ref: MediaItemRef) async -> PlexMetadata? {
        guard let meta = try? await networkManager.getFullMetadata(
            serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
        ) else { return nil }
        guard let showKey = (meta.type == "episode" ? meta.grandparentRatingKey
                             : (meta.type == "season" ? meta.parentRatingKey : nil))
        else { return meta }
        return (try? await networkManager.getFullMetadata(
            serverURL: serverURL, authToken: authToken, ratingKey: showKey
        )) ?? meta
    }

    /// Every external guid Plex holds for the item, tmdb first (it's what the
    /// watchlist cache is keyed on elsewhere). NOT tmdb-only: a show scraped by
    /// the TheTVDB agent frequently carries no tmdb guid at all, and demanding
    /// one meant adding it silently did nothing (issue #269). Plex Discover
    /// matches imdb and tvdb guids just as well.
    func watchlistGUIDs(_ ref: MediaItemRef) async -> [String] {
        if ref.providerID == TMDBMediaMapper.providerID,
           let (tmdbId, _) = TMDBMediaMapper.decodeItemID(ref.itemID) {
            return ["tmdb://\(tmdbId)"]
        }
        guard let meta = await watchlistTarget(ref) else { return [] }
        return Self.externalGUIDs(meta)
    }

    static func externalGUIDs(_ meta: PlexMetadata) -> [String] {
        let raw = [meta.guid].compactMap { $0 } + (meta.Guid ?? []).compactMap(\.id)
        var out: [String] = []
        if let id = raw.compactMap(PlexMetadata.extractTmdbId).first { out.append("tmdb://\(id)") }
        if let id = raw.compactMap(PlexMetadata.extractImdbId).first { out.append("imdb://\(id)") }
        if let id = raw.compactMap(PlexMetadata.extractTvdbId).first { out.append("tvdb://\(id)") }
        return out
    }

    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool {
        let guids = await watchlistGUIDs(ref)
        guard !guids.isEmpty else { return false }
        return await MainActor.run { guids.contains(where: PlexWatchlistService.shared.contains) }
    }

    func addToWatchlist(_ ref: MediaItemRef) async throws {
        guard let meta = await watchlistTarget(ref) else { throw MediaProviderError.notFound }
        let guids = Self.externalGUIDs(meta)
        guard let guid = guids.first else { throw MediaProviderError.notFound }
        // Stub for the optimistic local insert; the next fetchWatchlist replaces
        // it with the server's copy. It carries every guid so a later
        // `contains` answers for whichever one the caller has.
        let entry = PlexWatchlistItem(
            id: guid,
            title: meta.title ?? "",
            year: meta.year,
            type: meta.type == "movie" ? .movie : .show,
            posterURL: PlexMediaMapper.artworkURL(
                meta.thumb ?? meta.bestThumb, serverURL: serverURL, authToken: authToken
            ),
            guids: guids
        )
        let service = PlexWatchlistService.shared
        await service.add(guid: guid, item: entry)
        // `add` swallows its own API errors and reverts the optimistic insert,
        // so asking whether the guid survived is the only way to know the write
        // landed. Without this the caller can't tell a success from a no-op —
        // which is how #269 shipped a button that lied.
        guard await MainActor.run(body: { service.contains(guid: guid) }) else {
            throw MediaProviderError.backendSpecific(underlying: "Plex rejected the watchlist add")
        }
    }

    func removeFromWatchlist(_ ref: MediaItemRef) async throws {
        let guids = await watchlistGUIDs(ref)
        guard !guids.isEmpty else { throw MediaProviderError.notFound }
        let service = PlexWatchlistService.shared
        // Remove by the guid actually in the local set — that's the one the
        // service matches its stored items against.
        let target = await MainActor.run { guids.first(where: service.contains) }
        guard let guid = target else { return }   // already off the list
        await service.remove(guid: guid)
        guard await MainActor.run(body: { !guids.contains(where: service.contains) }) else {
            throw MediaProviderError.backendSpecific(underlying: "Plex rejected the watchlist remove")
        }
    }

    // MARK: - Helpers

    private func plexSortString(for sort: SortOption) -> String? {
        switch sort {
        case .titleAsc: return "titleSort:asc"
        case .titleDesc: return "titleSort:desc"
        case .releaseDateDesc: return "originallyAvailableAt:desc"
        case .addedAtDesc: return "addedAt:desc"
        case .addedAtAsc: return "addedAt:asc"
        case .releaseDateAsc: return "originallyAvailableAt:asc"
        case .lastContentAddedDesc: return "episode.addedAt:desc"
        case .ratingDesc: return "rating:desc"
        }
    }
}
