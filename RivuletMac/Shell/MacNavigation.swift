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

/// UserDefaults keys the Mac shell reads. A settings page flips them.
enum MacSettingsKeys {
    static let showPlaylists = "macShowPlaylists"
    /// Shared with tvOS and iOS (iCloud synced).
    static let showFavorites = "showFavoritesTab"
}
