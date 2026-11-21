// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  The Live TV client logic both phone and desktop apps read: layout choice,
//  record offers, and the long-press menu rules (the tvOS LiveProgramMenu rules in HIG order).
//

import Combine
import Foundation

/// Same key and values as tvOS `liveTVLayout`.
enum LiveLayout: String, CaseIterable {
    case browse = "Browse"
    case guide = "Guide"
    /// Categories, then their channels with what is on: the tvOS List layout. Same stored value.
    case list = "List"

    static let storageKey = "liveTVLayout"

    var title: String {
        switch self {
        case .browse: String(localized: "What's On")
        case .guide: String(localized: "Guide")
        case .list: String(localized: "List")
        }
    }
}

/// A programme the sheet describes. `program` is nil for a channel with no guide data.
struct LiveProgrammeSelection: Identifiable {
    let channel: UnifiedChannel
    let program: UnifiedProgram?
    var id: String { program?.id ?? channel.id }
}

extension UnifiedChannel {
    /// "7 · BBC One", or the name alone.
    var numberAndName: String {
        [channelNumber.map(String.init), name].compactMap { $0 }.joined(separator: " · ")
    }

    /// The number to show beside the name. An Xtream panel's number is its
    /// own running count across the whole lineup, which tells the viewer
    /// nothing, so it is left out; sorting and number search still use it.
    var displayNumber: ChannelNumber? { sourceType == .xtream ? nil : channelNumber }

    /// The name to show: an IPTV list's leading region or quality tag ("UK | ", "┃NL┃ ")
    /// left out, as the category already says it (`XtreamService.cleanName`). Search and
    /// sorting keep the full name.
    var displayName: String {
        switch sourceType {
        case .xtream, .genericM3U, .dispatcharr: XtreamService.cleanName(name)
        default: name
        }
    }

    /// `numberAndName` with `displayNumber` and `displayName`.
    var displayNumberAndName: String {
        [displayNumber.map(String.init), displayName].compactMap { $0 }.joined(separator: " · ")
    }
}

extension UnifiedProgram {
    var timeRange: String {
        let style = Date.FormatStyle.dateTime.hour().minute()
        return String(localized: "\(startTime.formatted(style)) to \(endTime.formatted(style))")
    }
}

// MARK: - Recording

/// Record offers and recording changes, with the tvOS copy for failures.
/// Each presenting context (tab, sheet, player) owns one.
@MainActor
final class LiveRecorder: ObservableObject {
    struct Offer: Identifiable {
        let id = UUID()
        let program: UnifiedProgram
        let channel: UnifiedChannel
        let options: [LiveTVRecordOption]
    }

    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var offer: Offer?
    @Published var failure: Failure?
    @Published private(set) var isLoadingOptions = false

    private var store: LiveTVDataStore { .shared }

    /// Loads the source's record options and asks which one.
    func offerRecording(_ program: UnifiedProgram, on channel: UnifiedChannel) {
        isLoadingOptions = true
        Task {
            defer { isLoadingOptions = false }
            do {
                let options = try await store.recordOptions(for: program, on: channel)
                if options.isEmpty {
                    failure = Failure(title: String(localized: "Can't Record"), message: String(localized: "The server offered no way to record this programme."))
                } else {
                    offer = Offer(program: program, channel: channel, options: options)
                }
            } catch {
                failure = Failure(title: String(localized: "Can't Record"), message: error.localizedDescription)
            }
        }
    }

    func record(_ option: LiveTVRecordOption, offer: Offer) {
        run { try await LiveTVDataStore.shared.record(option, program: offer.program, on: offer.channel) }
    }

    func cancel(_ recording: LiveTVScheduledRecording) {
        run { try await LiveTVDataStore.shared.cancel(recording) }
    }

    func cancelSeries(of recording: LiveTVScheduledRecording) {
        run { try await LiveTVDataStore.shared.cancelSeries(of: recording) }
    }

    func delete(_ rule: LiveTVRecordingRule, then done: @escaping () -> Void = {}) {
        run({ try await LiveTVDataStore.shared.delete(rule) }, then: done)
    }

    // MARK: Naming a list

    /// A name being asked for: a new list holding a channel, or a new name for a list.
    struct Naming: Identifiable {
        let id = UUID()
        let channelId: String?
        let listId: String?
        var title: String { listId == nil ? String(localized: "New List") : String(localized: "Rename List") }
    }

    @Published var naming: Naming?
    @Published var namingText = ""

    func askNewList(holding channel: UnifiedChannel) {
        namingText = ""
        naming = Naming(channelId: channel.id, listId: nil)
    }

