// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  Which Home rows this device hides, and which collections it pins. The row set
//  comes from the server (`PlexDataStore.projectHomeItems`); hiding can only remove
//  rows. Rows are keyed by `hubIdentifier`, which carries the section id, so a key
//  for a row no longer offered just stops matching.
//

import Foundation

enum HomeRowSettings {

    /// Posted after any change. `PlexDataStore` re-projects on it so Home
    /// repaints without waiting for the next poll.
    static let changedNotification = Notification.Name("homeRowVisibilityChanged")

    private static let hiddenBaseKey = "hiddenHomeRowIdentifiers"

    private static var defaults: UserDefaults { .standard }

    /// Per Plex Home profile, keyed off `selectedPlexUserId`: identifiers carry the
    /// section id, not the account, so one global list would cross profiles.
    private static var hiddenKey: String {
        guard let userId = defaults.object(forKey: "selectedPlexUserId") as? Int else {
            return hiddenBaseKey
        }
        return "\(hiddenBaseKey)_user_\(userId)"
    }

    /// Identifiers the user has hidden. Empty by default: a fresh install shows
    /// exactly what Plex says, and nothing here diverges until asked.
    static var hiddenIdentifiers: Set<String> {
        Set(defaults.stringArray(forKey: hiddenKey) ?? [])
    }

    static func isHidden(_ hubIdentifier: String?) -> Bool {
        guard let hubIdentifier, !hubIdentifier.isEmpty else { return false }
        return hiddenIdentifiers.contains(hubIdentifier)
    }

    static func setHidden(_ hidden: Bool, for hubIdentifier: String) {
        guard !hubIdentifier.isEmpty else { return }
        var ids = hiddenIdentifiers
        if hidden { ids.insert(hubIdentifier) } else { ids.remove(hubIdentifier) }
        write(ids)
    }

    /// Un-hide everything. The "Show All" bulk action.
    static func showAll() {
        write([])
    }

    private static func write(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: hiddenKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

/// Collections pinned to Home from a library's tile menu: the one way to add a row, and only
/// inside a library Plex already puts on Home. Scoped by library uuid, because
/// `selectedServer` is nil after a warm launch. Stored as JSON per Plex Home profile.
enum HomeCollectionPins {

    /// `nonisolated` because the target defaults to MainActor, and the pin
    /// loader's `TaskGroup` children and `PlexDataStore.pinRowDecision` read
    /// these keys off the main actor. Same as `HomeItemID` and `CachedHomeHub`.
    nonisolated struct Pin: Codable, Hashable, Sendable {
        let ratingKey: String
        let libraryUUID: String
        /// Plex's title at pin time, refreshed by `updateTitles` on a rename.
        var title: String

        var id: String { "\(libraryUUID)/\(ratingKey)" }
        /// Never matches `PlexDataStore.isContinueWatchingFamily`, so the row
        /// renders as a plain poster shelf.
        var rowIdentifier: String { "rivulet.pin.collection.\(ratingKey)" }
        /// Members in the collection's own order, smart collections included.
        /// `/library/metadata/{rk}/children` returns none for a smart one.
        var childrenKey: String { "/library/collections/\(ratingKey)/children" }
    }

    /// Where a pin draws: a row in its library's Home block, or a row on the
    /// library page itself, after the Collections row. Two lists stored apart,
    /// so one collection can be pinned to either or both. Every function below
    /// defaults to Home.
    nonisolated enum Destination: Sendable { case home, library }

    /// Posted after any change to either list. `PlexDataStore` re-projects,
    /// fetches and re-projects on it; a library page refetches its pins.
    static let changedNotification = Notification.Name("homeCollectionPinsChanged")

    private static var defaults: UserDefaults { .standard }

    /// Per profile, for the same reason as `HomeRowSettings.hiddenKey`. Internal
    /// so the pin loader can compare it before and after its fetch.
    static var storageKey: String { storageKey(for: .home) }

    private static func storageKey(for destination: Destination) -> String {
        let baseKey = destination == .home ? "homeCollectionPins" : "libraryCollectionPins"
        guard let userId = defaults.object(forKey: "selectedPlexUserId") as? Int else {
            return baseKey
        }
        return "\(baseKey)_user_\(userId)"
    }

    /// Every Home pin for the current profile, in the order they were pinned.
    static var pins: [Pin] { pins(in: .home) }

    static func pins(in destination: Destination) -> [Pin] {
        guard let data = defaults.data(forKey: storageKey(for: destination)) else { return [] }
        return (try? JSONDecoder().decode([Pin].self, from: data)) ?? []
    }

    static func isPinned(ratingKey: String, libraryUUID: String, in destination: Destination = .home) -> Bool {
        pins(in: destination).contains { $0.ratingKey == ratingKey && $0.libraryUUID == libraryUUID }
    }

    static func pin(_ pin: Pin, in destination: Destination = .home) {
        guard !isPinned(ratingKey: pin.ratingKey, libraryUUID: pin.libraryUUID, in: destination) else { return }
        write(pins(in: destination) + [pin], to: destination)
    }

    /// No-op, and no notification, when the pin is already gone.
    static func unpin(ratingKey: String, libraryUUID: String, in destination: Destination = .home) {
        let current = pins(in: destination)
        let kept = current.filter { !($0.ratingKey == ratingKey && $0.libraryUUID == libraryUUID) }
        guard kept.count != current.count else { return }
        write(kept, to: destination)
    }

    /// Swaps a pin one slot up or down, Settings' hold-Select reorder. Home
    /// draws each library's pins in this order. No-op at either end.
    // ponytail: swaps across libraries too, which leaves Home unchanged; group the Settings list by library if that confuses anyone.
    static func move(_ pin: Pin, up: Bool, in destination: Destination = .home) {
        var current = pins(in: destination)
        guard let i = current.firstIndex(where: { $0.id == pin.id }) else { return }
        let j = up ? i - 1 : i + 1
        guard current.indices.contains(j) else { return }
        current.swapAt(i, j)
        write(current, to: destination)
    }

    /// Adopts Plex's current title for any pin in `libraryUUID`, in either
    /// list, whose collection was renamed. Writes and posts nothing when no
    /// title differs, so the library page can call it on every refresh.
    static func updateTitles(from collections: [PlexMetadata], libraryUUID: String) {
        for destination in [Destination.home, .library] {
            updateTitles(from: collections, libraryUUID: libraryUUID, in: destination)
        }
    }

    private static func updateTitles(from collections: [PlexMetadata], libraryUUID: String,
                                     in destination: Destination) {
        let current = pins(in: destination)
        let updated = current.map { pin -> Pin in
            guard pin.libraryUUID == libraryUUID,
                  let title = collections.first(where: { $0.ratingKey == pin.ratingKey })?.title,
                  !title.isEmpty else { return pin }
            var renamed = pin
            renamed.title = title
            return renamed
        }
        guard updated != current else { return }
        write(updated, to: destination)
    }

    private static func write(_ pins: [Pin], to destination: Destination) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        defaults.set(data, forKey: storageKey(for: destination))
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
