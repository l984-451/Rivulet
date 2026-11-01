// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexNetworkManager+History.swift
//  Rivulet
//
//  Watch history and play statistics (Year in Review). Measured on PMS 1.43.5:
//  both answer a managed Home user's token with that user's rows only; the
//  owner's token answers every account, so the owner filters on account 1.
//

import Foundation

// MARK: - Response shapes

/// One play from `/status/sessions/history/all`. The server keeps no duration per play.
nonisolated struct PlexHistoryEntry: Decodable, Hashable, Sendable {
    let ratingKey: String?
    let title: String?
    let type: String?
    let grandparentTitle: String?
    let grandparentKey: String?
    let parentIndex: Int?
    /// Epoch seconds.
    let viewedAt: Int?
    let accountID: Int?
    let thumb: String?
    let grandparentThumb: String?
    let grandparentArt: String?
}

/// One bucket from `/statistics/media`: seconds played per account, device and type.
nonisolated struct PlexMediaStatistic: Decodable, Hashable, Sendable {
    let accountID: Int?
    /// Bucket start, epoch seconds.
    let at: Int
    /// 1 movie, 4 episode, 10 track.
    let metadataType: Int?
    let duration: Int?
}

nonisolated struct PlexHistoryContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        let Metadata: [PlexHistoryEntry]?
        let totalSize: Int?
    }
    let MediaContainer: Container
}

nonisolated struct PlexStatisticsContainer: Decodable, Sendable {
    nonisolated struct Container: Decodable, Sendable {
        nonisolated struct Account: Decodable, Sendable { let id: Int }
        let StatisticsMedia: [PlexMediaStatistic]?
        /// Every account the token may see: one for a managed user, all of them for the server owner.
        let Account: [Account]?
    }
    let MediaContainer: Container
}

// MARK: - Requests

extension PlexNetworkManager {

    /// Every play from `since` on, paged. `type=` is ignored by the server, so callers filter.
    func getWatchHistory(
        serverURL: String,
        authToken: String,
        since: Date,
        until: Date,
        accountID: Int?
    ) async throws -> [PlexHistoryEntry] {
        let pageSize = 2000
        var entries: [PlexHistoryEntry] = []
        while true {
            // `viewedAt>=` and `viewedAt<=` are the name "viewedAt>" / "viewedAt<" plus "=".
            var query = [
                URLQueryItem(name: "viewedAt>", value: String(Int(since.timeIntervalSince1970))),
                URLQueryItem(name: "viewedAt<", value: String(Int(until.timeIntervalSince1970))),
                // Size alone is ignored without Start.
                URLQueryItem(name: "X-Plex-Container-Start", value: String(entries.count)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize))
            ]
            if let accountID { query.append(URLQueryItem(name: "accountID", value: String(accountID))) }
            guard var components = URLComponents(string: serverURL + "/status/sessions/history/all") else {
                throw PlexAPIError.invalidURL
            }
            components.queryItems = query
            guard let url = components.url else { throw PlexAPIError.invalidURL }
            let container: PlexHistoryContainer = try await request(url, headers: plexHeaders(authToken: authToken))
            let page = container.MediaContainer.Metadata ?? []
            entries += page
            let total = container.MediaContainer.totalSize ?? entries.count
            if page.count < pageSize || entries.count >= total { return entries }
        }
    }

    /// Daily play statistics from `since` on, and the ids of the accounts the token can see.
    func getDailyMediaStatistics(
        serverURL: String,
        authToken: String,
        since: Date,
        accountID: Int? = nil
    ) async throws -> (stats: [PlexMediaStatistic], accountIDs: [Int]) {
        var query = [
            URLQueryItem(name: "timespan", value: "3"),
            URLQueryItem(name: "at>", value: String(Int(since.timeIntervalSince1970)))
        ]
        if let accountID { query.append(URLQueryItem(name: "accountID", value: String(accountID))) }
        guard var components = URLComponents(string: serverURL + "/statistics/media") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = query
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let container: PlexStatisticsContainer = try await request(url, headers: plexHeaders(authToken: authToken))
        return (container.MediaContainer.StatisticsMedia ?? [], container.MediaContainer.Account?.map(\.id) ?? [])
    }
}
