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
    /// The profile row's picture; the symbol stays where there is none.
    var avatarURL: URL?
    /// The profile row only: Select opens the profile switcher.
    var canSwitchProfile = false
    /// The row's server, named once servers' rows are mixed and no section
    /// header can name it; "Live TV" on a split Live TV source's row.
    var badge: String?
    /// The row's `SidebarArrangement` key; nil for the fixed rows.
    var arrangeKey: String?
}

/// A server whose sidebar gets a Playlists row.
struct PlaylistServer: Hashable {
    let providerID: String
    let name: String
    /// `LibrarySettingsManager.serverID(ofKey:)` of this server's libraries: "" for the selected Plex server.
    let serverID: String

    /// The servers among `providerIDs`, the selected Plex server first.
    @MainActor static func current(_ providerIDs: Set<String>) -> [PlaylistServer] {
        let plexID = MediaProviderRegistry.shared.plexProvider?.id
        var servers: [PlaylistServer] = []
        if let plexID, providerIDs.contains(plexID),
           LibrarySettingsManager.shared.areServerLibrariesVisible(plexID) {
            servers.append(PlaylistServer(providerID: plexID,
                                          name: PlexAuthManager.shared.savedServerName ?? "Library", serverID: ""))
        }
        for source in ServerDataStore.shared.sources
        where source.providerID != plexID && providerIDs.contains(source.providerID)
            && !servers.contains(where: { $0.providerID == source.providerID })
            && LibrarySettingsManager.shared.areServerLibrariesVisible(source.providerID) {
            servers.append(PlaylistServer(providerID: source.providerID, name: source.name, serverID: source.providerID))
        }
        return servers
    }
}

/// One library in the sidebar, any server's, in the user's order.
struct SidebarLibrary: Hashable {
    /// `LibrarySettingsManager`'s key, which names the server.
    let key: String
    let serverName: String
    let item: ShellSidebarItem

    init(plex library: PlexLibrary, serverName: String) {
        key = library.key
        self.serverName = serverName
        item = ShellSidebarItem(tab: .library(key: library.key), title: library.title,
                                icon: ShellSidebarModel.icon(forLibraryType: library.type))
    }

