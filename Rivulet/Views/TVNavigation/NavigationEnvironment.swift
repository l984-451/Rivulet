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
    case library(key: String)
    case liveTV(sourceId: String?)
    case settings
}

// MARK: - Nested Navigation State

/// Observable object to track nested navigation state across views.
/// `isNested` is set true while a child view has pushed a detail view;
/// the sidebar reads it to hide the tab bar and block tab switches.
///
/// `isSettingsSubPage` is a parallel signal specific to Settings sub-pages.
/// It cannot share `isNested` because Settings sub-page navigation is
/// intra-tab view swapping (not a real view push), and coupling it to
/// `isNested` caused a hide/show race with the sidebar when returning to
/// the root page. A dedicated flag lets us hide the tab bar and block tab
/// switches while in a Settings sub-page without that race.
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

    /// Posted by a content page the moment it goes from having nothing
    /// focusable (a loading or splash state) to showing its collection view.
    ///
    /// The focus engine has no notion of "this surface just became focusable":
    /// it re-resolves on a press, a presentation, or an explicit request, and a
    /// page that finishes loading is none of those. So a page that mounts empty
    /// and fills in later strands focus wherever it was parked, and every arrow
    /// press is dead until the user leaves the tab. `RootShellViewController`
    /// listens and re-drives focus into the content.
    static let contentBecameFocusable = Notification.Name("contentBecameFocusable")
}

