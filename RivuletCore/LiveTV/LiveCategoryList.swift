// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveCategoryList.swift
//  Rivulet
//
//  The List layout's categories: Recently Watched, Favorites, the viewer's own
//  lists and All Channels first, then the pinned groups, then each source's
//  groups in the source's own order (#568). With two or more sources in view,
//  each gets a section of its own, headed by its name, with its own All
//  Channels. Data only; each app draws it its own way.
//

import Foundation

/// One row of the category column.
struct LiveCategory: Identifiable, Hashable {
    enum Kind: Hashable {
        case recent
        case favorites
        /// Every channel in view, or one source's when `sourceId` is set.
        case all
        /// A source's name over its own categories. Not a category itself.
        case sourceHeader
        /// A channel group, by its trimmed title.
        case group(String)
        /// One of the viewer's own lists, by its id (`LiveChannelList`).
        case list(String)
        /// What's On's For You: what is on now that is like what the viewer watches.
        case forYou
        /// What's On's genre row: channels airing a programme of that genre now.
        case onNow(LiveGenre)
    }

    let id: String
    let kind: Kind
    /// Localized for the fixed rows; the source's own text for sources and groups.
    let title: String
    /// The section's source, nil for the rows over every source in view.
    let sourceId: String?
    let channelCount: Int
    /// A group's key for pinning (`LiveCategoryList.pinKey`), on the group and on its pinned copy.
    var pinKey: String? = nil

    /// The copy of a pinned group near the top, rather than the group in its section.
    var isPinnedCopy: Bool { id.hasPrefix("pin|") }
}

/// Which guide a category opens: the source it is limited to and the tab.
struct LiveGuideTarget: Hashable {
    enum Tab: Hashable {
        case all
        case favorites
        /// A tab by its title: a channel group, or a source's name in a combined guide.
        case group(String)
        /// One of the viewer's own lists, by its id.
        case list(String)
    }

    let sourceId: String?
    let tab: Tab
}

/// What a channel airs now and next, from its guide.
struct LiveNowNext: Equatable {
    let current: UnifiedProgram?
    let next: UnifiedProgram?

    /// How far through `current` the clock is, 0...1.
    func progress(at now: Date) -> Double? {
        guard let current else { return nil }
        let length = current.endTime.timeIntervalSince(current.startTime)
        guard length > 0 else { return nil }
        return min(max(now.timeIntervalSince(current.startTime) / length, 0), 1)
    }

    /// The guide's programmes for a channel, sorted by start. Placeholder
    /// blocks ("No guide data available.") say nothing, so they count as none.
    static func of(_ programs: [UnifiedProgram]?, at now: Date) -> LiveNowNext {
        let programs = programs ?? []
        let isReal = { (program: UnifiedProgram) in !program.id.contains(":placeholder:") }
        return LiveNowNext(current: programs.first { $0.startTime <= now && $0.endTime > now && isReal($0) },
                           next: programs.first { $0.startTime > now && isReal($0) })
    }
}

/// The category column and the channels behind each row. Built once per
/// change of channels, favorites, recents or sources, then read per row.
struct LiveCategoryList {
    /// The store state the list is built from.
    struct Input {
        /// The merged lineup, in the store's order (by number, then name).
        var channels: [UnifiedChannel]
        /// Every source, in the store's order: id and display name.
        var sources: [(id: String, name: String)] = []
        var favoriteIds: [String] = []
        var unfavoritedIds: Set<String> = []
        /// Newest first.
        var recentChannelIds: [String] = []
        /// One source's sidebar entry; nil shows every source.
        var sourceIdFilter: String?
        /// Sources whose sections are folded to their header.
        var collapsedSourceIds: Set<String> = []
        /// The viewer's own lists, in their order.
        var lists: [LiveChannelList] = []
        /// Pinned groups (`pinKey`), in the order they were pinned.
        var pinnedKeys: [String] = []
        /// The guide, for a smart list's genre rule.
        var epg: [String: [UnifiedProgram]] = [:]
        /// The store's change counters, so smart lists are not matched again for nothing.
        var versions: LiveSmartRules.Versions?
        /// What's On's For You picks, best first (`LiveShelves`).
        var forYouIds: [String] = []
        /// What's On's genre rows: each genre airing now and its channels.
        var onNow: [(genre: LiveGenre, ids: [String])] = []
    }

    /// The column's rows in order, source headers included.
    let categories: [LiveCategory]
    let sourceIdFilter: String?
    private let lineup: [UnifiedChannel]
    /// Every row, folded ones too, in column order.
    private let allRows: [LiveCategory]
    /// Each row's channels, as positions in `lineup`.
    private let members: [String: [Int]]