    init(_ library: MediaLibrary, serverName: String) {
        key = library.settingsKey
        self.serverName = serverName
        item = ShellSidebarItem(tab: .providerLibrary(providerID: library.providerID, libraryID: library.id),
                                title: library.title, icon: ShellSidebarModel.icon(forLibraryKind: library.kind))
    }
    /// Every server's visible libraries (or all of them) in the user's order across servers.
    @MainActor static func current(includeHidden: Bool = false) -> [SidebarLibrary] {
        let plexName = PlexAuthManager.shared.savedServerName ?? "Library"
        let store = ServerDataStore.shared
        let names = Dictionary(store.sources.map { ($0.providerID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let plex = includeHidden
            ? LibrarySettingsManager.shared.sortLibraries(PlexDataStore.shared.libraries.filter(\.hasBrowseSurface))
            : PlexDataStore.shared.visibleSidebarLibraries
        let others = includeHidden ? store.libraries : store.visibleLibraries
        let all = plex.map { SidebarLibrary(plex: $0, serverName: plexName) }
            + others.map { SidebarLibrary($0, serverName: names[$0.providerID] ?? "") }
        return LibrarySettingsManager.shared.arrange(all, key: \.key)
    }
}

/// A group of rows. `title` renders as a small section header; nil means the
/// rows sit flush with no header (the top group, Discover-below, Settings).
struct ShellSidebarSection: Hashable {
    let title: String?
    let items: [ShellSidebarItem]
}

/// Builds the sidebar's section list from live app state. Pure, so the order
/// rules (the profile, Search and Home on top, the arrangeable rows in the
/// user's order, Settings always last) stay unit-testable.
enum ShellSidebarModel {

    /// The order for a profile with none stored: today's default layout.
    static let defaultOrder = SidebarArrangement.seed(libraryOrder: [], discoverAbove: true, liveTVAbove: false)

    // swiftlint:disable:next function_parameter_count
    static func sections(
        libraries: [SidebarLibrary],
        liveTVSources: [LiveTVDataStore.LiveTVSourceInfo],
        combineLiveTV: Bool,
        showDiscover: Bool,
        showWatchlist: Bool,
        order: [String] = defaultOrder,
        hiddenKeys: Set<String> = [],
        profileName: String,
        profileAvatar: URL? = nil,
        canSwitchProfile: Bool = false,
        hasMediaServer: Bool = true,
        playlistServers: [PlaylistServer] = [],
        requestsServer: PlaylistServer? = nil
    ) -> [ShellSidebarSection] {
        var sections: [ShellSidebarSection] = []

        // The profile is a header in a section of its own, above the tabs.
        sections.append(ShellSidebarSection(title: nil, items: [
            ShellSidebarItem(tab: .account, title: firstName(of: profileName),
                             icon: "person.crop.circle.fill", avatarURL: profileAvatar,
                             canSwitchProfile: canSwitchProfile),
        ]))

        // Search, Discover and the watchlist need a media server. Without one,
        // Home is only the welcome screen, kept while there is no Live TV instead.
        var top: [ShellSidebarItem] = []
        if hasMediaServer {
            top.append(ShellSidebarItem(tab: .search, title: "Search", icon: "magnifyingglass"))
        }
        if !opensToLiveTV(hasMediaServer: hasMediaServer, liveTVSources: liveTVSources) {
            top.append(ShellSidebarItem(tab: .home, title: "Home", icon: "house.fill"))
        }

        let rows = arrangeableRows(libraries: libraries, liveTVSources: liveTVSources, combineLiveTV: combineLiveTV,
                                   showDiscover: showDiscover && hasMediaServer,
                                   showWatchlist: showWatchlist && hasMediaServer,
                                   hiddenKeys: hiddenKeys, playlistServers: playlistServers)
        let labelsServers = Set(libraries.map { LibrarySettingsManager.serverID(ofKey: $0.key) }).count > 1
        let libraryKeys = Set(libraries.map(\.key))
        let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let (arranged, grouped) = SidebarArrangement.sections(
            SidebarArrangement.arrange(rows.map(\.key), order: order))
        var middle = arranged
        // Discover and the watchlist leading the list join Search and Home, as before.
        if let first = middle.first, first.server == nil {
            let lead = first.keys.prefix { $0 == SidebarArrangement.discover || $0 == SidebarArrangement.watchlist }
            top += lead.compactMap { key in
                byKey[key].map { row in var item = row.item; item.arrangeKey = key; return item }
            }
            middle[0] = SidebarArrangement.Section(server: nil, keys: Array(first.keys.dropFirst(lead.count)))
        }
        if !top.isEmpty {
            sections.append(ShellSidebarSection(title: nil, items: top))
        }
        for section in middle where !section.keys.isEmpty {
            let items = section.keys.compactMap { key -> ShellSidebarItem? in
                guard let row = byKey[key] else { return nil }
                var item = row.item
                item.arrangeKey = key
                // Mixed servers: no header can name the server, so the row does.
                if !grouped, labelsServers || !libraryKeys.contains(key),
                   let server = row.serverName { item.badge = server }
                return item
            }
            let namesServer = labelsServers || !section.keys.contains(where: libraryKeys.contains)
            let title = !namesServer || section.server == nil ? nil : section.keys.first.flatMap { byKey[$0]?.serverName }
            sections.append(ShellSidebarSection(title: title, items: items))
        }
        if let requestsServer {
            var item = ShellSidebarItem(tab: .requests(providerID: requestsServer.providerID),
                                        title: "Requests", icon: "tray.full.fill")
            item.badge = requestsServer.name
            sections.append(ShellSidebarSection(title: nil, items: [item]))
        }
        sections.append(ShellSidebarSection(
            title: nil,
            items: [ShellSidebarItem(tab: .settings, title: "Settings", icon: "gearshape.fill")]))
        return sections
    }

    /// One arrangeable row: its key in the stored order, and its server's name
    /// (libraries and Playlists rows).
    struct Row: Hashable {
        let key: String
        let item: ShellSidebarItem
        let serverName: String?
    }

    /// Every arrangeable row shown, before ordering: Discover, the watchlist, the
    /// libraries in order, each server's Playlists row, and Live TV. Settings >
    /// Sidebar passes everything, hidden rows included.
    static func arrangeableRows(
        libraries: [SidebarLibrary],
        liveTVSources: [LiveTVDataStore.LiveTVSourceInfo],
        combineLiveTV: Bool,
        showDiscover: Bool,
        showWatchlist: Bool,
        hiddenKeys: Set<String> = [],
        playlistServers: [PlaylistServer] = []
    ) -> [Row] {
        var rows: [Row] = []
        if showDiscover {
            rows.append(Row(key: SidebarArrangement.discover,
                            item: ShellSidebarItem(tab: .discover, title: "Discover", icon: "sparkles"), serverName: nil))
        }
        // The watchlist is account-level, not a library: no server.
        if showWatchlist {
            rows.append(Row(key: SidebarArrangement.watchlist,
                            item: ShellSidebarItem(tab: .watchlist, title: "Watchlist", icon: "bookmark.fill"), serverName: nil))
        }
        rows += libraries.map { Row(key: $0.key, item: $0.item, serverName: $0.serverName) }
        for server in playlistServers {
            let key = SidebarArrangement.playlists(server: server.serverID)
            guard !hiddenKeys.contains(key), !hiddenKeys.contains(SidebarArrangement.allPlaylistsHidden) else { continue }
            rows.append(Row(key: key, item: playlistsItem(server), serverName: server.name))
        }
        if !liveTVSources.isEmpty, combineLiveTV {
            rows.append(Row(key: SidebarArrangement.liveTV,
                            item: ShellSidebarItem(tab: .liveTV(sourceId: nil), title: "Live TV", icon: "play.rectangle.fill"),
                            serverName: nil))
        } else if !combineLiveTV {
            // Split sources: the source names the row, the badge says it is Live TV.
            rows += liveTVSources.map { source in
                Row(key: SidebarArrangement.liveTV(source: source.id),
                    item: ShellSidebarItem(tab: .liveTV(sourceId: source.id),
                                           title: source.displayName.replacingOccurrences(of: " Live TV", with: ""),
                                           icon: icon(forSource: source), badge: "Live TV"),
                    serverName: nil)
            }
        }
        return rows
    }

    private static func playlistsItem(_ server: PlaylistServer) -> ShellSidebarItem {
        ShellSidebarItem(tab: .playlists(providerID: server.providerID), title: "Playlists",
                         icon: "list.bullet.rectangle")
    }

    /// Live TV with no media server: the app opens on Live TV and Home is hidden.
    static func opensToLiveTV(hasMediaServer: Bool, liveTVSources: [LiveTVDataStore.LiveTVSourceInfo]) -> Bool {
        !hasMediaServer && !liveTVSources.isEmpty
    }

    /// A held or long Up stops at Home and at Search: leaving either upward takes
    /// a fresh press or swipe, so the rarely used profile row is never overshot into.
    static func stopsUpwardRun(from: SidebarTab?, to: SidebarTab?, headingUp: Bool,
                               gestureAlreadyMoved: Bool) -> Bool {
        headingUp && gestureAlreadyMoved && from != to && (from == .home || from == .search)
    }

    /// The first word of a display name; a one-word name or handle is whole.
    static func firstName(of displayName: String) -> String {
        displayName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? displayName
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

    static func icon(forLibraryKind kind: MediaLibrary.LibraryKind) -> String {
        switch kind {
        case .movies: return "film.fill"
        case .shows: return "tv.fill"
        case .music: return "music.note"
        case .photos: return "photo.fill"
        case .mixed, .liveTV: return "folder.fill"
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
