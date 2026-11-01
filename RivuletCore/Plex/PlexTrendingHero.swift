// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// TMDB's trending titles a Plex server owns, with no library index: each title's
/// plex:// guid from Plex's metadata host (kept for the session), then one
/// `/library/all?guid=a,b,…` on the server.
enum PlexTrendingHero {
    /// `TrendingMatch.key` → plex:// guid; an empty string is a title Plex has no match for.
    private static var plexGUIDs: [String: String] = [:]

    static func items(serverURL: String, serverToken: String, accountToken: String, limit: Int = 10) async -> [PlexMetadata] {
        async let movies = TMDBDiscoverService.shared.fetchSection(.movieTrending)
        async let shows = TMDBDiscoverService.shared.fetchSection(.tvTrending)
        let titles = TrendingMatch.interleave(movies: await movies, shows: await shows)
        let guids = await resolve(titles, accountToken: accountToken)
        guard let owned = try? await PlexNetworkManager.shared.findByGuids(
            serverURL: serverURL, authToken: serverToken, guids: guids) else { return [] }
        return ordered(owned, by: guids, limit: limit)
    }

    /// `owned` in `guids` order, with art, at most `limit`.
    static func ordered(_ owned: [PlexMetadata], by guids: [String], limit: Int) -> [PlexMetadata] {
        let byGUID = Dictionary(owned.compactMap { item in item.guid.map { ($0, item) } }, uniquingKeysWith: { a, _ in a })
        return Array(guids.compactMap { byGUID[$0] }.filter { $0.art != nil }.prefix(limit))
    }

    /// The titles' plex:// guids in order, asking Plex only for ones not yet resolved.
    private static func resolve(_ titles: [TMDBListItem], accountToken: String) async -> [String] {
        let missing = titles.filter { plexGUIDs[TrendingMatch.key(tmdbID: String($0.id), type: $0.mediaType)] == nil }
        // ponytail: 8 at a time with no cap on the list; TMDB's two trending pages are ~40 titles.
        for chunk in stride(from: 0, to: missing.count, by: 8).map({ Array(missing[$0..<min($0 + 8, missing.count)]) }) {
            let found = await withTaskGroup(of: (String, String?).self) { group in
                for title in chunk {
                    let key = TrendingMatch.key(tmdbID: String(title.id), type: title.mediaType)
                    group.addTask { (key, await plexGUID(for: title, accountToken: accountToken)) }
                }
                // A failed request is asked again next time; only answers are kept.
                return await group.reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
            }
            plexGUIDs.merge(found) { _, new in new }
        }
        return titles.compactMap { plexGUIDs[TrendingMatch.key(tmdbID: String($0.id), type: $0.mediaType)] }
            .filter { !$0.isEmpty }
    }

    /// The title's plex:// guid, "" when Plex has none, nil when the request failed.
    private static func plexGUID(for title: TMDBListItem, accountToken: String) async -> String? {
        var components = URLComponents(string: "https://metadata.provider.plex.tv/library/metadata/matches")!
        components.queryItems = [
            URLQueryItem(name: "type", value: title.mediaType == .movie ? "1" : "2"),
            URLQueryItem(name: "guid", value: "tmdb://\(title.id)"),
            URLQueryItem(name: "X-Plex-Token", value: accountToken),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Reply: Decodable {
            struct Container: Decodable { let Metadata: [Item]? }
            struct Item: Decodable { let guid: String? }
            let MediaContainer: Container
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return reply.MediaContainer.Metadata?.first?.guid ?? ""
    }
}
