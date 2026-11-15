// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// Which libraries a profile hides from the sidebar. Stored per Plex Home profile; a key is
/// `<providerID>/<library id>`.
nonisolated enum SidebarLibraryVisibility {
    private static var storeKey: String { HomeSettingsScope.key("hiddenSidebarLibraries") }

    static func stored() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storeKey) ?? [])
    }

    static func save(_ keys: Set<String>) {
        if keys.isEmpty { UserDefaults.standard.removeObject(forKey: storeKey) } else {
            UserDefaults.standard.set(keys.sorted(), forKey: storeKey)
        }
    }

    static func key(for library: MediaLibrary) -> String { key(providerID: library.providerID, libraryID: library.id) }
    static func key(providerID: String, libraryID: String) -> String { "\(providerID)/\(libraryID)" }
}

extension BrowseStore {
    /// The libraries the sidebar lists: all of them less the hidden ones.
    var sidebarLibraries: [MediaLibrary] {
        libraries.filter { !hiddenSidebarLibraries.contains(SidebarLibraryVisibility.key(for: $0)) }
    }

    /// Every library not hidden, photo libraries included.
    var shownLibraries: [MediaLibrary] {
        (libraries + photoLibraries).filter(isSidebarLibraryShown)
    }

    func isSidebarLibraryShown(_ library: MediaLibrary) -> Bool {
        !hiddenSidebarLibraries.contains(SidebarLibraryVisibility.key(for: library))
    }

    func setSidebarLibrary(_ library: MediaLibrary, shown: Bool) {
        setSidebarLibraries([library], shown: shown)
    }

    func setSidebarLibraries(_ targets: [MediaLibrary], shown: Bool) {
        var hidden = hiddenSidebarLibraries
        for library in targets {
            if shown { hidden.remove(SidebarLibraryVisibility.key(for: library)) } else {
                hidden.insert(SidebarLibraryVisibility.key(for: library))
            }
        }
        hiddenSidebarLibraries = hidden
        SidebarLibraryVisibility.save(hidden)
    }
}
