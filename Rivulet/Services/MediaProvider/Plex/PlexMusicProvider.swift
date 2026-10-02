// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexMusicProvider.swift
//  Rivulet
//
//  Plex implementation of MusicProvider. Wraps PlexNetworkManager + maps
//  responses through PlexMusicMapper.
//

import Foundation

final class PlexMusicProvider: MusicProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .plex
    nonisolated let displayName: String
    private(set) var connectionState: ConnectionState = .connected

    let serverURL: String
    let authToken: String
    let networkManager: PlexNetworkManager

    init(
        machineIdentifier: String,
        displayName: String,
        serverURL: String,
        authToken: String,
        networkManager: PlexNetworkManager = .shared
    ) {
        self.id = "plex:\(machineIdentifier)"
        self.displayName = displayName
        self.serverURL = serverURL
        self.authToken = authToken
        self.networkManager = networkManager
    }

    // MARK: - Browse

    func musicLibraries() async throws -> [MediaLibrary] {
        try await plexCall {
            let all = try await networkManager.getLibraries(
                serverURL: serverURL, authToken: authToken
            )
            return all
                .filter { $0.type == "artist" }
                .map { PlexMediaMapper.library($0, providerID: id) }
        }
    }

    func artists(
        in library: MediaLibrary,
        sort: SortOption,
        page: Page
    ) async throws -> PagedResult<MusicArtist> {
        try await plexCall {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL, authToken: authToken,
                sectionId: library.id,
                start: page.offset,
                size: page.limit,
                sort: plexSortString(for: sort),
                type: 8                      // Plex artists type
            )
            let mapped = result.items.map { meta in
                PlexMusicMapper.artist(
                    meta, providerID: id,
                    serverURL: serverURL, authToken: authToken
                )
            }
            let total = result.totalSize ?? mapped.count
            let next: Page? = (page.offset + page.limit < total)
                ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
            return PagedResult(items: mapped, total: total, nextPage: next)
        }
    }

    func albums(
        in library: MediaLibrary,
        sort: SortOption,
        page: Page
    ) async throws -> PagedResult<MusicAlbum> {
        try await plexCall {
            let result = try await networkManager.getLibraryItemsWithTotal(
                serverURL: serverURL, authToken: authToken,
                sectionId: library.id,
                start: page.offset,
                size: page.limit,
                sort: plexSortString(for: sort),
                type: 9                      // Plex albums type
            )
            let mapped = result.items.map { meta in
                PlexMusicMapper.album(
                    meta, providerID: id,
                    serverURL: serverURL, authToken: authToken
                )
            }
            let total = result.totalSize ?? mapped.count
            let next: Page? = (page.offset + page.limit < total)
                ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
            return PagedResult(items: mapped, total: total, nextPage: next)
        }
    }

    func search(_ query: String) async throws -> [MusicItem] {
        // Parallels PlexProvider.search — routes through /hubs/search which
        // isn't typed yet.
        //
        // TODO(post-wave-1): wire Plex music search once PlexNetworkManager
        // has a typed search helper.
        throw MediaProviderError.backendSpecific(
            underlying: "Plex music search not implemented in Wave 1"
        )
    }

    // MARK: - Hierarchy

    func albums(for artistRef: MediaItemRef) async throws -> [MusicAlbum] {
        try await plexCall {
            let kids = try await networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: artistRef.itemID
            )
            return kids.compactMap { meta -> MusicAlbum? in
                guard meta.type == "album" else { return nil }
                return PlexMusicMapper.album(
                    meta, providerID: id,
                    serverURL: serverURL, authToken: authToken
                )
            }
        }
    }

    func tracks(for albumRef: MediaItemRef) async throws -> [MusicTrack] {
        try await plexCall {
            let kids = try await networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: albumRef.itemID
            )
            return kids.compactMap { meta -> MusicTrack? in
                guard meta.type == "track" else { return nil }
                return PlexMusicMapper.track(
                    meta, providerID: id,
                    serverURL: serverURL, authToken: authToken
                )
            }
        }
    }

    func allTracks(for artistRef: MediaItemRef) async throws -> [MusicTrack] {
        try await plexCall {
            let leaves = try await networkManager.getAllLeaves(
                serverURL: serverURL, authToken: authToken, ratingKey: artistRef.itemID
            )
            return leaves.map {
                PlexMusicMapper.track(
                    $0, providerID: id,
                    serverURL: serverURL, authToken: authToken
                )
            }
        }
    }

    // MARK: - Detail

    func artistDetail(for ref: MediaItemRef) async throws -> MusicArtistDetail {
        try await plexCall {
            async let metaFetch = networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            async let childrenFetch = networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            async let leavesFetch = networkManager.getAllLeaves(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            let meta = try await metaFetch
            let albumsMeta = try await childrenFetch
            let allLeaves = try await leavesFetch

            let albums = albumsMeta.filter { $0.type == "album" }
            let topTracks = Array(allLeaves.prefix(10))
            // TODO(post-wave-1): wire /library/metadata/{id}/similar.
            return PlexMusicMapper.artistDetail(
                meta,
                albums: albums,
                topTracks: topTracks,
                similarArtists: [],
                providerID: id,
                serverURL: serverURL, authToken: authToken
            )
        }
    }

    func albumDetail(for ref: MediaItemRef) async throws -> MusicAlbumDetail {
        try await plexCall {
            async let metaFetch = networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            async let childrenFetch = networkManager.getChildren(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            let meta = try await metaFetch
            let allChildren = try await childrenFetch
            let tracks = allChildren.filter { $0.type == "track" }
            return PlexMusicMapper.albumDetail(
                meta, tracks: tracks,
                providerID: id,
                serverURL: serverURL, authToken: authToken
            )
        }
    }

    func trackDetail(for ref: MediaItemRef) async throws -> MusicTrackDetail {
        try await plexCall {
            let meta = try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            // TODO(post-wave-1): wire getLyrics helper + pipe through.
            return PlexMusicMapper.trackDetail(
                meta, lyrics: nil,
                providerID: id,
                serverURL: serverURL, authToken: authToken
            )
        }
    }

    // MARK: - Home rails

    func recentlyAddedAlbums(limit: Int) async throws -> [MusicAlbum] {
        try await plexCall {
            let items = try await networkManager.getRecentlyAdded(
                serverURL: serverURL, authToken: authToken, limit: limit
            )
            return items.compactMap { meta -> MusicAlbum? in
                guard meta.type == "album" else { return nil }
                return PlexMusicMapper.album(
                    meta, providerID: id,
                    serverURL: serverURL, authToken: authToken
                )
            }
        }
    }

    func recentlyPlayed(limit: Int) async throws -> [MusicItem] {
        // TODO(post-wave-1): wire music recently-played hub.
        return []
    }

    // MARK: - Playback

    func resolveStream(for trackRef: MediaItemRef) async throws -> StreamInfo {
        try await plexCall {
            let meta = try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: trackRef.itemID
            )
            let sources: [MediaSource] = (meta.Media ?? []).flatMap { media in
                (media.Part ?? []).map { part in
                    PlexMediaMapper.mediaSource(
                        media, part,
                        serverURL: serverURL, authToken: authToken
                    )
                }
            }
            guard let source = sources.first else {
                throw MediaProviderError.notFound
            }
            return StreamInfo(source: source, playSessionID: nil, trackInfoAvailable: true)
        }
    }

    // MARK: - State

    func setRating(_ rating: Double?, for ref: MediaItemRef) async throws {
        // setUserRating does not yet exist on PlexNetworkManager.
        // TODO(post-wave-1): add setUserRating to PlexNetworkManager and wire it here.
        throw MediaProviderError.backendSpecific(
            underlying: "Plex rating update not yet wired at network layer"
        )
    }

    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        // Plex has no separate "favorite" concept — non-zero rating = favorite.
        try await setRating(favorite ? 5.0 : nil, for: ref)
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
        case .lastContentAddedDesc: return "addedAt:desc"
        // Music uses userRating (per-user star rating) not rating (community rating);
        // Plex's music libraries don't populate the community `rating` field.
        case .ratingDesc: return "userRating:desc"
        }
    }
}
