// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveSmartList.swift
//  Rivulet
//
//  A channel list that fills itself from rules, as a smart playlist does:
//  channels from a country or in a language, of a genre, from a source, or
//  with a word in their name. Rules of one kind widen the list (Netherlands
//  or Belgium); rules of different kinds narrow it (Netherlands and Sports).
//  The list follows the lineup, so new channels join it on their own.
//
//  A channel's country is the tag its category carries ("┃NL┃ Sports"), else
//  one on its own name. Its genre is read from its category, then its name,
//  then what its guide mostly airs; what it airs right now does not count,
//  so a list holds still between programmes.
//

import Foundation

struct LiveSmartRules: Codable, Hashable {
    /// `ContentOrigin.origin` keys.
    var origins: [String] = []
    /// `LiveGenre` raw values.
    var genres: [String] = []
    var sourceIds: [String] = []
    /// Words a channel's name must hold, folded as search folds them.
    var words: [String] = []

    enum Rule: Hashable {
        case origin(String)
        case genre(LiveGenre)
        case source(String)
        case word(String)
    }

    init(_ rules: [Rule] = []) {
        for rule in rules { add(rule) }
    }

    var rules: [Rule] {
        origins.map(Rule.origin) + genres.compactMap { LiveGenre(rawValue: $0).map(Rule.genre) }
            + sourceIds.map(Rule.source) + words.map(Rule.word)
    }

    var isEmpty: Bool { rules.isEmpty }

    func contains(_ rule: Rule) -> Bool { rules.contains(rule) }

    mutating func add(_ rule: Rule) {
        guard !contains(rule) else { return }
        switch rule {
        case .origin(let key): origins.append(key)
        case .genre(let genre): genres.append(genre.rawValue)
        case .source(let id): sourceIds.append(id)
        case .word(let word):
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !words.contains(trimmed) { words.append(trimmed) }
        }
    }

    mutating func remove(_ rule: Rule) {
        switch rule {
        case .origin(let key): origins.removeAll { $0 == key }
        case .genre(let genre): genres.removeAll { $0 == genre.rawValue }
        case .source(let id): sourceIds.removeAll { $0 == id }
        case .word(let word): words.removeAll { $0 == word }
        }
    }

    /// The store's change counters (`LiveTVDataStore.lineupVersions`): matches are kept per value.
    struct Versions: Hashable {
        let channels: Int
        let epg: Int
    }

    /// The channels that match, in lineup order. No rules match nothing.
    func channels(in lineup: [UnifiedChannel], epg: [String: [UnifiedProgram]] = [:],
                  versions: Versions? = nil) -> [UnifiedChannel] {
        indices(in: lineup, epg: epg, versions: versions).map { lineup[$0] }
    }

    /// The positions in `lineup` that match. With `versions`, kept until the lineup (or, for a
    /// genre rule, the guide) changes: the List and the guide ask on every refresh, and a large
    /// lineup takes a moment to match. Without, matched afresh.
    func indices(in lineup: [UnifiedChannel], epg: [String: [UnifiedProgram]] = [:],
                 versions: Versions? = nil) -> [Int] {
        guard !isEmpty else { return [] }
        guard let versions else { return match(lineup, epg: epg) }
        // The lineup's ends and size tell a source-filtered lineup from the whole one.
        let key = MatchKey(rules: self, channels: versions.channels, epg: genres.isEmpty ? 0 : versions.epg,
                           count: lineup.count, first: lineup.first?.id, last: lineup.last?.id)
        if let known = Self.matches[key] { return known }
        let found = match(lineup, epg: epg)
        if Self.matches.count > 64 { Self.matches.removeAll() }
        Self.matches[key] = found
        return found
    }

    /// Whether a guide change can change the matches.
    var readsGuide: Bool { !genres.isEmpty }

    private struct MatchKey: Hashable {
        let rules: LiveSmartRules
        let channels: Int
        let epg: Int
        let count: Int
        let first: String?
        let last: String?
    }
    private static var matches: [MatchKey: [Int]] = [:]

    private func match(_ lineup: [UnifiedChannel], epg: [String: [UnifiedProgram]]) -> [Int] {
        let origins = Set(origins), genres = Set(genres.compactMap(LiveGenre.init(rawValue:)))
        let sources = Set(sourceIds), words = words.map(LiveChannelSearch.normalized)
        // Per category rather than per channel: a lineup has thousands of channels in a few hundred groups.
        var originByGroup: [String: String?] = [:]
        var genreByGroup: [String: LiveGenre?] = [:]
        return lineup.indices.filter { index in
            let channel = lineup[index]
            if !sources.isEmpty, !sources.contains(channel.sourceId) { return false }
            let group = channel.groupTitle ?? ""
            if !origins.isEmpty {
                let fromGroup: String?
                if let known = originByGroup[group] { fromGroup = known } else {
                    fromGroup = ContentOrigin.origin(forTags: XtreamService.splitTags(group).tags)
                    originByGroup[group] = fromGroup
                }
                let origin = fromGroup ?? ContentOrigin.origin(forTags: XtreamService.splitTags(channel.name).tags)
                guard let origin, origins.contains(origin) else { return false }
            }
            if !genres.isEmpty {
                let fromGroup: LiveGenre?
                if let known = genreByGroup[group] { fromGroup = known } else {
                    fromGroup = LiveGenre.from(XtreamService.splitTags(group).name)
                    genreByGroup[group] = fromGroup
                }
                guard let genre = fromGroup ?? Self.genre(of: channel, epg: epg), genres.contains(genre) else { return false }
            }
            if !words.isEmpty {
                let name = LiveChannelSearch.normalized(channel.name)
                guard words.contains(where: name.contains) else { return false }
            }
            return true
        }
    }

