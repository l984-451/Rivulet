// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingMerge.swift
//  Rivulet
//
//  One Continue Watching row across every server (#87), for both apps. The same title on two
//  servers, or in two libraries of one server (#470), becomes one card, matched only on ids (never on title: a wrong merge
//  hides a show, a duplicate is only untidy). Episodes collapse per SHOW, since
//  Plex and Jellyfin keep separate watch state and one show can sit at a
//  different episode on each; the card shows the copy watched last.
//

import Foundation

enum ContinueWatchingMerge {
    /// One card: the copy shown, then the same title's copies on other servers.
    struct Card<Item> {
        var item: Item
        var others: [Item]
        var copies: [Item] { [item] + others }
    }

    /// Merges each server's row, `rows` in server order (the selected Plex server
    /// first). `keys` gives an item's identity keys, `watched` its last watch.
    /// With one contributing row, that server's own order stands.
    static func merge<Item>(_ rows: [[Item]], keys: (Item) -> [String], watched: (Item) -> Date?) -> [Card<Item>] {
        let contributing = rows.filter { !$0.isEmpty }
        func date(_ item: Item) -> Date { watched(item) ?? .distantPast }
        // Union by shared key: the first group that holds any key wins.
        var groups: [[(item: Item, rank: Int)]] = []
        var groupForKey: [String: Int] = [:]
        var rank = 0
        for row in contributing {
            for item in row {
                defer { rank += 1 }
                let itemKeys = keys(item)
                let hits = Set(itemKeys.compactMap { groupForKey[$0] })
                let target: Int
                if let first = hits.min() {
                    target = first
                    // A bridge between two groups folds the later into the first.
                    for other in hits.subtracting([first]).sorted(by: >) {
                        groups[first] += groups[other]
                        groups[other] = []
                        for (key, index) in groupForKey where index == other { groupForKey[key] = first }
                    }
                } else {
                    target = groups.count
                    groups.append([])
                }
                groups[target].append((item, rank))
                for key in itemKeys { groupForKey[key] = target }
            }
        }
        let cards = groups.filter { !$0.isEmpty }.map { group -> (card: Card<Item>, rank: Int) in
            // Latest watch wins; a tie (synced Plex servers) keeps server order.
            let ordered = group.sorted { (date($0.item), $1.rank) > (date($1.item), $0.rank) }
            return (Card(item: ordered[0].item, others: ordered.dropFirst().map(\.item)), group.map(\.rank).min() ?? 0)
        }
        if contributing.count == 1 { return cards.sorted { $0.rank < $1.rank }.map(\.card) }
        return cards.sorted { (date($0.card.item), $1.rank) > (date($1.card.item), $0.rank) }.map(\.card)
    }

    // MARK: - Identity keys

    /// The scope a key names: one movie, or one show for its episodes and seasons.
    /// tmdb and tvdb reuse numbers across movies and TV, so every key carries it.
    /// `type` is Plex's ("movie", "show", "season", "episode").
    static func scope(ofType type: String?) -> String? {
        switch type {
        case "movie": "m"
        case "show", "season", "episode": "s"
        default: nil
        }
    }

    /// Keys from a Plex item: its agent guid ("plex://movie/…", a legacy
    /// "com.plexapp.agents.thetvdb://80379?lang=en") and, for a movie, the
    /// `Guid` ids. An episode's `Guid` ids are the episode's own, so it keys on
    /// its show's guid only.
    static func plexKeys(type: String?, guid: String?, showGuid: String?, guids: [String]) -> [String] {
        guard let scope = scope(ofType: type) else { return [] }
        let own = type == "movie" ? [guid].compactMap { $0 } + guids : [showGuid].compactMap { $0 }
        return own.compactMap { key(fromPlexGuid: $0, scope: scope) }
    }

    /// `plexKeys` for a Plex item as both apps decode it.
    static func plexKeys(_ meta: PlexMetadata) -> [String] {
        plexKeys(type: meta.type, guid: meta.guid,
                 showGuid: meta.type == "season" ? meta.parentGuid : meta.grandparentGuid,
                 guids: (meta.Guid ?? []).compactMap(\.id))
    }

    /// A Plex show's own keys: its agent guid plus its external ids.
    static func plexShowKeys(_ show: PlexMetadata) -> [String] {
        ([show.guid].compactMap { $0 } + (show.Guid ?? []).compactMap(\.id))
            .compactMap { key(fromPlexGuid: $0, scope: "s") }
    }

    /// Keys from external ids as Jellyfin names them ("Imdb", "Tmdb", "Tvdb").
    static func providerIDKeys(_ ids: [String: String], scope: String) -> [String] {
        ids.compactMap { name, value in
            guard !value.isEmpty else { return nil }
            switch name.lowercased() {
            case "imdb": return "\(scope):imdb:\(value)"
            case "tmdb": return "\(scope):tmdb:\(value)"
            case "tvdb": return "\(scope):tvdb:\(value)"
            default: return nil
            }
        }.sorted()
    }

    static func key(fromPlexGuid guid: String, scope: String) -> String? {
        let bare = guid.split(separator: "?").first.map(String.init) ?? guid
        guard let range = bare.range(of: "://") else { return nil }
        let agent = bare[..<range.lowerBound]
        let value = bare[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        switch agent {
        case "plex":
            // "plex://movie/<id>", "plex://show/<id>": the type is the first part.
            let parts = bare[range.upperBound...].split(separator: "/")
            guard parts.count == 2, ["movie", "show"].contains(parts[0]) else { return nil }
            return "\(scope):plex:\(parts[1])"
        case "imdb", "com.plexapp.agents.imdb": return value.isEmpty ? nil : "\(scope):imdb:\(value)"
        case "tmdb", "com.plexapp.agents.themoviedb": return value.isEmpty ? nil : "\(scope):tmdb:\(value)"
        case "tvdb", "com.plexapp.agents.thetvdb": return value.isEmpty ? nil : "\(scope):tvdb:\(value)"
        default: return nil
        }
    }
}
