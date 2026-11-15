// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  Which Home rows this profile hides. The row set comes from the servers; hiding can only
//  remove rows. Rows are keyed by `hubIdentifier`, which carries the section id, so a key
//  for a row no longer offered just stops matching. Both apps read and write it.
//

import Foundation

/// Home settings are stored once per Plex Home profile (`<key>_user_<id>`), as
/// `SyncCatalog.profileFamilies` lists them.
nonisolated enum HomeSettingsScope {
    static func key(_ base: String) -> String {
        guard let userId = UserDefaults.standard.object(forKey: PlexProfileSession.savedUserIDKey) as? Int else {
            return base
        }
        return "\(base)_user_\(userId)"
    }
}

nonisolated enum HomeRowSettings {

    /// Posted after any change to the hidden rows or the row order.
    static let changedNotification = Notification.Name("homeRowVisibilityChanged")

    /// Identifiers carry the section id, not the account, so one global list would cross profiles.
    private static var hiddenKey: String { HomeSettingsScope.key("hiddenHomeRowIdentifiers") }

    private static var defaults: UserDefaults { .standard }

    /// Empty by default: a fresh install shows exactly what the servers say.
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

    /// Un-hide everything. Part of Home Rows' Reset.
    static func showAll() {
        write([])
    }

    private static func write(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: hiddenKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// The identifiers of the Continue Watching rows, which Home merges into one: the
    /// selected Plex server's own, and each other server's.
    static func continueWatchingIdentifiers(hasSelectedPlex: Bool, otherProviderIDs: [String]) -> [String] {
        (hasSelectedPlex ? ["continueWatching"] : []) + otherProviderIDs.map { "\($0)|continueWatching" }
    }

    /// A shelf's identifier on iOS, where the selected server's row ids carry its
    /// provider prefix; on tvOS they carry none, and the other servers' match.
    static func identifier(ofShelf id: String, selectedProviderID: String?) -> String {
        guard let selectedProviderID, id.hasPrefix("\(selectedProviderID)|") else { return id }
        return String(id.dropFirst(selectedProviderID.count + 1))
    }
}
