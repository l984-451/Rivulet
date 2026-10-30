// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  NavigationEnvironment.swift
//  Rivulet
//
//  Environment keys and state objects for tvOS navigation
//

import SwiftUI
import Combine

// MARK: - Sidebar Tab

/// Tab selection type for the system TabView sidebar
enum SidebarTab: Hashable {
    case account
    case search
    case home
    case discover
    case watchlist
    case library(key: String)
    /// A library on a non-Plex server. Ids, not the library value, so a
    /// renamed library keeps its tab (and its cached page) across reloads.
    case providerLibrary(providerID: String, libraryID: String)
    /// One server's video playlists, by provider id.
    case playlists(providerID: String)
    case requests(providerID: String)
    case liveTV(sourceId: String?)
    case settings
}

// MARK: - Nested Navigation State

/// Nested navigation state: while either flag is set the sidebar hides its pill
/// and blocks tab switches. Settings sub-pages get their own flag because
/// sharing `isNested` raced the sidebar on the way back to the root page.
@MainActor
class NestedNavigationState: ObservableObject {
    @Published var isNested: Bool = false
    @Published var isSettingsSubPage: Bool = false
}

/// Environment key for nested navigation state
private struct NestedNavigationStateKey: EnvironmentKey {
    static let defaultValue: NestedNavigationState = NestedNavigationState()
}

extension EnvironmentValues {
    var nestedNavigationState: NestedNavigationState {
        get { self[NestedNavigationStateKey.self] }
        set { self[NestedNavigationStateKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted by `PlexHomeViewController` when focus crosses its top-row
    /// boundary. Object is a `Bool`: true while focus sits below the top row
    /// (the sidebar pill should hide for full-bleed browsing, matching the
    /// TV app), false once focus returns to the top row or leaves the page.
    /// Change-only: posted when the value flips, not on every focus move.
    static let contentFocusBelowTopChanged = Notification.Name("contentFocusBelowTopChanged")

    /// Posted by a content page when it goes from nothing focusable (loading)
    /// to its collection view. The focus engine does not re-resolve on its own
    /// when a page finishes loading, so `RootShellViewController` re-drives it.
    static let contentBecameFocusable = Notification.Name("contentBecameFocusable")

    /// Posted by a tab's content controller (object: itself) after it swapped the
    /// page it shows. The shell drives focus into it as on a tab switch.
    static let tabContentReplaced = Notification.Name("tabContentReplaced")
}
