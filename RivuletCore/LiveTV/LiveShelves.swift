// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveShelves.swift
//  Rivulet
//
//  What's On: the rows of Live TV cards (Recently Watched, For You, Recordings,
//  Favorites, On Now, Starting Soon, then one per genre and per channel group).
//  Data only; each app draws the cards its own way.
//

import Foundation

/// One What's On row.
nonisolated struct LiveShelf: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [LiveCardItem]

    /// Rows of stand-in cards until the first rows are built, so the real ones land in place.
    /// The title is a space so a header keeps its height.
    static let placeholders: [LiveShelf] = (0..<3).map { row in
        LiveShelf(id: "placeholder|\(row)", title: " ", items: (0..<8).map { index in
            LiveCardItem(id: "placeholder|\(row)|\(index)", kind: .channel,
                         channel: UnifiedChannel(id: "placeholder", sourceType: .genericM3U, sourceId: "",
                                                 name: "Channel name"),
                         program: nil, recording: nil)
        })
    }
}

/// One card's content.
nonisolated struct LiveCardItem: Hashable, Identifiable, Sendable {
    enum Kind: Hashable {
        /// A channel and what is on it now.
        case channel
        /// A programme starting soon on `channel`.
        case upcoming
        /// A recording Plex or Dispatcharr has lined up.
        case recording
    }

    let id: String
    let kind: Kind
    let channel: UnifiedChannel?
    let program: UnifiedProgram?
    let recording: LiveTVScheduledRecording?
    /// The programme is set to record (see `markingRecordings`).
    var setToRecord = false

    /// A stand-in from `LiveShelf.placeholders`: drawn blank, never focused or played.
    var isPlaceholder: Bool { id.hasPrefix("placeholder|") }

    static func channel(_ channel: UnifiedChannel, program: UnifiedProgram?, section: String) -> LiveCardItem {
        LiveCardItem(id: "\(section)|\(channel.id)", kind: .channel, channel: channel,
                     program: program, recording: nil)
    }

    /// An upcoming card's start: the time alone today, with the weekday after. Formatted in
    /// `calendar`'s zone, the one that decided "today".
    static func startLabel(_ program: UnifiedProgram, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = program.eventStart
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        return calendar.isDate(start, inSameDayAs: now)
            ? start.formatted(style.hour().minute())
            : start.formatted(style.weekday().hour().minute())
    }

    static func upcoming(_ program: UnifiedProgram, on channel: UnifiedChannel, section: String = "soon") -> LiveCardItem {
        LiveCardItem(id: "\(section)|\(program.id)", kind: .upcoming, channel: channel,
                     program: program, recording: nil)
    }

    static func recording(_ recording: LiveTVScheduledRecording, channel: UnifiedChannel?) -> LiveCardItem {
        LiveCardItem(id: "rec|\(recording.id)", kind: .recording, channel: channel,
                     program: nil, recording: recording)
    }
}

extension Array where Element == LiveCardItem {
    /// Each card's `setToRecord`, from the schedule. Recording cards already
    /// say so themselves.
    nonisolated func markingRecordings(_ recordings: [LiveTVScheduledRecording]) -> [LiveCardItem] {
        map { item in
            guard item.kind != .recording, let program = item.program else { return item }
            var marked = item
            marked.setToRecord = LiveTVDataStore.activeRecording(for: program, in: recordings) != nil
            return marked
        }
    }

