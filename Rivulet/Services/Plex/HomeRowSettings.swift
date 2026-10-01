// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  HomeRowSettings.swift
//  Rivulet
//
//  Which Home rows this device hides, and which collections it pins.
//
//  Home's row SET comes from the Plex server (pinned libraries → hubs flagged
//  `promoted`; see `PlexDataStore.projectHomeItems`). This is the local
//  subtractive filter on top: an Apple TV in the living room is a different
//  context from a phone, and a viewer may want fewer rows here than their Plex
//  account asks for everywhere.
//
//  The hide list is subtractive ON PURPOSE. It can hide a row Plex offers; it
//  can never invent one Plex does not. That keeps a single source of truth for
//  what a row IS and what it is called, and it means a stored preference can
//  never resurrect a row for a library the user has since unshared or deleted.
//
//  Local pins (`HomeCollectionPins`, below) are the one user-created exception:
//  a collection pinned from a library's tile menu adds a row inside that
//  library's Home block. A pin never adds a library, and a pin whose library is
//  gone, unshared or on another server never matches, so the no-resurrection
//  property still holds.
//
//  Rows are keyed by Plex's `hubIdentifier` (`movie.recentlyadded.1`,
//  `tv.recentlyadded.2`, `continueWatching`), which is stable across refreshes
//  and carries the library's section id, so two libraries' Recently Added rows
//  are distinct keys. A key for a row that stops being offered simply never
//  matches again; it is inert rather than wrong, so there is nothing to prune.
//

import Foundation

enum HomeRowSettings {

    /// Posted after any change. `PlexDataStore` re-projects on it so Home
    /// repaints without waiting for the next poll.
    static let changedNotification = Notification.Name("homeRowVisibilityChanged")

    private static let hiddenBaseKey = "hiddenHomeRowIdentifiers"

    private static var defaults: UserDefaults { .standard }

    /// Namespaced PER PLEX HOME PROFILE, the same way `LibrarySettingsManager`
    /// namespaces its own keys.
    ///
    /// Load-bearing on a shared server. Home rows are derived from the signed-in
    /// account's pinned libraries, so two profiles on one Apple TV see different
    /// rows; a single global key would let one profile's hidden rows suppress
    /// another's, and the identifiers collide because they carry the section id
    /// rather than the account. Mirrors the key
    /// `PlexUserProfileManager` writes (`selectedPlexUserId`).
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
        defaults.set(Array(ids), forKey: hiddenKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

/// Collections the user pinned to Home from a library's tile menu. The one
/// user-created exception to the subtractive rule above (see the file header).
///
/// Scoped by library uuid rather than server. `PlexAuthManager.selectedServer`,
/// and with it the machine id, is nil after a warm launch that restores only
/// URL and token, while `PlexLibrary.uuid` is always present. Matching on it
/// keeps pins to the current server and leaves a pin for a deleted or unshared
/// library inert.
///
/// Stored as a JSON array per Plex Home profile, keyed like
/// `HomeRowSettings.hiddenKey`. `PlexDataStore` fetches each pin's first page
/// (`loadPinnedCollections`) and draws it after its library's own rows
/// (`projectHomeItems`).
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

    /// Posted after any change. `PlexDataStore` re-projects, fetches and
    /// re-projects on it.
    static let changedNotification = Notification.Name("homeCollectionPinsChanged")

    private static let baseKey = "homeCollectionPins"

    private static var defaults: UserDefaults { .standard }

    /// Per profile, for the same reason as `HomeRowSettings.hiddenKey`. Internal
    /// so the pin loader can compare it before and after its fetch.
    static var storageKey: String {
        guard let userId = defaults.object(forKey: "selectedPlexUserId") as? Int else {
            return baseKey
        }
        return "\(baseKey)_user_\(userId)"
    }

    /// Every pin for the current profile, in the order they were pinned.
    static var pins: [Pin] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Pin].self, from: data)) ?? []
    }

    static func isPinned(ratingKey: String, libraryUUID: String) -> Bool {
        pins.contains { $0.ratingKey == ratingKey && $0.libraryUUID == libraryUUID }
    }

    static func pin(_ pin: Pin) {
        guard !isPinned(ratingKey: pin.ratingKey, libraryUUID: pin.libraryUUID) else { return }
        write(pins + [pin])
    }

    /// No-op, and no notification, when the pin is already gone.
    static func unpin(ratingKey: String, libraryUUID: String) {
        let current = pins
        let kept = current.filter { !($0.ratingKey == ratingKey && $0.libraryUUID == libraryUUID) }
        guard kept.count != current.count else { return }
        write(kept)
    }

    /// Adopts Plex's current title for any pin in `libraryUUID` whose
    /// collection was renamed. Writes and posts nothing when no title differs,
    /// so the library page can call it on every refresh.
    static func updateTitles(from collections: [PlexMetadata], libraryUUID: String) {
        let current = pins
        let updated = current.map { pin -> Pin in
            guard pin.libraryUUID == libraryUUID,
                  let title = collections.first(where: { $0.ratingKey == pin.ratingKey })?.title,
                  !title.isEmpty else { return pin }
            var renamed = pin
            renamed.title = title
            return renamed
        }
        guard updated != current else { return }
        write(updated)
    }

    private static func write(_ pins: [Pin]) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        defaults.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
