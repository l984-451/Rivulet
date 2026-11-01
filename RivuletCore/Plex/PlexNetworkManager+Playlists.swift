// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexNetworkManager+Playlists.swift
//  Rivulet
//
//  Playlist endpoints, audio and video. Measured on PMS 1.43.4.
//

import Foundation

// MARK: - Response shapes

/// A playlist row. Not `PlexMetadata`: playlists send `smart` as a JSON bool
/// and collections send it as "1", so one shared field cannot decode both.
nonisolated struct PlexPlaylist: Decodable, Hashable, Sendable {
    let ratingKey: String
    let title: String?
    let composite: String?
    let leafCount: Int?
    let duration: Int?
    let smart: Bool?
}

nonisolated struct PlexPlaylistContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let Metadata: [PlexPlaylist]?
    }
    let MediaContainer: Container
}

/// A page of a playlist's items. The container says whether the list is smart.
nonisolated struct PlexPlaylistItemsContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let Metadata: [PlexMetadata]?
        let totalSize: Int?
        let smart: Bool?
    }
    let MediaContainer: Container
}

nonisolated struct PlexIdentityContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let machineIdentifier: String
    }
    let MediaContainer: Container
}

// MARK: - Requests

extension PlexNetworkManager {

    /// Playlists of one type ("audio", "video"), optionally only those holding items from a section.
    func getPlaylists(
        serverURL: String,
        authToken: String,
        type: String,
        sectionID: String? = nil,
        sort: String? = nil
    ) async throws -> [PlexPlaylist] {
        var query = [URLQueryItem(name: "playlistType", value: type)]
        if let sectionID { query.append(URLQueryItem(name: "sectionID", value: sectionID)) }
        if let sort { query.append(URLQueryItem(name: "sort", value: sort)) }
        guard let url = Self.playlistsURL(serverURL: serverURL, path: "/playlists", query: query) else {
            throw PlexAPIError.invalidURL
        }
        let container: PlexPlaylistContainer = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.Metadata ?? []
    }

    /// One page of a playlist's items. A smart playlist can hold the whole library.
    func getPlaylistItemsWithTotal(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        start: Int,
        size: Int
    ) async throws -> (items: [PlexMetadata], totalSize: Int?, isSmart: Bool) {
        guard let url = URL(string: "\(serverURL)/playlists/\(ratingKey)/items?X-Plex-Container-Start=\(start)&X-Plex-Container-Size=\(size)") else {
            throw PlexAPIError.invalidURL
        }
        let container: PlexPlaylistItemsContainer = try await request(url, headers: plexHeaders(authToken: authToken))
        let page = container.MediaContainer
        return (page.Metadata ?? [], page.totalSize, page.smart ?? false)
    }

    /// Every item of a playlist, in 200-item pages.
    func getAllPlaylistItems(serverURL: String, authToken: String, ratingKey: String) async throws
        -> (items: [PlexMetadata], isSmart: Bool) {
        let size = 200
        var items: [PlexMetadata] = []
        while true {
            let page = try await getPlaylistItemsWithTotal(
                serverURL: serverURL, authToken: authToken, ratingKey: ratingKey, start: items.count, size: size)
            items += page.items
            if page.items.isEmpty || items.count >= (page.totalSize ?? items.count) { return (items, page.isSmart) }
        }
    }

    /// A new regular playlist seeded with `uri`; the server answers 400 without one.
    func createPlaylist(
        serverURL: String,
        authToken: String,
        type: String,
        title: String,
        uri: String
    ) async throws -> PlexPlaylist {
        guard let url = Self.createPlaylistURL(serverURL: serverURL, type: type, title: title, uri: uri) else {
            throw PlexAPIError.invalidURL
        }
        let container: PlexPlaylistContainer = try await request(url, method: "POST", headers: plexHeaders(authToken: authToken))
        guard let created = container.MediaContainer.Metadata?.first else { throw PlexAPIError.invalidResponse }
        return created
    }

    /// Append library items to a regular playlist. A duplicate is ignored; a season expands to its episodes.
    func addToPlaylist(
        serverURL: String,
        authToken: String,
        playlistRatingKey: String,
        machineIdentifier: String,
        ratingKeys: [String]
    ) async throws {
        let uri = Self.libraryURI(machineIdentifier: machineIdentifier, ratingKeys: ratingKeys)
        guard let url = Self.playlistsURL(serverURL: serverURL, path: "/playlists/\(playlistRatingKey)/items",
                                          query: [URLQueryItem(name: "uri", value: uri)]) else {
            throw PlexAPIError.invalidURL
        }
        _ = try await requestData(url, method: "PUT", headers: plexHeaders(authToken: authToken))
    }

