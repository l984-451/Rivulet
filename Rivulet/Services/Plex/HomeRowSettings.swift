// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  HomeRowSettings.swift
//  Rivulet
//
//  Which Home rows this device hides.
//
//  Home's row SET comes from the Plex server (pinned libraries → hubs flagged
//  `promoted`; see `PlexDataStore.projectHomeItems`). This is the local
//  subtractive filter on top: an Apple TV in the living room is a different
//  context from a phone, and a viewer may want fewer rows here than their Plex
//  account asks for everywhere.
//
//  Subtractive ON PURPOSE. It can hide a row Plex offers; it can never invent
//  one Plex does not. That keeps a single source of truth for what a row IS and
//  what it is called, and it means a stored preference can never resurrect a
//  row for a library the user has since unshared or deleted.
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
