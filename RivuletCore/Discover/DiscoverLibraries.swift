// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation
import Synchronization

/// Libraries a profile leaves out of Discover (Use in Discover), such as one of placeholder videos: a copy
/// there isn't yours to Discover, and For You doesn't read its watch history. Stored per Plex Home profile
/// as `SidebarLibraryVisibility`'s keys, except that the selected Plex server is named by its machine id
/// (`key(providerID:libraryID:selectedPlex:)`). Empty by default: every library is used.
nonisolated enum DiscoverLibraries {
    /// Posted after `setUsed`, and on tvOS when iCloud changes the list.
    static let changedNotification = Notification.Name("discoverLibrariesChanged")
    static let storeBase = "discoverExcludedLibraries"
    private static var storeKey: String { HomeSettingsScope.key(storeBase) }

    /// How the selected Plex server is named. The registry names it by a hash of its URL whenever the app
    /// starts from a restored sign-in, so its provider id changes with the URL (a connection upgrade, the LAN
    /// fallback) and differs between devices. The stored keys use its machine id instead, as downloads do
    /// (`DownloadIdentity`), and a key reads the same on every device and every launch.
    nonisolated struct SelectedPlex: Sendable, Equatable {
        /// The registry's ids for the selected server this sign-in (`MediaItemRef.selectedPlexIDs`).
        var providerIDs: Set<String>
        /// Its machine id (`PlexAuthManager.selectedServerMachineID`).
        var machineID: String?

        /// A server switched away from this session stays in `selectedPlexIDs` and comes back as an extra
        /// server under its own id, so the extras are left out: their libraries keep their own keys.
        /// With no machine id known yet (an install that never saved one) the registry's id stands.
        @MainActor static var current: SelectedPlex {
            SelectedPlex(providerIDs: MediaItemRef.selectedPlexIDs.withLock { $0 }
                            .subtracting(MediaItemRef.extraPlexIDs.withLock { $0 }),
                         machineID: PlexAuthManager.shared.selectedServerMachineID)
        }

        /// `providerID` as the stored keys name it: the selected Plex server by its machine id, any other
        /// server (an extra Plex server's id already is its machine id) as it is.
        func storedID(_ providerID: String) -> String {
            guard providerIDs.contains(providerID), let machineID, !machineID.isEmpty else { return providerID }
            return DownloadIdentity.plexProviderID(machineID: machineID)
        }
    }

    /// The key a library is stored under.
    static func key(providerID: String, libraryID: String, selectedPlex: SelectedPlex) -> String {
        SidebarLibraryVisibility.key(providerID: selectedPlex.storedID(providerID), libraryID: libraryID)
    }

    static func key(for library: MediaLibrary, selectedPlex: SelectedPlex) -> String {
        key(providerID: library.providerID, libraryID: library.id, selectedPlex: selectedPlex)
    }

    static func excluded() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storeKey) ?? [])
    }

    /// `key` is `key(providerID:libraryID:selectedPlex:)`.
    static func setUsed(_ used: Bool, key: String) {
        var keys = excluded()
        if used { keys.remove(key) } else { keys.insert(key) }
        if keys.isEmpty { UserDefaults.standard.removeObject(forKey: storeKey) } else {
            UserDefaults.standard.set(keys.sorted(), forKey: storeKey)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// `libraries` less the excluded ones.
    static func used(_ libraries: [MediaLibrary], excluded: Set<String>, selectedPlex: SelectedPlex) -> [MediaLibrary] {
        libraries.filter { !excluded.contains(key(for: $0, selectedPlex: selectedPlex)) }
    }

    /// Whether a server's copy counts in Discover. An item that names no library does.
    static func counts(_ item: MediaItem, excluded: Set<String>, selectedPlex: SelectedPlex) -> Bool {
        guard let libraryID = item.libraryID else { return true }
        return !excluded.contains(key(providerID: item.ref.providerID, libraryID: libraryID, selectedPlex: selectedPlex))
    }

    /// One server's excluded library ids (tvOS's Discover reads the selected Plex server's sections).
    static func libraryIDs(_ excluded: Set<String>, providerID: String, selectedPlex: SelectedPlex) -> Set<String> {
        let prefix = key(providerID: providerID, libraryID: "", selectedPlex: selectedPlex)
        return Set(excluded.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }
}

extension BrowseStore {
    /// What Use in Discover lists: the shown movie and TV libraries, the ones Discover can match.
    var discoverableLibraries: [MediaLibrary] {
        sidebarLibraries.filter { $0.kind == .movies || $0.kind == .shows }.sidebarOrder(servers: providerOrder)
    }

    /// The shown libraries less those left out of Discover: what For You reads.
    var librariesUsedInDiscover: [MediaLibrary] {
        DiscoverLibraries.used(sidebarLibraries, excluded: discoverExcludedLibraries, selectedPlex: .current)
    }

    func usesInDiscover(_ library: MediaLibrary) -> Bool {
        !discoverExcludedLibraries.contains(DiscoverLibraries.key(for: library, selectedPlex: .current))
    }

    func setUsesInDiscover(_ library: MediaLibrary, _ used: Bool) {
        DiscoverLibraries.setUsed(used, key: DiscoverLibraries.key(for: library, selectedPlex: .current))
        discoverExcludedLibraries = DiscoverLibraries.excluded()
    }

    /// False for a copy in a library hidden from the sidebar or left out of Discover.
    func countsInDiscover(_ item: MediaItem) -> Bool {
        isShownOnHome(item)
            && DiscoverLibraries.counts(item, excluded: discoverExcludedLibraries, selectedPlex: .current)
    }
}
