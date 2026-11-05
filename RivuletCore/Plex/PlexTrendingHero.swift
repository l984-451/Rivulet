// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Titles known by TMDB id (trending, watchlist) turned into the plex:// guids a Plex server
/// indexes: from Plex's metadata host, kept for the session. The server is then asked for
/// `/library/all?guid=a,b,…` (`findByGuids`).
enum PlexTrendingHero {
    /// A title's plex:// guid: "" when Plex has none, nil when the request failed.
    typealias Lookup = @Sendable (TitleMatch, String) async -> String?

    /// `kind:tmdb id` → plex:// guid; an empty string is a title Plex has no match for.
    private static var plexGUIDs: [String: String] = [:]

    private static func cacheKey(_ title: TitleMatch) -> String? {
        title.externalIDs["tmdb"].map { "\(title.kind):\($0)" }
    }

    /// The titles' plex:// guids in title order, each once. A title's own guid is used as given;
    /// the rest are looked up, only those not yet resolved, and are skipped without an account token.
    static func guids(for titles: [TitleMatch], accountToken: String?, lookup: @escaping Lookup) async -> [String] {
        let missing = titles.filter { title in
            title.plexGUID == nil && cacheKey(title).map { plexGUIDs[$0] == nil } == true
        }
        if let accountToken {
            // ponytail: 8 at a time with no cap on the list; TMDB's two trending pages are ~40 titles.
            for chunk in stride(from: 0, to: missing.count, by: 8).map({ Array(missing[$0..<min($0 + 8, missing.count)]) }) {
                let found = await withTaskGroup(of: (String, String?).self) { group in
                    for title in chunk {
                        guard let key = cacheKey(title) else { continue }
                        group.addTask { (key, await lookup(title, accountToken)) }
                    }
                    // A failed request is asked again next time; only answers are kept.
                    return await group.reduce(into: [String: String]()) { $0[$1.0] = $1.1 }
                }
                plexGUIDs.merge(found) { _, new in new }
            }
        }
        var seen = Set<String>()
        return titles.compactMap { title in
            title.plexGUID ?? cacheKey(title).flatMap { plexGUIDs[$0] }
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `owned` in `guids` order.
    static func ordered(_ owned: [PlexMetadata], by guids: [String]) -> [PlexMetadata] {
        let byGUID = Dictionary(owned.compactMap { item in item.guid.map { ($0, item) } }, uniquingKeysWith: { a, _ in a })
        return guids.compactMap { byGUID[$0] }
    }

    /// Plex's metadata host: the title's plex:// guid from its TMDB id.
    static func plexTV(_ title: TitleMatch, _ accountToken: String) async -> String? {
        guard let tmdb = title.externalIDs["tmdb"] else { return nil }
        var components = URLComponents(string: "https://metadata.provider.plex.tv/library/metadata/matches")!
        components.queryItems = [
            URLQueryItem(name: "type", value: title.kind == .movie ? "1" : "2"),
            URLQueryItem(name: "guid", value: "tmdb://\(tmdb)"),
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
