// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelLists.swift
//  Rivulet
//
//  The viewer's own channel lists and pinned categories, kept on this device.
//  A list holds channel ids in the order they were added; a pin names a
//  source's channel group (`LiveCategoryList.pinKey`). Both show at the top
//  of the List layout and as tabs in the guide.
//

import Foundation
import Combine

/// A list of channels the viewer put together.
struct LiveChannelList: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var channelIds: [String]
    /// A smart list's rules: it holds the channels they match, and `channelIds` stays empty.
    var rules: LiveSmartRules?

    var isSmart: Bool { rules != nil }

    /// The list's channels in `lineup`: a smart list's matches in lineup order, else its own in its order.
    func channels(in lineup: [UnifiedChannel], epg: [String: [UnifiedProgram]] = [:],
                  versions: LiveSmartRules.Versions? = nil) -> [UnifiedChannel] {
        if let rules { return rules.channels(in: lineup, epg: epg, versions: versions) }
        let byId = Dictionary(lineup.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return channelIds.compactMap { byId[$0] }
    }

    /// The list's tab in the guide, whose tabs go by title: its name, or "Name (List)"
    /// when a channel group, a source or Favorites already has that name.
    func tabTitle(taken: Set<String>) -> String {
        taken.contains(name) ? String(localized: "\(name) (List)") : name
    }
}

@MainActor
final class LiveChannelListStore: ObservableObject {
    static let shared = LiveChannelListStore()

    @Published private(set) var lists: [LiveChannelList] = []
    /// Pinned groups, in the order they were pinned.
    @Published private(set) var pinnedCategoryKeys: [String] = []

    private let defaults: UserDefaults
    static let listsKey = "liveTVChannelLists"
    static let pinsKey = "liveTVPinnedCategories"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    /// Rereads both from the device's store, as iCloud sync does after changing them.
    func reload() {
        let saved = defaults.data(forKey: Self.listsKey)
            .flatMap { try? JSONDecoder().decode([LiveChannelList].self, from: $0) } ?? []
        if saved != lists { lists = saved }
        let pins = defaults.stringArray(forKey: Self.pinsKey) ?? []
        if pins != pinnedCategoryKeys { pinnedCategoryKeys = pins }
    }

    // MARK: - Lists

    /// A new list holding `channelId`. A blank name makes no list.
    @discardableResult
    func createList(named name: String, with channelId: String) -> LiveChannelList? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let list = LiveChannelList(id: UUID().uuidString, name: uniqueName(trimmed), channelIds: [channelId])
        lists.append(list)
        saveLists()
        return list
    }

    /// A new smart list. A blank name or no rules make none.
    @discardableResult
    func createSmartList(named name: String, rules: LiveSmartRules) -> LiveChannelList? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !rules.isEmpty else { return nil }
        let list = LiveChannelList(id: UUID().uuidString, name: uniqueName(trimmed), channelIds: [], rules: rules)
        lists.append(list)
        saveLists()
        return list
    }

    /// A smart list's new rules. A list keeps at least one.
    func setRules(_ rules: LiveSmartRules, for listId: String) {
        guard !rules.isEmpty, let index = lists.firstIndex(where: { $0.id == listId }), lists[index].isSmart else { return }
        lists[index].rules = rules
        saveLists()
    }

    func rename(_ listId: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = lists.firstIndex(where: { $0.id == listId }) else { return }
        lists[index].name = uniqueName(trimmed, excluding: listId)
        saveLists()
    }

    /// The name, or "Name 2", "Name 3"… when another list has it: a list's guide tab goes by its
    /// name, so two lists sharing one would share a tab.
    func uniqueName(_ name: String, excluding listId: String? = nil) -> String {
        let taken = Set(lists.filter { $0.id != listId }.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    func delete(_ listId: String) {
        lists.removeAll { $0.id == listId }
        saveLists()
    }

    /// Adds the channel at the end, or takes it out when it is already there.
    func toggle(_ channelId: String, in listId: String) {
        guard let index = lists.firstIndex(where: { $0.id == listId }), !lists[index].isSmart else { return }
        if let position = lists[index].channelIds.firstIndex(of: channelId) {
            lists[index].channelIds.remove(at: position)
        } else {
            lists[index].channelIds.append(channelId)
        }
        saveLists()
    }

    /// Whether a guide change can change any list's channels (a smart list with a genre rule).
    var listsReadGuide: Bool { lists.contains { $0.rules?.readsGuide == true } }

    func list(_ listId: String) -> LiveChannelList? {
        lists.first { $0.id == listId }
    }

    // MARK: - Pins

    func isPinned(_ key: String) -> Bool { pinnedCategoryKeys.contains(key) }

    func togglePin(_ key: String) {
        if let index = pinnedCategoryKeys.firstIndex(of: key) {
            pinnedCategoryKeys.remove(at: index)
        } else {
            pinnedCategoryKeys.append(key)
        }
        defaults.set(pinnedCategoryKeys, forKey: Self.pinsKey)
    }

    private func saveLists() {
        if let data = try? JSONEncoder().encode(lists) {
            defaults.set(data, forKey: Self.listsKey)
        }
    }
}