    /// Moves a row to just after `after`, or to the top when `after` is nil.
    func movePlaylistItem(
        serverURL: String,
        authToken: String,
        playlistRatingKey: String,
        playlistItemID: String,
        after: String?
    ) async throws {
        guard let url = Self.movePlaylistItemURL(serverURL: serverURL, ratingKey: playlistRatingKey,
                                                 playlistItemID: playlistItemID, after: after) else {
            throw PlexAPIError.invalidURL
        }
        _ = try await requestData(url, method: "PUT", headers: plexHeaders(authToken: authToken))
    }

    func removePlaylistItem(
        serverURL: String,
        authToken: String,
        playlistRatingKey: String,
        playlistItemID: String
    ) async throws {
        guard let url = Self.playlistItemURL(serverURL: serverURL, ratingKey: playlistRatingKey,
                                             playlistItemID: playlistItemID) else {
            throw PlexAPIError.invalidURL
        }
        _ = try await requestData(url, method: "DELETE", headers: plexHeaders(authToken: authToken))
    }

    func renamePlaylist(serverURL: String, authToken: String, playlistRatingKey: String, title: String) async throws {
        guard let url = Self.renamePlaylistURL(serverURL: serverURL, ratingKey: playlistRatingKey, title: title) else {
            throw PlexAPIError.invalidURL
        }
        _ = try await requestData(url, method: "PUT", headers: plexHeaders(authToken: authToken))
    }

    func deletePlaylist(serverURL: String, authToken: String, playlistRatingKey: String) async throws {
        guard let url = Self.playlistURL(serverURL: serverURL, ratingKey: playlistRatingKey) else {
            throw PlexAPIError.invalidURL
        }
        _ = try await requestData(url, method: "DELETE", headers: plexHeaders(authToken: authToken))
    }

    /// The row the moved one lands after, nil for the top: what `after` takes.
    nonisolated static func moveAfter(entryID: String, toIndex: Int, in entryIDs: [String]) -> String? {
        let others = entryIDs.filter { $0 != entryID }
        let landed = min(max(toIndex, 0), others.count)
        return landed > 0 ? others[landed - 1] : nil
    }

    /// The `uri` a playlist write takes. The host is the SERVER's machine identifier.
    nonisolated static func libraryURI(machineIdentifier: String, ratingKeys: [String]) -> String {
        "server://\(machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(ratingKeys.joined(separator: ","))"
    }

    /// The server's own machine identifier, from `/identity`.
    func getMachineIdentifier(serverURL: String, authToken: String) async throws -> String {
        guard let url = URL(string: "\(serverURL)/identity") else { throw PlexAPIError.invalidURL }
        let container: PlexIdentityContainer = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.machineIdentifier
    }

    // MARK: - URL builders

    nonisolated static func createPlaylistURL(serverURL: String, type: String, title: String, uri: String) -> URL? {
        playlistsURL(serverURL: serverURL, path: "/playlists", query: [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "smart", value: "0"),
            URLQueryItem(name: "uri", value: uri)
        ])
    }

    nonisolated static func movePlaylistItemURL(serverURL: String, ratingKey: String, playlistItemID: String, after: String?) -> URL? {
        playlistsURL(serverURL: serverURL, path: "/playlists/\(ratingKey)/items/\(playlistItemID)/move",
                     query: after.map { [URLQueryItem(name: "after", value: $0)] } ?? [])
    }

    nonisolated static func playlistItemURL(serverURL: String, ratingKey: String, playlistItemID: String) -> URL? {
        playlistsURL(serverURL: serverURL, path: "/playlists/\(ratingKey)/items/\(playlistItemID)")
    }

    nonisolated static func renamePlaylistURL(serverURL: String, ratingKey: String, title: String) -> URL? {
        playlistsURL(serverURL: serverURL, path: "/playlists/\(ratingKey)", query: [URLQueryItem(name: "title", value: title)])
    }

    nonisolated static func playlistURL(serverURL: String, ratingKey: String) -> URL? {
        playlistsURL(serverURL: serverURL, path: "/playlists/\(ratingKey)")
    }

    /// URLComponents leaves "+" raw, which the server reads as a space, so it is encoded here.
    private nonisolated static func playlistsURL(serverURL: String, path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: serverURL + path) else { return nil }
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url
    }
}
