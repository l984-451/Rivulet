// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelSearch.swift
//  Rivulet
//
//  Looking up a channel: by name, call sign or number, and by what it airs
//  now. Case, accents and the separators providers put in names ("| NL |")
//  are ignored. Data only; each app draws the results its own way.
//

import Combine
import Foundation

nonisolated enum LiveChannelSearch {
    /// The lineup prepared once for searching, with what each channel airs
    /// at `now`: a large IPTV lineup has tens of thousands of channels, and
    /// every keystroke searches it. Rebuild it as the guide or the clock moves.
    struct Index: Sendable {
        fileprivate struct Entry: Sendable {
            let channel: UnifiedChannel
            let name: String
            let words: [Substring]
            let callSign: String
            let number: String?
            let current: UnifiedProgram?
            let currentTitle: String
        }
        fileprivate let entries: [Entry]

        init(_ channels: [UnifiedChannel], epg: [String: [UnifiedProgram]] = [:], now: Date = Date()) {
            var seen = Set<String>()
            entries = channels.filter { seen.insert($0.id).inserted }.map { channel in
                let name = LiveChannelSearch.normalized(channel.name)
                let current = epg[channel.id]?.first { $0.endTime > now }
                    .flatMap { $0.startTime <= now && !$0.id.contains(":placeholder:") ? $0 : nil }
                return Entry(channel: channel, name: name, words: name.split(separator: " "),
                             callSign: channel.callSign.map(LiveChannelSearch.normalized) ?? "",
                             number: channel.channelNumber.map(String.init),
                             current: current, currentTitle: current.map { LiveChannelSearch.normalized($0.title) } ?? "")
            }
        }
    }

    struct Results: Sendable {
        /// Channels whose name, call sign or number matches, best first.
        var channels: [UnifiedChannel] = []
        /// Programmes airing now whose title matches, with their channel.
        var onNow: [(channel: UnifiedChannel, program: UnifiedProgram)] = []

        var isEmpty: Bool { channels.isEmpty && onNow.isEmpty }
    }

    /// Lowercased, accents folded, every run of anything but letters and
    /// digits made one space.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSpace = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(character)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Channels and programmes on now for `query`. Every word of the query
    /// must match; an empty query finds nothing.
    static func search(_ query: String, in index: Index, channelLimit: Int = 100, programLimit: Int = 50) -> Results {
        let query = normalized(query)
        let tokens = query.split(separator: " ")
        guard !tokens.isEmpty else { return Results() }

        // Lower ranks first: the channel number itself, the whole name, a
        // name starting with the query, every word starting a word, anywhere.
        func rank(_ entry: Index.Entry) -> Int? {
            if let number = entry.number, number == query { return 0 }
            if entry.name == query || entry.callSign == query { return 1 }
            if entry.name.hasPrefix(query) { return 2 }
            if tokens.allSatisfy({ token in entry.words.contains { $0.hasPrefix(token) } }) { return 3 }
            if tokens.allSatisfy({ entry.name.contains($0) || entry.callSign.contains($0) }) { return 4 }
            return nil
        }
        var ranked: [(rank: Int, position: Int, channel: UnifiedChannel)] = []
        for (position, entry) in index.entries.enumerated() {
            if let rank = rank(entry) { ranked.append((rank, position, entry.channel)) }
        }
        ranked.sort { ($0.rank, $0.position) < ($1.rank, $1.position) }

        var onNow: [(rank: Int, position: Int, channel: UnifiedChannel, program: UnifiedProgram)] = []
        for (position, entry) in index.entries.enumerated() {
            guard let program = entry.current, tokens.allSatisfy({ entry.currentTitle.contains($0) }) else { continue }
            onNow.append((entry.currentTitle.hasPrefix(query) ? 0 : 1, position, entry.channel, program))
        }
        onNow.sort { ($0.rank, $0.position) < ($1.rank, $1.position) }

        return Results(channels: ranked.prefix(channelLimit).map(\.channel),
                       onNow: onNow.prefix(programLimit).map { ($0.channel, $0.program) })
    }
}

/// A search field's channel results on iOS and the Mac, through the same index and ranking as
/// tvOS: the index is built off the main thread once per lineup and guide, and typing runs one
/// search per pause rather than per letter. Channels that match, then those airing a match.
@MainActor
final class LiveChannelSearcher: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { run() } }
    }
    @Published private(set) var results: [UnifiedChannel] = []
    /// A search is waiting on the index or the pause.
    @Published private(set) var isSearching = false

    private let store: LiveTVDataStore
    private var index: LiveChannelSearch.Index?
    private var indexedVersions: LiveSmartRules.Versions?
    /// The lineup and guide the index in flight is built from.
    private var buildingVersions: LiveSmartRules.Versions?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(store: LiveTVDataStore = .shared) {
        self.store = store
    }

    private func run() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        guard let index, indexedVersions == store.lineupVersions else { return buildIndex() }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                LiveChannelSearch.search(trimmed, in: index)
            }.value
            guard let self, !Task.isCancelled else { return }
            var seen = Set(found.channels.map(\.id))
            self.results = found.channels + found.onNow.map(\.channel).filter { seen.insert($0.id).inserted }
            self.isSearching = false
        }
    }

    private func buildIndex() {
        let versions = store.lineupVersions
        // Already building this one: the search runs when it lands, not on every keystroke.
        guard buildingVersions != versions else { return }
        indexTask?.cancel()
        buildingVersions = versions
        let channels = store.channels, epg = store.epg
        indexTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                LiveChannelSearch.Index(channels, epg: epg, now: Date())
            }.value
            guard let self, !Task.isCancelled else { return }
            self.index = built
            self.indexedVersions = versions
            self.buildingVersions = nil
            self.indexTask = nil
            self.run()
        }
    }
}
