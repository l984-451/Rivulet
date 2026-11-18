// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  The libraries Home's hero leaves out (Settings > Home > Hero), per Plex Home profile. A library
//  of placeholders (a trailer standing in for a title not owned) can keep its Home row while its
//  titles stay out of the hero. Stored as exclusions, so a library added later is included.
//  Hero Reset leaves this alone: it resets what the hero shows, not which libraries are placeholders.
//

import Foundation

nonisolated enum HeroLibraries {

    /// Posted after any change. Not `HeroSources.changedNotification`: that one refetches the
    /// favorites and playlists, and leaving a library out changes no fetched list.
    static let changedNotification = Notification.Name("heroLibrariesChanged")

    private static var key: String { HomeSettingsScope.key("heroExcludedLibraries") }

    /// `SidebarLibraryVisibility` keys, "<providerID>/<libraryID>".
    static var excluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isIncluded(providerID: String, libraryID: String) -> Bool {
        !excluded.contains(SidebarLibraryVisibility.key(providerID: providerID, libraryID: libraryID))
    }

    static func isIncluded(_ library: MediaLibrary) -> Bool {
        isIncluded(providerID: library.providerID, libraryID: library.id)
    }

    static func set(providerID: String, libraryID: String, included: Bool) {
        var current = excluded
        let libraryKey = SidebarLibraryVisibility.key(providerID: providerID, libraryID: libraryID)
        if included { current.remove(libraryKey) } else { current.insert(libraryKey) }
        if current.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(current.sorted(), forKey: key)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func set(_ library: MediaLibrary, included: Bool) {
        set(providerID: library.providerID, libraryID: library.id, included: included)
    }

    /// The hero's test for a title, reading the setting once: false for a title from a left-out
    /// library, true for one that names no library (Jellyfin and Emby's Continue Watching and
    /// playlist entries).
    static var allows: (MediaItem) -> Bool {
        let excluded = excluded
        return { item in
            guard !excluded.isEmpty, let libraryID = item.libraryID else { return true }
            return !excluded.contains(SidebarLibraryVisibility.key(providerID: item.ref.providerID, libraryID: libraryID))
        }
    }

    /// `allows` for the selected Plex server's metadata, which names its section rather than a library id.
    static func allows(plexProviderID providerID: String?) -> (PlexMetadata) -> Bool {
        let excluded = excluded
        return { item in
            guard !excluded.isEmpty, let providerID,
                  let section = item.librarySectionKey.map(PlexLibraryVisibilityFilter.normalizedSectionID)
                    ?? item.librarySectionID.map(String.init) else { return true }
            return !excluded.contains(SidebarLibraryVisibility.key(providerID: providerID, libraryID: section))
        }
    }
}