    func askRename(_ list: LiveChannelList) {
        namingText = list.name
        naming = Naming(channelId: nil, listId: list.id)
    }

    /// Makes or renames the list; a blank name changes nothing. Returns the list's id.
    @discardableResult
    func commitName(lists: LiveChannelListStore = .shared) -> String? {
        defer { naming = nil }
        guard let naming else { return nil }
        if let listId = naming.listId {
            lists.rename(listId, to: namingText)
            return listId
        }
        guard let channelId = naming.channelId else { return nil }
        return lists.createList(named: namingText, with: channelId)?.id
    }

    private func run(_ change: @escaping () async throws -> Void, then done: @escaping () -> Void = {}) {
        Task {
            do {
                try await change()
                done()
            } catch {
                failure = Failure(title: String(localized: "Recording Didn't Change"), message: error.localizedDescription)
            }
        }
    }
}

/// One long-press menu entry. Built once, drawn as SwiftUI buttons or UIActions.
struct LiveMenuAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var isDestructive = false
    /// A submenu's rows; `perform` is unused when there are any.
    var children: [LiveMenuAction] = []
    var perform: () -> Void = {}
}

/// The tvOS `LiveProgramMenu` rules in HIG order: Watch, Record, Favorite.
@MainActor
enum LiveMenu {
    static func sections(
        channel: UnifiedChannel,
        program: UnifiedProgram?,
        recorder: LiveRecorder,
        watch: @escaping (UnifiedChannel) -> Void,
        details: ((LiveProgrammeSelection) -> Void)? = nil
    ) -> [[LiveMenuAction]] {
        let store = LiveTVDataStore.shared
        let airingNow = program?.isCurrentlyAiring ?? true
        var watchGroup = [LiveMenuAction(
            id: "watch",
            title: airingNow ? String(localized: "Watch") : String(localized: "Watch \(channel.name)"),
            systemImage: "play.fill"
        ) { watch(channel) }]
        if let details, program != nil {
            watchGroup.append(LiveMenuAction(id: "details", title: String(localized: "Details"), systemImage: "info.circle") {
                details(LiveProgrammeSelection(channel: channel, program: program))
            })
        }

        var recordGroup: [LiveMenuAction] = []
        if let program, program.endTime > Date(), store.canRecord(channel) {
            if let recording = store.activeRecording(for: program) {
                recordGroup.append(LiveMenuAction(
                    id: "cancel",
                    title: recording.status == .recording ? String(localized: "Stop Recording") : String(localized: "Cancel Recording"),
                    systemImage: "stop.circle",
                    isDestructive: true
                ) { recorder.cancel(recording) })
                if recording.ruleIsSeries {
                    recordGroup.append(LiveMenuAction(
                        id: "series",
                        title: String(localized: "Cancel Series"),
                        systemImage: "square.stack.3d.up.slash",
                        isDestructive: true
                    ) { recorder.cancelSeries(of: recording) })
                }
            } else {
                recordGroup.append(LiveMenuAction(id: "record", title: String(localized: "Record…"), systemImage: "record.circle") {
                    recorder.offerRecording(program, on: channel)
                })
            }
        }

        var favoriteGroup: [LiveMenuAction] = []
        let isFavorite = store.isFavorite(channel)
        favoriteGroup.append(LiveMenuAction(
            id: "favorite",
            title: isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
            systemImage: isFavorite ? "star.slash" : "star"
        ) { store.toggleFavorite(channel) })
        favoriteGroup.append(listMenu(for: channel, recorder: recorder))
        return [watchGroup, recordGroup, favoriteGroup].filter { !$0.isEmpty }
    }

    /// "Add to List": the viewer's own lists, ticked where the channel is (Select adds or takes it
    /// out), then New List…. Smart lists fill themselves and are not offered.
    static func listMenu(for channel: UnifiedChannel, recorder: LiveRecorder,
                         lists: LiveChannelListStore = .shared) -> LiveMenuAction {
        var rows = lists.lists.filter { !$0.isSmart }.map { list in
            LiveMenuAction(id: "list-\(list.id)", title: list.name,
                           systemImage: list.channelIds.contains(channel.id) ? "checkmark" : "list.bullet") {
                lists.toggle(channel.id, in: list.id)
            }
        }
        rows.append(LiveMenuAction(id: "list-new", title: String(localized: "New List…"), systemImage: "plus") {
            recorder.askNewList(holding: channel)
        })
        return LiveMenuAction(id: "lists", title: String(localized: "Add to List"), systemImage: "text.badge.plus",
                              children: rows)
    }
}
