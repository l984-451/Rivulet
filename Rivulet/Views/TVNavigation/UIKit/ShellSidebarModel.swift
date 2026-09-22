// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ShellSidebarModel.swift
//  Rivulet
//

import Foundation

/// One row of the custom shell sidebar.
struct ShellSidebarItem: Hashable {
    let tab: SidebarTab
    let title: String
    /// SF Symbol name.
    let icon: String
}

/// A group of rows. `title` renders as a small section header; nil means the
/// rows sit flush with no header (the top group, Discover-below, Settings).
struct ShellSidebarSection: Hashable {
    let title: String?
    let items: [ShellSidebarItem]
}

/// Builds the sidebar's section list from live app state. Pure, so the order
/// rules carried over from the system-sidebar shell (Discover position,
/// Live TV combined/separate and position, server-named library section,
/// Settings always last) stay unit-testable.
enum ShellSidebarModel {

    // swiftlint:disable:next function_parameter_count
    static func sections(
        libraries: [PlexLibrary],
        liveTVSources: [LiveTVDataStore.LiveTVSourceInfo],
        combineLiveTV: Bool,
        showDiscover: Bool,
        discoverAbove: Bool,
        showWatchlist: Bool,
        liveTVAbove: Bool,
        serverName: String?,
        profileName: String
    ) -> [ShellSidebarSection] {
        var sections: [ShellSidebarSection] = []

        var top: [ShellSidebarItem] = [
            ShellSidebarItem(tab: .account, title: profileName, icon: "person.crop.circle.fill"),
            ShellSidebarItem(tab: .search, title: "Search", icon: "magnifyingglass"),
            ShellSidebarItem(tab: .home, title: "Home", icon: "house.fill"),
        ]
        let discover = ShellSidebarItem(tab: .discover, title: "Discover", icon: "sparkles")
        if showDiscover && discoverAbove {
            top.append(discover)
        }
        // The watchlist is account-level, not a library, so it sits with the
        // other whole-app destinations rather than in the server section.
        if showWatchlist {
            top.append(ShellSidebarItem(tab: .watchlist, title: "Watchlist", icon: "bookmark.fill"))
        }
        sections.append(ShellSidebarSection(title: nil, items: top))

        let librarySection = ShellSidebarSection(
            title: serverName ?? "Library",
            items: libraries.map {
                ShellSidebarItem(tab: .library(key: $0.key),
                                 title: $0.title,
                                 icon: icon(forLibraryType: $0.type))
            })
        let liveTVSection = ShellSidebarSection(
            title: "Live TV",
            items: liveTVItems(sources: liveTVSources, combined: combineLiveTV))

        let middle = liveTVAbove ? [liveTVSection, librarySection]
                                 : [librarySection, liveTVSection]
        sections.append(contentsOf: middle.filter { !$0.items.isEmpty })

        if showDiscover && !discoverAbove {
            sections.append(ShellSidebarSection(title: nil, items: [discover]))
        }
        sections.append(ShellSidebarSection(
            title: nil,
            items: [ShellSidebarItem(tab: .settings, title: "Settings", icon: "gearshape.fill")]))
        return sections
    }

    static func icon(forLibraryType type: String) -> String {
        switch type {
        case "movie": return "film.fill"
        case "show": return "tv.fill"
        case "artist": return "music.note"
        case "photo": return "photo.fill"
        default: return "folder.fill"
        }
    }

    private static func liveTVItems(
        sources: [LiveTVDataStore.LiveTVSourceInfo],
        combined: Bool
    ) -> [ShellSidebarItem] {
        guard !sources.isEmpty else { return [] }
        if combined {
            return [ShellSidebarItem(tab: .liveTV(sourceId: nil),
                                     title: "Channels",
                                     icon: "play.rectangle.fill")]
        }
        return sources.map { source in
            ShellSidebarItem(tab: .liveTV(sourceId: source.id),
                             title: source.displayName.replacingOccurrences(of: " Live TV", with: ""),
                             icon: icon(forSource: source))
        }
    }

    private static func icon(forSource source: LiveTVDataStore.LiveTVSourceInfo) -> String {
        switch source.sourceType {
        case .plex: return "play.rectangle.fill"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        default: return "list.bullet.rectangle"
        }
    }
}
