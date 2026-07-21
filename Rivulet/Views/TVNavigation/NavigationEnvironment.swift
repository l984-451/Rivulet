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
