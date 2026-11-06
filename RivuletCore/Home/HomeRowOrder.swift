// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  The order Home draws its rows in, set in Settings > Home > Rows. With nothing saved,
//  Home's own order. Once saved, a row with no saved place (a playlist just switched on)
//  goes last. Per Plex Home profile, as `HomeRowSettings`.
//

import Foundation

nonisolated enum HomeRowOrder {

    /// Every server's Continue Watching is one row on Home, so they share a key.
    static let continueWatchingKey = "rivulet.continueWatching"

    static func key(isContinueWatching: Bool, identifier: String?, fallback: String) -> String {
        isContinueWatching ? continueWatchingKey : (identifier ?? fallback)
    }

    private static var defaults: UserDefaults { .standard }

    static var storageKey: String { HomeSettingsScope.key("homeRowOrder") }

    static var savedKeys: [String] { defaults.stringArray(forKey: storageKey) ?? [] }

    static func arrange<T>(_ rows: [T], key: (T) -> String) -> [T] {
        arrange(rows, key: key, savedOrder: savedKeys)
    }

    /// Rows sharing a key stay together, in their default order, at that key's place.
    static func arrange<T>(_ rows: [T], key: (T) -> String, savedOrder: [String]) -> [T] {
        var defaultKeys: [String] = []
        for row in rows where !defaultKeys.contains(key(row)) { defaultKeys.append(key(row)) }
        let order = savedOrder.filter(defaultKeys.contains) + defaultKeys.filter { !savedOrder.contains($0) }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.enumerated()
            .sorted { (rank[key($0.element)] ?? .max, $0.offset) < (rank[key($1.element)] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// Swaps `key` with its neighbour in `shownKeys` (the page's list, already arranged) and saves that order.
    static func move(_ key: String, up: Bool, among shownKeys: [String]) {
        guard let i = shownKeys.firstIndex(of: key) else { return }
        save(moved(key, to: up ? i - 1 : i + 1, among: shownKeys, saved: savedKeys))
    }

    /// Moves `key` to `index` of `shownKeys` and saves the order (iOS's drag).
    static func move(_ key: String, to index: Int, among shownKeys: [String]) {
        save(moved(key, to: index, among: shownKeys, saved: savedKeys))
    }

    /// A row switched on goes last. Its saved place is dropped, and `shownKeys`
    /// (the page's rows, the new one still off) are saved.
    static func placeLast(_ key: String, among shownKeys: [String]) {
        save(placedLast(key, among: shownKeys, saved: savedKeys))
    }

    static func placedLast(_ key: String, among shownKeys: [String], saved: [String]) -> [String] {
        (shownKeys + saved.filter { !shownKeys.contains($0) }).filter { $0 != key }
    }

    /// Back to Home's own order.
    static func reset() {
        guard !savedKeys.isEmpty else { return }
        defaults.removeObject(forKey: storageKey)
        NotificationCenter.default.post(name: HomeRowSettings.changedNotification, object: nil)
    }

    private static func save(_ keys: [String]) {
        guard keys != savedKeys else { return }
        defaults.set(keys, forKey: storageKey)
        NotificationCenter.default.post(name: HomeRowSettings.changedNotification, object: nil)
    }

    /// Saved keys not shown now (a server offline) follow, so they are not lost.
    static func moved(_ key: String, up: Bool, among shownKeys: [String], saved: [String]) -> [String] {
        guard let i = shownKeys.firstIndex(of: key) else { return saved }
        return moved(key, to: up ? i - 1 : i + 1, among: shownKeys, saved: saved)
    }

    static func moved(_ key: String, to index: Int, among shownKeys: [String], saved: [String]) -> [String] {
        var keys = shownKeys
        guard let i = keys.firstIndex(of: key), keys.indices.contains(index) else { return saved }
        keys.remove(at: i)
        keys.insert(key, at: index)
        return keys + saved.filter { !shownKeys.contains($0) }
    }
}
