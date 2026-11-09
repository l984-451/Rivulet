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
    /// A folder of a photo library.
    case photos(MediaLibrary, folder: MediaItemRef, title: String)
    /// One of a photo library's memories, as a flat grid.
    case photoMemory(MediaLibrary, PhotoMemory)
    /// A cast or crew member; `providerID` is the server whose artwork URL the portrait is.
    case person(MediaPerson, providerID: String)
    /// Live TV's scheduled and finished recordings.
    case liveRecordings
}

extension MacRoute {
    /// The server this page's content comes from.
    var providerID: String {
        switch self {
        case .detail(let item): item.ref.providerID
        case .hub(let hub): hub.providerID
        case .playlist(let playlist): playlist.item.ref.providerID
        case .library(let library), .photos(let library, _, _), .photoMemory(let library, _): library.providerID
        case .person(_, let providerID): providerID
        case .liveRecordings: ""
        }
    }
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
    /// The server this row lists, nil for the rows that span them.
    var providerID: String? {
        switch self {
        case .library(let library): library.providerID
        case .playlists(let providerID): providerID
        default: nil
        }
    }

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
    let canBack: Bool
    let canForward: Bool
    let box: MacShellBox
}

/// The window's menu actions, set in place each pass. Published values hold this box and flags, never
/// closures: a fresh closure per pass republishes, which re-renders the root and loops the toolbar.
final class MacShellBox {
    var back: () -> Void = {}
    var forward: () -> Void = {}
    var openAccount: () -> Void = {}
    var switchProfile: () -> Void = {}
}

/// The visible page's reload; the Go menu's Cmd-R runs it, else refreshes the store.
/// The published value is one box per page, so a page pass does not republish and loop the window's toolbar.
final class MacPageRefreshBox { var action: () -> Void = {} }

struct MacPageRefresh {
    let box: MacPageRefreshBox
    func callAsFunction() { box.action() }
}

struct MacPageRefreshKey: FocusedValueKey {
    typealias Value = MacPageRefresh
}

extension FocusedValues {
    var macPageRefresh: MacPageRefresh? {
        get { self[MacPageRefreshKey.self] }
        set { self[MacPageRefreshKey.self] = newValue }
    }
}

private struct MacPageRefreshModifier: ViewModifier {
    let action: () -> Void
    @State private var box = MacPageRefreshBox()

    func body(content: Content) -> some View {
        box.action = action
        return content.focusedSceneValue(\.macPageRefresh, MacPageRefresh(box: box))
    }
}

extension View {
    /// Registers this page's reload for the toolbar button and Cmd-R.
    func macPageRefresh(_ action: @escaping () -> Void) -> some View {
        modifier(MacPageRefreshModifier(action: action))
    }
}

/// Window actions the app menu drives: Account and Switch Profile.
struct MacAccountMenuActions {
    let canSwitchProfile: Bool
    let box: MacShellBox
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

extension BrowseStore {
    /// The sidebar's libraries, photo libraries included.
    var sidebarAllLibraries: [MediaLibrary] {
        sidebarLibraries + photoLibraries.filter(isSidebarLibraryShown)
    }
}