    static func build(_ input: Input) -> LiveCategoryList {
        let filter = input.sourceIdFilter
        let lineup = filter.map { id in input.channels.filter { $0.sourceId == id } } ?? input.channels
        var members: [String: [Int]] = [:]
        var rows: [LiveCategory] = []
        var folded: Set<String> = []

        func add(_ kind: LiveCategory.Kind, title: String, sourceId: String?, positions: [Int],
                 id: String? = nil, pinKey: String? = nil) {
            let id = id ?? Self.id(kind, sourceId: sourceId)
            // A merged lineup can list a channel twice; one row each.
            var seen = Set<String>()
            let unique = positions.filter { seen.insert(lineup[$0].id).inserted }
            guard kind == .sourceHeader || !unique.isEmpty else { return }
            members[id] = unique
            rows.append(LiveCategory(id: id, kind: kind, title: title, sourceId: sourceId,
                                     channelCount: unique.count, pinKey: pinKey))
        }

        var position: [String: Int] = [:]
        for (index, channel) in lineup.enumerated() where position[channel.id] == nil {
            position[channel.id] = index
        }
        add(.recent, title: String(localized: "Recently Watched"), sourceId: nil,
            positions: input.recentChannelIds.compactMap { position[$0] })
        add(.forYou, title: String(localized: "For You"), sourceId: nil,
            positions: input.forYouIds.compactMap { position[$0] })
        let favorites = LiveTVDataStore.favorites(in: lineup, order: input.favoriteIds,
                                                  unfavorited: input.unfavoritedIds)
        add(.favorites, title: String(localized: "Favorites"), sourceId: nil,
            positions: favorites.compactMap { position[$0.id] })
        // The viewer's own lists, each in the order its channels were added.
        for list in input.lists {
            let positions = list.rules.map { $0.indices(in: lineup, epg: input.epg, versions: input.versions) }
                ?? list.channelIds.compactMap { position[$0] }
            add(.list(list.id), title: list.name, sourceId: nil, positions: positions)
        }
        add(.all, title: String(localized: "All Channels"), sourceId: nil, positions: Array(lineup.indices))
        // As What's On: a row per genre airing now, before the provider's own categories.
        for row in input.onNow {
            add(.onNow(row.genre), title: row.genre.title, sourceId: nil, positions: row.ids.compactMap { position[$0] })
        }

        // Sections when two or more sources are in view, as the guide's source
        // tabs; with one, its groups follow All Channels directly.
        var bySource: [String: [Int]] = [:]
        for (index, channel) in lineup.enumerated() { bySource[channel.sourceId, default: []].append(index) }
        let known = input.sources.map(\.id)
        let present = known.filter { bySource[$0] != nil }
            + bySource.keys.filter { !known.contains($0) }.sorted()
        let names = Dictionary(input.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let sectioned = filter == nil && present.count > 1

        // Pinned groups, above the sections. A pin names one source's group,
        // so a group two sources share is pinned for one of them only.
        var byKey: [String: (title: String, sourceId: String, positions: [Int])] = [:]
        for (index, channel) in lineup.enumerated() {
            guard let title = LiveGroupOrder.trimmed(channel.groupTitle) else { continue }
            byKey[Self.pinKey(sourceId: channel.sourceId, title: title),
                  default: (title, channel.sourceId, [])].positions.append(index)
        }
        for key in input.pinnedKeys {
            guard let group = byKey[key] else { continue }
            add(.group(group.title), title: group.title, sourceId: sectioned ? group.sourceId : nil,
                positions: group.positions, id: "pin|\(key)", pinKey: key)
        }

        func addGroups(of positions: [Int], sourceId: String?) {
            var byGroup: [String: [Int]] = [:]
            for index in positions {
                guard let title = LiveGroupOrder.trimmed(lineup[index].groupTitle) else { continue }
                byGroup[title, default: []].append(index)
            }
            for title in LiveGroupOrder.titles(in: positions.map { lineup[$0] }) {
                let groupPositions = byGroup[title] ?? []
                let key = groupPositions.first.map { Self.pinKey(sourceId: lineup[$0].sourceId, title: title) }
                add(.group(title), title: title, sourceId: sourceId, positions: groupPositions, pinKey: key)
            }
        }

        if sectioned {
            for sourceId in present {
                let positions = bySource[sourceId] ?? []
                add(.sourceHeader, title: names[sourceId] ?? "", sourceId: sourceId, positions: positions)
                let before = rows.count
                add(.all, title: String(localized: "All Channels"), sourceId: sourceId, positions: positions)
                addGroups(of: positions, sourceId: sourceId)
                // Folded: the rows leave the column but keep their channels, so
                // a selected row that folds away keeps its list.
                if input.collapsedSourceIds.contains(sourceId) { folded.formUnion(rows[before...].map(\.id)) }
            }
        } else {
            addGroups(of: Array(lineup.indices), sourceId: nil)
        }

        // Groups read without the list's tags where that leaves them apart.
        let groupNames = LiveGroupDisplay.names(rows.compactMap { if case .group(let title) = $0.kind { title } else { nil } })
        rows = rows.map { row in
            guard case .group(let title) = row.kind, let name = groupNames[title], name != row.title else { return row }
            return LiveCategory(id: row.id, kind: row.kind, title: name, sourceId: row.sourceId,
                                channelCount: row.channelCount, pinKey: row.pinKey)
        }
        return LiveCategoryList(categories: rows.filter { !folded.contains($0.id) }, sourceIdFilter: filter,
                                lineup: lineup, allRows: rows, members: members)
    }

    static func id(_ kind: LiveCategory.Kind, sourceId: String?) -> String {
        let source = sourceId ?? ""
        switch kind {
        case .recent: return "recent"
        case .forYou: return "foryou"
        case .onNow(let genre): return "onnow|\(genre.rawValue)"
        case .favorites: return "favorites"
        case .all: return "all|\(source)"
        case .sourceHeader: return "source|\(source)"
        case .group(let title): return "group|\(source)|\(title)"
        case .list(let listId): return "list|\(listId)"
        }
    }

    /// A group's key for pinning: its source and title, the same in every view.
    static func pinKey(sourceId: String, title: String) -> String {
        "\(sourceId)|\(title)"
    }

    // MARK: - Reading

    /// The row's channels, in the guide's order for that tab: favorites as
    /// arranged, recents newest first, everything else as the lineup.
    func channels(in categoryId: String) -> [UnifiedChannel] {
        (members[categoryId] ?? []).map { lineup[$0] }
    }

    /// Any row, folded ones too.
    func category(_ id: String) -> LiveCategory? {
        allRows.first { $0.id == id }
    }

    /// The guide a row opens, with the same channels where the guide has such
    /// a tab. Recently Watched has none, so it opens on All Channels.
    func guideTarget(for categoryId: String) -> LiveGuideTarget? {
        guard let row = category(categoryId) else { return nil }
        let source = row.sourceId ?? sourceIdFilter
        switch row.kind {
        case .recent, .forYou, .onNow: return LiveGuideTarget(sourceId: sourceIdFilter, tab: .all)
        case .favorites: return LiveGuideTarget(sourceId: sourceIdFilter, tab: .favorites)
        case .all: return LiveGuideTarget(sourceId: source, tab: .all)
        case .group(let title): return LiveGuideTarget(sourceId: source, tab: .group(title))
        case .list(let listId): return LiveGuideTarget(sourceId: sourceIdFilter, tab: .list(listId))
        case .sourceHeader: return nil
        }
    }

    /// The row for the guide's tab on the way back, so a tab changed in the
    /// guide becomes the list's selection. nil when the list has no such row.
    func categoryId(for target: LiveGuideTarget) -> String? {
        // The rows over every source carry no source id.
        let source = target.sourceId == sourceIdFilter ? nil : target.sourceId
        let match: LiveCategory?
        switch target.tab {
        case .favorites:
            match = category(Self.id(.favorites, sourceId: nil))
        case .list(let listId):
            match = category(Self.id(.list(listId), sourceId: nil))
        case .all:
            match = category(Self.id(.all, sourceId: source))
        case .group(let title):
            if let source {
                match = category(Self.id(.group(title), sourceId: source))
            } else if let header = allRows.first(where: { $0.kind == .sourceHeader && $0.title == title }) {
                // A source's own tab in the combined guide.
                match = category(Self.id(.all, sourceId: header.sourceId))
            } else {
                // A group the combined guide merges: the first source that has
                // it, in its section rather than its pinned copy.
                match = allRows.first { $0.kind == .group(title) && !$0.isPinnedCopy }
            }
        }
        return match?.id
    }

    /// The row to come back on from a guide opened from `openerId`. The guide
    /// still on that row's tab, on a channel the row holds, comes back to the
    /// row itself: Recently Watched and a pinned copy share their tab with
    /// another row, which would otherwise take the selection.
    func categoryId(backFrom target: LiveGuideTarget, openedFrom openerId: String?, channelId: String?) -> String? {
        if let openerId, guideTarget(for: openerId) == target,
           channelId.map({ id in (members[openerId] ?? []).contains { lineup[$0].id == id } }) ?? true {
            return openerId
        }
        return categoryId(for: target)
    }
}

extension LiveTVDataStore {
    /// The List layout's categories for a source (nil: every source).
    func liveCategoryList(sourceIdFilter: String?, collapsedSourceIds: Set<String> = []) -> LiveCategoryList {
        // For You and the genre rows are picked as What's On picks them, so both layouts agree.
        let found = liveDiscovery(sourceIdFilter: sourceIdFilter)
        let forYou = found.forYou.map(\.id)
        let onNow = found.byGenre.map { (genre: $0.genre, ids: $0.channels.map(\.id)) }
        return LiveCategoryList.build(LiveCategoryList.Input(
            channels: channels,
            sources: sources.map { (id: $0.id, name: $0.displayName) },
            favoriteIds: favoriteIds, unfavoritedIds: unfavoritedIds,
            recentChannelIds: recentChannelIds,
            sourceIdFilter: sourceIdFilter, collapsedSourceIds: collapsedSourceIds,
            lists: LiveChannelListStore.shared.lists,
            pinnedKeys: LiveChannelListStore.shared.pinnedCategoryKeys,
            epg: epg, versions: lineupVersions, forYouIds: forYou, onNow: onNow))
    }
}
