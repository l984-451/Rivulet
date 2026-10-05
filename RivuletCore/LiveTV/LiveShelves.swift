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
struct LiveShelf: Identifiable {
    let id: String
    let title: String
    let items: [LiveCardItem]
}

/// One card's content.
struct LiveCardItem: Hashable, Identifiable {
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

    static func channel(_ channel: UnifiedChannel, program: UnifiedProgram?, section: String) -> LiveCardItem {
        LiveCardItem(id: "\(section)|\(channel.id)", kind: .channel, channel: channel,
                     program: program, recording: nil)
    }

    /// An upcoming card's start: the time alone today, with the weekday after.
    static func startLabel(_ program: UnifiedProgram, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = program.eventStart
        return calendar.isDate(start, inSameDayAs: now)
            ? start.formatted(.dateTime.hour().minute())
            : start.formatted(.dateTime.weekday().hour().minute())
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
    func markingRecordings(_ recordings: [LiveTVScheduledRecording]) -> [LiveCardItem] {
        map { item in
            guard item.kind != .recording, let program = item.program else { return item }
            var marked = item
            marked.setToRecord = LiveTVDataStore.activeRecording(for: program, in: recordings) != nil
            return marked
        }
    }

    /// First of each id. A diffable snapshot traps on a repeated identifier,
    /// and a merged lineup can list a channel twice.
    func uniquedById() -> [LiveCardItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension LiveTVDataStore {
    /// The What's On rows for a source (nil: every source). Rows may be empty.
    func whatsOnShelves(sourceIdFilter: String?, now: Date = Date()) -> [LiveShelf] {
        LiveShelves.build(LiveShelves.Input(
            channels: channels, epg: epg, recentChannelIds: recentChannelIds, favoriteIds: favoriteIds,
            viewings: viewings, suggestionsEnabled: suggestionsEnabled,
            scheduledRecordings: scheduledRecordings), sourceIdFilter: sourceIdFilter, now: now)
    }
}

enum LiveShelves {
    /// The store state the rows are built from.
    struct Input {
        var channels: [UnifiedChannel]
        var epg: [String: [UnifiedProgram]]
        var recentChannelIds: [String] = []
        var favoriteIds: [String] = []
        var viewings: [LiveViewing] = []
        var suggestionsEnabled = true
        var scheduledRecordings: [LiveTVScheduledRecording] = []
    }

    static func build(_ input: Input, sourceIdFilter: String?, now: Date) -> [LiveShelf] {
        let epg = input.epg
        func current(_ channel: UnifiedChannel) -> UnifiedProgram? {
            epg[channel.id]?.first { $0.startTime <= now && $0.endTime > now }
        }
        func next(_ channel: UnifiedChannel) -> UnifiedProgram? {
            epg[channel.id]?.first { $0.startTime > now }
        }

        let all = sourceIdFilter.map { id in input.channels.filter { $0.sourceId == id } } ?? input.channels
        // An empty event slot has nothing to show; Favorites and Recently
        // Watched still list it, since the viewer chose it.
        let channels = all.filter { current($0)?.isEmptySlot != true }
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
        // Channels showing something now, not holding a slot for a later game.
        let airing = channels.filter { current($0)?.isPregameBlock != true }

        // Channels played lately, newest first, to go straight back to one.
        let recent = input.recentChannelIds.compactMap { channelsById[$0] }
        if !recent.isEmpty {
            shelves.append(LiveShelf(id: "recent", title: "Recently Watched", items: onNow(recent, section: "recent")))
        }

        // Like what this viewer watches at this hour, from what is on now.
        // Recently Watched already covers going back, so its channels are left out.
        if input.suggestionsEnabled {
            let recentIds = Set(input.recentChannelIds)
            let candidates = airing.filter { !recentIds.contains($0.id) }.map { channel in
                let program = current(channel)
                return (channel: channel, program: program,
                        genre: LiveGenre.of(channel, airing: program, guide: epg[channel.id] ?? []))
            }
            let picks = LiveSuggestions.rank(candidates, history: input.viewings, now: now).prefix(20)
            if picks.count >= 3 {
                shelves.append(LiveShelf(id: "foryou", title: "For You", items: onNow(Array(picks), section: "foryou")))
            }
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
            shelves.append(LiveShelf(id: "recordings", title: "Recordings", items: recordings))
        }

        let favourites = LiveTVDataStore.favorites(in: all, order: input.favoriteIds)
        if !favourites.isEmpty {
            shelves.append(LiveShelf(id: "favorites", title: "Favorites", items: onNow(favourites, section: "favorites")))
        }

        if !airing.isEmpty {
            shelves.append(LiveShelf(id: "now", title: "On Now", items: onNow(Array(airing.prefix(150)), section: "now")))
        }

        // The next programme on each channel that starts within the next
        // ninety minutes: what this viewer watches when each one starts
        // first, then soonest first.
        let horizon = now.addingTimeInterval(90 * 60)
        let upcoming = channels.compactMap { channel -> LiveSuggestions.Candidate? in
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
            shelves.append(LiveShelf(id: "soon", title: "Starting Soon", items: soon))
        }

        // A shelf per genre, when the lineup spans more than one, by what each
        // channel is showing now. Cards move rows at programme boundaries; a
        // local station that usually airs sports is not sports during church.
        // A genre with only a channel or two gets no row of its own.
        let byGenre = Dictionary(grouping: airing) { channel in
            LiveGenre.of(channel, airing: current(channel), guide: epg[channel.id] ?? [])
        }
        let genres = LiveGenre.allCases.filter { (byGenre[$0] ?? []).count >= 3 }
        if genres.count > 1 {
            for genre in genres {
                let id = "genre|\(genre.rawValue)"
                let list = Array((byGenre[genre] ?? []).prefix(60))
                shelves.append(LiveShelf(id: id, title: genre.rawValue, items: onNow(list, section: id)))
            }
        }

        // A shelf per channel group, when the source groups at all.
        let groups = Dictionary(grouping: channels) {
            $0.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let groupTitles = groups.keys.filter { !$0.isEmpty }.sorted()
        if groupTitles.count > 1 {
            for title in groupTitles.prefix(16) {
                let id = "group|\(title)"
                let list = Array((groups[title] ?? []).prefix(60))
                shelves.append(LiveShelf(id: id, title: title, items: onNow(list, section: id)))
            }
        }

        return shelves.map {
            LiveShelf(id: $0.id, title: $0.title,
                      items: $0.items.uniquedById().markingRecordings(input.scheduledRecordings))
        }
    }
}
