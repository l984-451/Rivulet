// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

// What one server finds for a search: titles named like the query, the people, and a shelf of
// titles for each collection or genre whose name matches.

import Foundation

nonisolated struct SearchHits: Sendable {
    /// Movies, shows, seasons and episodes, best match first.
    var titles: [MediaItem] = []
    /// Cast and crew, best match first. Each carries this server's `providerID`.
    var people: [MediaPerson] = []
    /// Collections first, then genres.
    var shelves: [SearchShelf] = []

    var isEmpty: Bool { titles.isEmpty && people.isEmpty && shelves.isEmpty }

    /// Most of each kind a server returns, and how many shelves it fills.
    static let peopleLimit = 20
    static let collectionLimit = 3
    static let genreLimit = 2
    static let shelfItemLimit = 40

    /// The first of each list, then the second of each, and so on.
    static func interleaved<T>(_ lists: [[T]]) -> [T] {
        var out: [T] = []
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count { out.append(list[i]) }
        }
        return out
    }
}

nonisolated struct SearchShelf: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case collection, genre }
    let kind: Kind
    let name: String
    var items: [MediaItem]
}

/// How well a name matches a query, by the rules Plex and Jellyfin rank on: the whole name, then
/// its start (a leading article skipped), then the start of a word, then anywhere in it.
nonisolated enum SearchRank: Int, Comparable, Sendable {
    case none, contains, wordPrefix, prefix, exact

    static func < (a: SearchRank, b: SearchRank) -> Bool { a.rawValue < b.rawValue }

    static func of(_ name: String, query: String) -> SearchRank {
        let q = normalized(query)
        let n = normalized(name)
        guard !q.isEmpty, !n.isEmpty else { return .none }
        let bare = withoutArticle(n)
        if n == q || bare == q { return .exact }
        if n.hasPrefix(q) || bare.hasPrefix(q) { return .prefix }
        if (" " + n).contains(" " + q) { return .wordPrefix }
        return n.contains(q) ? .contains : .none
    }

    /// A title's best rank over its name and sort name.
    static func of(_ item: MediaItem, query: String) -> SearchRank {
        max(of(item.title, query: query), item.sortTitle.map { of($0, query: query) } ?? .none)
    }

    /// Lowercased, accents folded, punctuation dropped ("Ocean's" is "oceans"), spaces collapsed.
    static func normalized(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out = ""
        var pendingSpace = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else if ch.isWhitespace || ch == "-" || ch == "_" || ch == "." || ch == "," || ch == ":" {
                pendingSpace = true
            }
        }
        return out
    }

    private static func withoutArticle(_ n: String) -> String {
        for article in ["the ", "a ", "an "] where n.hasPrefix(article) {
            return String(n.dropFirst(article.count))
        }
        return n
    }

    /// The entries whose name ranks at least `minimum`, best first (ties keep their order), at most `limit`.
    static func matching<T>(_ entries: [T], query: String, minimum: SearchRank = .wordPrefix, limit: Int,
                            name: (T) -> String) -> [T] {
        let ranks: [SearchRank] = entries.map { of(name($0), query: query) }
        let kept: [Int] = stableBest(entries.indices.filter { ranks[$0] >= minimum }, ranks: ranks)
        return kept.prefix(limit).map { entries[$0] }
    }

    /// `titles` best match first, the server's own order kept within a rank. An episode or season
    /// has to match on its own name: servers also return every episode of a matching show.
    static func ranked(_ titles: [MediaItem], query: String) -> [MediaItem] {
        let ranks: [SearchRank] = titles.map { of($0, query: query) }
        let kept: [Int] = titles.indices.filter { index in
            let kind = titles[index].kind
            return ranks[index] > .none || (kind != .episode && kind != .season)
        }
        return stableBest(kept, ranks: ranks).map { titles[$0] }
    }

    /// Indices by rank, best first, ascending index within a rank.
    private static func stableBest(_ indices: [Int], ranks: [SearchRank]) -> [Int] {
        indices.sorted { a, b in
            if ranks[a] != ranks[b] { return ranks[a] > ranks[b] }
            return a < b
        }
    }
}
