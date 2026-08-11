// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLibraryVisibilityFilter.swift
//  Rivulet
//
//  Restricts a flat, cross-library `[PlexMetadata]` list to the libraries the
//  user actually wants to see.
//
//  Why this has to exist at all: Rivulet's hidden-library / shown-on-Home sets
//  are CLIENT-side UserDefaults (`LibrarySettingsManager`) and are never sent
//  to Plex. Most Home rows dodge the problem structurally — Recently Added is
//  built by iterating `librariesForHomeScreen` and pulling each library's own
//  scoped hub, so a hidden library is simply never asked. But
//  `/hubs/continueWatching` and the global `/hubs` are ACCOUNT-level endpoints:
//  they return one flat list spanning every library on the server, with no
//  per-library request scoping available. Consuming them whole is what makes a
//  hidden library's items reappear — visibly duplicated for anyone running
//  mirrored libraries (e.g. "Movies" plus a "Movies.x264" re-encode of the same
//  films, where the user hid the mirror). The only place to apply the user's
//  intent is client-side, on the returned metadata.
//
//  It has to happen while the items are still `PlexMetadata`: only Plex
//  metadata carries the section attribution (`librarySectionKey` /
//  `librarySectionID`). `MediaItem` / `MediaItemRef` are providerID + itemID
//  only, so once `PlexMediaMapper` has run the attribution is gone.
//

import Foundation

/// Section-attribution predicate shared by every consumer of an account-level
/// (cross-library) Plex hub.
nonisolated enum PlexLibraryVisibilityFilter {

    /// Normalizes a section identifier to its bare numeric form.
    ///
    /// The two sides of the comparison are not written the same way. Plex spells
    /// `librarySectionKey` as a path (`/library/sections/3`) while
    /// `PlexLibrary.key` is the bare id (`3`) — see the `replacingOccurrences`
    /// calls in `PlexDataStore.loadLibraryHubsIfNeeded`, which already defend
    /// against both spellings. Comparing the raw strings would silently never
    /// match on the path form, so both sides get normalized first.
    static func normalizedSectionID(_ raw: String) -> String {
        guard let slash = raw.lastIndex(of: "/") else { return raw }
        return String(raw[raw.index(after: slash)...])
    }

    /// Builds the comparison set from library keys.
    static func normalizedKeySet(_ libraryKeys: some Sequence<String>) -> Set<String> {
        Set(libraryKeys.map(normalizedSectionID))
    }

    /// Whether `item` belongs to one of `normalizedKeys`.
    ///
    /// Fails OPEN in two cases, both deliberate:
    ///
    /// 1. **Empty key set.** On a cold launch the library list has not loaded
    ///    yet, and `LibrarySettingsManager.isLibraryShownOnHome` itself returns
    ///    `true` for everything until `homeVisibilityConfigured` flips. Treating
    ///    "no keys" as "hide everything" would blank Continue Watching and the
    ///    hero on every launch until libraries land.
    /// 2. **Unattributed item.** Some hub payloads omit section fields entirely.
    ///    An item we cannot attribute is not evidence that it is hidden, and
    ///    dropping it would silently lose legitimate content.
    static func isVisible(_ item: PlexMetadata, in normalizedKeys: Set<String>) -> Bool {
        guard !normalizedKeys.isEmpty else { return true }
        if let sectionKey = item.librarySectionKey {
            return normalizedKeys.contains(normalizedSectionID(sectionKey))
        }
        if let sectionID = item.librarySectionID {
            return normalizedKeys.contains(String(sectionID))
        }
        return true
    }

    /// Filters a cross-library metadata list down to `libraryKeys`.
    static func filter(_ items: [PlexMetadata], toLibraryKeys libraryKeys: some Sequence<String>) -> [PlexMetadata] {
        let keys = normalizedKeySet(libraryKeys)
        guard !keys.isEmpty else { return items }
        return items.filter { isVisible($0, in: keys) }
    }
}
