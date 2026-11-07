// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// A page pushed on the detail column. Features push these through `\.macOpen` and never name
/// each other's views; `MacRootView` maps each case to its view once.
enum MacRoute: Hashable {
    case detail(MediaItem)
    /// A See All grid for one row.
    case hub(MediaHub)
    case playlist(MediaPlaylist)
    case library(MediaLibrary)
    /// A cast or crew member; `providerID` is the server whose artwork URL the portrait is.
    case person(MediaPerson, providerID: String)
}

/// A row of the window's sidebar. Selecting one swaps the detail column's stack.
enum MacSidebarItem: Hashable {
    case home
    case search
    case liveTV
    case favorites
    case library(MediaLibrary)
    case playlists(providerID: String)
}

extension MacSidebarItem {
    /// The row as a string, for window restoration.
    var storageKey: String {
        switch self {
        case .home: "home"
        case .search: "search"
        case .liveTV: "live-tv"
        case .favorites: "favorites"
        case .library(let library): "library:\(library.providerID)|\(library.id)"
        case .playlists(let providerID): "playlists:\(providerID)"
        }
    }

    /// The row a stored key names, or nil while the libraries it points at have not loaded.
    static func restore(_ key: String, libraries: [MediaLibrary]) -> MacSidebarItem? {
        switch key {
        case "home": return .home
        case "search": return .search
        case "live-tv": return .liveTV
        case "favorites": return .favorites
        default:
            if key.hasPrefix("playlists:") { return .playlists(providerID: String(key.dropFirst("playlists:".count))) }
            return libraries.first { "library:\($0.providerID)|\($0.id)" == key }.map(MacSidebarItem.library)
        }
    }
}

extension EnvironmentValues {
    /// Pushes a page on the current detail stack.
    @Entry var macOpen: (MacRoute) -> Void = { _ in }
    /// Selects a sidebar row, e.g. Search from a menu command.
    @Entry var macSelect: (MacSidebarItem) -> Void = { _ in }
    /// Presents the account sheet.
    @Entry var macOpenAccount: () -> Void = {}
}

/// The selection the Go menu commands drive, published by the window.
struct MacSelectionKey: FocusedValueKey {
    typealias Value = Binding<MacSidebarItem?>
}

extension FocusedValues {
    var macSelection: Binding<MacSidebarItem?>? {
        get { self[MacSelectionKey.self] }
        set { self[MacSelectionKey.self] = newValue }
    }
}

/// Back and forward through the pages pushed on the current row, published by the window for the Go menu.
struct MacHistory {
    var back: (() -> Void)?
    var forward: (() -> Void)?
}

/// The visible page's reload; the Go menu's Cmd-R runs it, else refreshes the store.
struct MacPageRefreshKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var macPageRefresh: (() -> Void)? {
        get { self[MacPageRefreshKey.self] }
        set { self[MacPageRefreshKey.self] = newValue }
    }
}

/// Window actions the app menu drives: Account and Switch Profile.
struct MacAccountMenuActions {
    var openAccount: () -> Void
    var switchProfile: (() -> Void)?
}

struct MacAccountMenuKey: FocusedValueKey {
    typealias Value = MacAccountMenuActions
}

extension FocusedValues {
    var macAccountMenu: MacAccountMenuActions? {
        get { self[MacAccountMenuKey.self] }
        set { self[MacAccountMenuKey.self] = newValue }
    }
}

struct MacHistoryKey: FocusedValueKey {
    typealias Value = MacHistory
}

extension FocusedValues {
    var macHistory: MacHistory? {
        get { self[MacHistoryKey.self] }
        set { self[MacHistoryKey.self] = newValue }
    }
}

/// UserDefaults keys the Mac shell reads. A settings page flips them.
enum MacSettingsKeys {
    static let showPlaylists = "macShowPlaylists"
    /// Shared with tvOS and iOS (iCloud synced).
    static let showFavorites = "showFavoritesTab"
}