    /// First of each id. A diffable snapshot traps on a repeated identifier,
    /// and a merged lineup can list a channel twice.
    nonisolated func uniquedById() -> [LiveCardItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension LiveTVDataStore {
    /// The What's On rows for a source (nil: every source). Rows may be empty.
    /// `favoritesOnly`: the Favorites row alone, for Home, without the rows it does not show.
    func whatsOnShelves(sourceIdFilter: String?, now: Date = Date(), favoritesOnly: Bool = false) -> [LiveShelf] {
        LiveShelves.build(shelvesInput, sourceIdFilter: sourceIdFilter, now: now, favoritesOnly: favoritesOnly)
    }

    /// For You and the genre rows alone (the List's), as What's On picks them. Kept until the
    /// lineup, guide, history or five-minute window changes: the List asks on every refresh,
    /// and a large lineup takes a moment.
    func liveDiscovery(sourceIdFilter: String?, now: Date = Date()) -> LiveShelves.Discovery {
        // The newest viewing too: history is capped, so a full one keeps its count.
        let key = DiscoveryKey(versions: lineupVersions, recent: recentChannelIds, viewings: viewings.count,
                               lastViewing: viewings.last?.at,
                               source: sourceIdFilter,
                               window: Int(now.timeIntervalSince1970 / 300))
        if let cached = Self.discoveryCache, cached.key == key { return cached.value }
        let found = LiveShelves.discovery(shelvesInput, sourceIdFilter: sourceIdFilter, now: now)
        Self.discoveryCache = (key, found)
        return found
    }

    private struct DiscoveryKey: Equatable {
        let versions: LiveSmartRules.Versions
        let recent: [String]
        let viewings: Int
        let lastViewing: Date?
        let source: String?
        let window: Int
    }
    private static var discoveryCache: (key: DiscoveryKey, value: LiveShelves.Discovery)?

    /// The same rows, built off the main thread: a large guide takes seconds to sort (RIVULET-I).
    func whatsOnShelvesInBackground(sourceIdFilter: String?, now: Date = Date()) async -> [LiveShelf] {
        await LiveShelves.buildInBackground(shelvesInput, sourceIdFilter: sourceIdFilter, now: now)
    }

    private var shelvesInput: LiveShelves.Input {
        LiveShelves.Input(
            channels: channels, epg: epg, recentChannelIds: recentChannelIds, favoriteIds: favoriteIds,
            unfavoritedIds: unfavoritedIds, eventSlotIds: eventSlotIds, viewings: viewings,
            scheduledRecordings: scheduledRecordings,
            sourceNames: Dictionary(sources.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }))
    }
}

nonisolated enum LiveShelves {
    /// The store state the rows are built from.
    struct Input {
        var channels: [UnifiedChannel]
        var epg: [String: [UnifiedProgram]]
        var recentChannelIds: [String] = []
        var favoriteIds: [String] = []
        var unfavoritedIds: Set<String> = []
        var eventSlotIds: Set<String> = []
        var viewings: [LiveViewing] = []
        var suggestionsEnabled = true
        var scheduledRecordings: [LiveTVScheduledRecording] = []
        /// Source display names by source id, for the per-source rows.
        var sourceNames: [String: String] = [:]
    }

    /// For You and the genre rows: what What's On and the List share.
    struct Discovery {
        /// Like what this viewer watches at this hour, best first; empty below three picks.
        var forYou: [UnifiedChannel] = []
        /// Each genre airing now with its channels, in lineup order; empty unless the lineup
        /// spans more than one genre with three channels or more.
        var byGenre: [(genre: LiveGenre, channels: [UnifiedChannel])] = []
    }

    /// Each airing channel's genre is worked out once, for both: a large lineup takes a moment.
    /// A shelf per genre by what each channel shows now, so cards move rows at programme
    /// boundaries (a local station that usually airs sports is not sports during church).
    private static func discovery(airing: [UnifiedChannel], current: (UnifiedChannel) -> UnifiedProgram?,
                                  input: Input, now: Date) -> Discovery {
        let epg = input.epg
        var result = Discovery()
        let genres = airing.map { channel in
            LiveGenre.of(channel, airing: current(channel), guide: epg[channel.id] ?? [])
        }
        // Like what this viewer watches at this hour, from what is on now. Recently Watched
        // already covers going back, so its channels are left out.
        if input.suggestionsEnabled {
            let recentIds = Set(input.recentChannelIds)
            let candidates: [LiveSuggestions.Candidate] = zip(airing, genres).compactMap { channel, genre in
                recentIds.contains(channel.id) ? nil : (channel: channel, program: current(channel), genre: genre)
            }
            let picks = LiveSuggestions.rank(candidates, history: input.viewings, now: now)
            if picks.count >= 3 { result.forYou = picks }
        }
        var byGenre: [LiveGenre: [UnifiedChannel]] = [:]
        for (channel, genre) in zip(airing, genres) {
            if let genre { byGenre[genre, default: []].append(channel) }
        }
        let shown = LiveGenre.allCases.filter { (byGenre[$0] ?? []).count >= 3 }
        if shown.count > 1 { result.byGenre = shown.map { ($0, byGenre[$0] ?? []) } }
        return result
    }

    /// For You and the genre rows alone, for the List: without the rest of What's On.
    static func discovery(_ input: Input, sourceIdFilter: String?, now: Date) -> Discovery {
        var memo: [String: UnifiedProgram?] = [:]
        func current(_ channel: UnifiedChannel) -> UnifiedProgram? {
            if let known = memo[channel.id] { return known }
            let program = input.epg[channel.id]?.first { $0.startTime <= now && $0.endTime > now }
            memo[channel.id] = program
            return program
        }
        let all = sourceIdFilter.map { id in input.channels.filter { $0.sourceId == id } } ?? input.channels
        // As What's On: showing something now, not an empty event slot or a slot held for a later game.
        let airing = all.filter { channel in
            guard let program = current(channel) else { return !input.eventSlotIds.contains(channel.id) }
            return !program.isEmptySlot && !program.isPregameBlock
        }
        return discovery(airing: airing, current: current, input: input, now: now)
    }

    @concurrent static func buildInBackground(_ input: Input, sourceIdFilter: String?, now: Date) async -> [LiveShelf] {
        build(input, sourceIdFilter: sourceIdFilter, now: now)
    }

    static func build(_ input: Input, sourceIdFilter: String?, now: Date, favoritesOnly: Bool = false) -> [LiveShelf] {
        let epg = input.epg
        // Each row asks again for the same channel; scan its guide once per build.
        var currentMemo: [String: UnifiedProgram?] = [:]
        var nextMemo: [String: UnifiedProgram?] = [:]
        func current(_ channel: UnifiedChannel) -> UnifiedProgram? {
            if let memo = currentMemo[channel.id] { return memo }
            let program = epg[channel.id]?.first { $0.startTime <= now && $0.endTime > now }
            currentMemo[channel.id] = program
            return program
        }
        func next(_ channel: UnifiedChannel) -> UnifiedProgram? {
            if let memo = nextMemo[channel.id] { return memo }
            let program = epg[channel.id]?.first { $0.startTime > now }
            nextMemo[channel.id] = program
            return program
        }

        let all = sourceIdFilter.map { id in input.channels.filter { $0.sourceId == id } } ?? input.channels
        // An event slot with no game on ("No game scheduled", or a gap in its
        // guide between games) has nothing to show.
        func offAir(_ channel: UnifiedChannel) -> Bool {
            guard let program = current(channel) else { return input.eventSlotIds.contains(channel.id) }
            return program.isEmptySlot
        }
        let channels = all.filter { !offAir($0) }
        let channelsById = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var shelves: [LiveShelf] = []

        func onNow(_ list: [UnifiedChannel], section: String) -> [LiveCardItem] {
            list.map { channel in
                let program = current(channel)
                // A pregame block stands in for the game after it: the card is the game.
                guard let block = program, block.isPregameBlock else {
                    return .channel(channel, program: program, section: section)
                }
                return .upcoming(next(channel) ?? block, on: channel, section: section)
            }
        }
        // Favorites and Recently Watched: an off-air slot shows its next game
        // if the guide has one, else nothing.
        func chosen(_ list: [UnifiedChannel], section: String) -> [LiveCardItem] {
            list.compactMap { channel in
                guard offAir(channel) else { return onNow([channel], section: section).first }
                let games = (epg[channel.id] ?? []).filter { $0.startTime > now && !$0.isEmptySlot }
                guard let game = games.first else { return nil }
                return .upcoming(game.isPregameBlock ? games.dropFirst().first ?? game : game,
                                 on: channel, section: section)
            }
        }
        // Channels showing something now, not holding a slot for a later game.
        let airing = channels.filter { current($0)?.isPregameBlock != true }

        // Channels played lately, newest first, to go straight back to one.
        let recent = chosen(input.recentChannelIds.compactMap { channelsById[$0] }, section: "recent")
        if !recent.isEmpty {
            shelves.append(LiveShelf(id: "recent", title: String(localized: "Recently Watched"), items: recent))
        }

        // Home's Favorites row needs none of this, and a large lineup takes a moment to rank.
        let found = favoritesOnly ? Discovery() : discovery(airing: airing, current: current, input: input, now: now)
        if !found.forYou.isEmpty {
            shelves.append(LiveShelf(id: "foryou", title: String(localized: "For You"),
                                     items: onNow(Array(found.forYou.prefix(20)), section: "foryou")))
        }

        // What is being recorded or about to be.
        let recordings = input.scheduledRecordings
            .filter { ($0.status == .scheduled || $0.status == .recording) && $0.endTime > now }
            .filter { sourceIdFilter == nil || $0.sourceId == sourceIdFilter }
            .sorted { $0.startTime < $1.startTime }
            .prefix(30)
            .map { recording in
                LiveCardItem.recording(recording, channel: recording.channelId.flatMap { channelsById[$0] })
            }
        if !recordings.isEmpty {
            shelves.append(LiveShelf(id: "recordings", title: String(localized: "Recordings"), items: recordings))
        }

        let favourites = chosen(LiveTVDataStore.favorites(in: all, order: input.favoriteIds,
                                                         unfavorited: input.unfavoritedIds), section: "favorites")
        if !favourites.isEmpty {
            shelves.append(LiveShelf(id: "favorites", title: String(localized: "Favorites"), items: favourites))
        }
        if favoritesOnly { return shelves.filter { $0.id == "favorites" } }

        if !airing.isEmpty {
            shelves.append(LiveShelf(id: "now", title: String(localized: "On Now"), items: onNow(Array(airing.prefix(150)), section: "now")))
        }

        // The next programme on each channel that starts within the next
        // ninety minutes: what this viewer watches when each one starts
        // first, then soonest first.
        let horizon = now.addingTimeInterval(90 * 60)
        let upcoming = all.compactMap { channel -> LiveSuggestions.Candidate? in
            guard let next = next(channel),
                  !next.id.contains(":placeholder:"), !next.isEmptySlot,
                  next.startTime > now, next.startTime <= horizon else { return nil }
            return (channel, next, LiveGenre.of(channel, airing: next, guide: epg[channel.id] ?? []))
        }
        let likeness = input.suggestionsEnabled
            ? LiveSuggestions.scores(upcoming.map { ($0, $0.program?.startTime ?? now) },
                                     history: input.viewings, now: now)
            : upcoming.map { _ in 0 }
        let soon = zip(upcoming, likeness.map { $0 >= LiveSuggestions.threshold ? $0 : 0 })
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1
                : ($0.0.program?.startTime ?? now) < ($1.0.program?.startTime ?? now) }
            .prefix(40)
            .compactMap { candidate, _ in candidate.program.map { LiveCardItem.upcoming($0, on: candidate.channel) } }
        if !soon.isEmpty {
            shelves.append(LiveShelf(id: "soon", title: String(localized: "Starting Soon"), items: soon))
        }

        // A shelf per genre, when the lineup spans more than one, by what each
        // channel is showing now. Cards move rows at programme boundaries; a
        // local station that usually airs sports is not sports during church.
        // A genre with only a channel or two gets no row of its own.
        for (genre, members) in found.byGenre {
            let id = "genre|\(genre.rawValue)"
            shelves.append(LiveShelf(id: id, title: genre.title, items: onNow(members, section: id)))
        }

        // A shelf per source when several are combined, as the Guide's tabs (#377).
        // Sources that share a name share a row.
        let bySource = Dictionary(grouping: channels) { input.sourceNames[$0.sourceId] ?? "" }
        let titles = sourceIdFilter == nil ? bySource.keys.filter { !$0.isEmpty }.sorted() : []
        let sourceTitles = titles.count > 1 ? titles : []
        for title in sourceTitles {
            let id = "source|\(title)"
            let list = bySource[title] ?? []
            shelves.append(LiveShelf(id: id, title: title, items: onNow(list, section: id)))
        }

        // A shelf per channel group, as the Guide's tabs, except a group that
        // holds every channel. A source row wins a name it shares with a group.
        // Rows hold their whole group: Add More reads these rows, and a capped row hid channels (#654).
        let groups = Dictionary(grouping: channels) {
            $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let sourceOrder = input.sourceNames.sorted { $0.value < $1.value }.map(\.key)
        let groupTitles = LiveGroupOrder.titles(in: channels, sourceOrder: sourceOrder).filter {
            !sourceTitles.contains($0) && groups[$0]?.count != channels.count
        }
        for title in groupTitles.prefix(16) {
            let id = "group|\(title)"
            let list = groups[title] ?? []
            shelves.append(LiveShelf(id: id, title: title, items: onNow(list, section: id)))
        }

        return shelves.map {
            LiveShelf(id: $0.id, title: $0.title,
                      items: $0.items.uniquedById().markingRecordings(input.scheduledRecordings))
        }
    }
}
