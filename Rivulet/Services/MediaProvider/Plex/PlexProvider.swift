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
import os

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
    /// The Plex profile an extra server's library settings belong to; nil for the selected server.
    nonisolated let accountID: String?

    init(
        machineIdentifier: String,
        displayName: String,
        serverURL: String,
        authToken: String,
        accountID: String? = nil,
        networkManager: PlexNetworkManager = .shared,
        dataStore: PlexDataStore = .shared,
        watchlistAPI: PlexWatchlistAPI = PlexWatchlistAPI()
    ) {
        self.id = "plex:\(machineIdentifier)"
        self.displayName = displayName
        self.serverURL = serverURL
        self.authToken = authToken
        self.accountID = accountID
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
        try await search(query, sections: nil)
    }

    func search(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaItem] {
        try await search(query, sections: Set(libraryIDs))
    }

    /// Titles only (movies, shows, seasons, episodes), as Home's own Plex search shows.
    private func search(_ query: String, sections: Set<String>?) async throws -> [MediaItem] {
        try await plexCall {
            let results = try await networkManager.search(
                serverURL: serverURL, authToken: authToken, query: query, start: 0, size: 80)
            return results
                .filter { ["movie", "show", "season", "episode"].contains($0.type ?? "") }
                .filter { meta in
                    guard let sections else { return true }
                    return meta.librarySectionID.map { sections.contains(String($0)) } ?? false
                }
                .map { PlexMediaMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken) }
        }
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
                var item = PlexMediaMapper.item($0, providerID: id, serverURL: serverURL, authToken: authToken)
                item.identity = ContinueWatchingMerge.plexKeys($0)
                return item
            }
        }
    }

    func itemIdentityKeys(for itemIDs: [String]) async -> [String: [String]] {
        let items = (try? await networkManager.getGuids(serverURL: serverURL, authToken: authToken, ratingKeys: itemIDs)) ?? []
        return Dictionary(items.compactMap { item in
            item.ratingKey.map { ($0, item.type == "movie" ? ContinueWatchingMerge.plexKeys(item) : ContinueWatchingMerge.plexShowKeys(item)) }
        }, uniquingKeysWith: { first, _ in first })
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

    /// The library's own Recently Added hub, re-keyed to the id Home looks up.
    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        guard let hub = try await hubs(in: library).first(where: { $0.id.lowercased().contains("recentlyadded") }),
              !hub.items.isEmpty else { return nil }
        return MediaHub(id: "\(library.id).recentlyAdded", providerID: id, title: hub.title, style: hub.style, items: hub.items)
    }

    // MARK: - Playback

    /// Plex items play through the `.plex` player path, which applies quality there; the cap is unused.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
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

    // MARK: - Deletion

    /// Answered once per provider; a new token builds a new provider.
    private let deletionAllowed = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Owner only, and only with the server's "Allow media deletion" on.
    func canDeleteMedia() async -> Bool {
        if let known = deletionAllowed.withLock({ $0 }) { return known }
        async let isAdmin = networkManager.canAdministerServer(serverURL: serverURL, authToken: authToken)
        async let allowed = networkManager.allowsMediaDeletion(serverURL: serverURL, authToken: authToken)
        let (admin, on) = await (isAdmin, allowed)
        let answer = admin && on
        deletionAllowed.withLock { $0 = answer }
        return answer
    }

    func deleteMedia(_ itemRef: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.deleteMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
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

    /// Every external guid Plex holds for the item, tmdb first. Not tmdb-only: a TheTVDB-agent
    /// show often has none, and Discover matches imdb and tvdb guids too (#269).
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

    // MARK: - Playlists

    var supportsPlaylists: Bool { true }

    /// Asked of the server once: the provider id can be a URL hash when the server list had not loaded.
    private let machineID = OSAllocatedUnfairLock<String?>(initialState: nil)

    private func serverMachineID() async throws -> String {
        if let known = machineID.withLock({ $0 }) { return known }
        let fetched = try await networkManager.getMachineIdentifier(serverURL: serverURL, authToken: authToken)
        machineID.withLock { $0 = fetched }
        return fetched
    }

    func videoPlaylists() async throws -> [MediaPlaylist] {
        try await plexCall {
            try await networkManager.getPlaylists(serverURL: serverURL, authToken: authToken, type: "video")
                .map { PlexMediaMapper.playlist($0, providerID: id, serverURL: serverURL, authToken: authToken) }
                .sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending }
        }
    }

    func playlistEntries(_ playlist: MediaItemRef) async throws -> [PlaylistEntry] {
        try await plexCall {
            try await networkManager.getAllPlaylistItems(serverURL: serverURL, authToken: authToken, ratingKey: playlist.itemID)
                .compactMap { meta in
                    meta.playlistItemID.map {
                        PlaylistEntry(entryID: String($0),
                                      item: PlexMediaMapper.item(meta, providerID: id, serverURL: serverURL, authToken: authToken))
                    }
                }
        }
    }

    func createPlaylist(title: String, seededWith items: [MediaItemRef]) async throws -> MediaPlaylist {
        try await plexCall {
            let uri = PlexNetworkManager.libraryURI(machineIdentifier: try await serverMachineID(),
                                                    ratingKeys: items.map(\.itemID))
            let created = try await networkManager.createPlaylist(
                serverURL: serverURL, authToken: authToken, type: "video", title: title, uri: uri
            )
            return PlexMediaMapper.playlist(created, providerID: id, serverURL: serverURL, authToken: authToken)
        }
    }

    func addToPlaylist(_ playlist: MediaItemRef, items: [MediaItemRef]) async throws {
        guard !items.isEmpty else { return }
        try await plexCall {
            try await networkManager.addToPlaylist(
                serverURL: serverURL, authToken: authToken, playlistRatingKey: playlist.itemID,
                machineIdentifier: try await serverMachineID(), ratingKeys: items.map(\.itemID)
            )
        }
    }

    func removeFromPlaylist(_ playlist: MediaItemRef, entryID: String) async throws {
        try await plexCall {
            try await networkManager.removePlaylistItem(
                serverURL: serverURL, authToken: authToken,
                playlistRatingKey: playlist.itemID, playlistItemID: entryID
            )
        }
    }

    func movePlaylistEntry(_ playlist: MediaItemRef, entryID: String, toIndex: Int, in entries: [PlaylistEntry]) async throws {
        let after = PlexNetworkManager.moveAfter(entryID: entryID, toIndex: toIndex, in: entries.map(\.entryID))
        try await plexCall {
            try await networkManager.movePlaylistItem(
                serverURL: serverURL, authToken: authToken, playlistRatingKey: playlist.itemID,
                playlistItemID: entryID, after: after
            )
        }
    }

    func renamePlaylist(_ playlist: MediaItemRef, title: String) async throws {
        try await plexCall {
            try await networkManager.renamePlaylist(
                serverURL: serverURL, authToken: authToken, playlistRatingKey: playlist.itemID, title: title
            )
        }
    }

    func deletePlaylist(_ playlist: MediaItemRef) async throws {
        try await plexCall {
            try await networkManager.deletePlaylist(
                serverURL: serverURL, authToken: authToken, playlistRatingKey: playlist.itemID
            )
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