    /// The genre a channel's name says, else what most of its next programmes are.
    private static func genre(of channel: UnifiedChannel, epg: [String: [UnifiedProgram]]) -> LiveGenre? {
        if let genre = LiveGenre.from(channel.name) { return genre }
        var counts: [LiveGenre: Int] = [:]
        for program in (epg[channel.id] ?? []).prefix(12) {
            if let genre = LiveGenre.from(program.category) { counts[genre, default: 0] += 1 }
        }
        guard let best = counts.values.max() else { return nil }
        return LiveGenre.allCases.first { counts[$0] == best }
    }

    // MARK: - Choices

    /// The countries and languages found in a lineup, by name.
    static func origins(in lineup: [UnifiedChannel]) -> [String] {
        var groups = Set<String>(), found = Set<String>()
        for channel in lineup {
            let group = channel.groupTitle ?? ""
            if groups.insert(group).inserted,
               let origin = ContentOrigin.origin(forTags: XtreamService.splitTags(group).tags) {
                found.insert(origin)
            }
        }
        let symbols: Set<String> = ["MULTI", "INT", "WORLD", "ASIA", "AFRICA"]
        // By name, the flag aside: "Arabic" among the A's.
        func name(_ key: String) -> String {
            let title = ContentOrigin.title(forOrigin: key), marker = ContentOrigin.marker(forOrigin: key)
            return title.hasPrefix(marker + " ") ? String(title.dropFirst(marker.count + 1)) : title
        }
        let places = found.subtracting(symbols).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        return places + found.intersection(symbols).sorted()
    }

    /// A rule as a menu row or a list's name.
    static func title(of rule: Rule, sourceNames: [String: String] = [:]) -> String {
        switch rule {
        case .origin(let key): return ContentOrigin.title(forOrigin: key)
        case .genre(let genre): return genre.title
        case .source(let id): return sourceNames[id] ?? id
        case .word(let word): return String(localized: "Name Contains \u{201C}\(word)\u{201D}")
        }
    }

    /// A name for a new list from its first rule: "🇳🇱 Netherlands", "Sports", "BBC".
    static func suggestedName(for rule: Rule, sourceNames: [String: String] = [:]) -> String {
        if case .word(let word) = rule { return word }
        return title(of: rule, sourceNames: sourceNames)
    }
}

/// A smart list being made or changed in the iOS and Mac editor: the rules as switches, the
/// words as one comma-separated field, and a name that defaults to the first rule's.
struct LiveSmartListDraft {
    let listId: String?
    var name: String
    var rules: LiveSmartRules
    var wordsText: String

    init(listId: String?, store: LiveChannelListStore = .shared) {
        self.listId = listId
        let list = listId.flatMap(store.list)
        name = list?.name ?? ""
        var rules = list?.rules ?? LiveSmartRules()
        wordsText = rules.words.joined(separator: ", ")
        rules.words = []
        self.rules = rules
    }

    /// The rules with the words field read in.
    var finalRules: LiveSmartRules {
        var result = rules
        for word in wordsText.split(separator: ",") { result.add(.word(String(word))) }
        return result
    }

    var canSave: Bool { !finalRules.isEmpty }

    func isOn(_ rule: LiveSmartRules.Rule) -> Bool { rules.contains(rule) }

    mutating func set(_ rule: LiveSmartRules.Rule, on: Bool) {
        if on { rules.add(rule) } else { rules.remove(rule) }
    }

    /// Saves and returns the list's id; a blank name takes the first rule's.
    @discardableResult
    func save(store: LiveChannelListStore = .shared, sourceNames: [String: String] = [:]) -> String? {
        let rules = finalRules
        guard let first = rules.rules.first else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? LiveSmartRules.suggestedName(for: first, sourceNames: sourceNames) : trimmed
        if let listId {
            store.rename(listId, to: title)
            store.setRules(rules, for: listId)
            return listId
        }
        return store.createSmartList(named: title, rules: rules)?.id
    }
}

extension LiveChannelList {
    /// A guide filter's value for a list, beside the groups' titles.
    static let filterPrefix = "list:"

    var filterTag: String { Self.filterPrefix + id }

    /// The list a guide filter names, if it names one.
    static func forFilter(_ filter: String, store: LiveChannelListStore = .shared) -> LiveChannelList? {
        guard filter.hasPrefix(filterPrefix) else { return nil }
        return store.list(String(filter.dropFirst(filterPrefix.count)))
    }
}
