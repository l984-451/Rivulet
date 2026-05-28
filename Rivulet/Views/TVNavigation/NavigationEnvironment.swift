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

    /// Sent by `TVSidebarView` when the user picks a sidebar tab while the
    /// active tab has a NavigationStack push on screen. tvOS locks the
    /// visible tab content to the navigation stack while it's at depth ≥ 1,
    /// so a selection write lands in state but the displayed tab doesn't
    /// switch. Subscribers (per-tab content views) clear their detail
    /// `@State` so the push pops to root, unblocking the swap.
    let popToRootSubject = PassthroughSubject<Void, Never>()
}

/// Environment key for nested navigation state
private struct NestedNavigationStateKey: EnvironmentKey {
    @MainActor static let defaultValue: NestedNavigationState = NestedNavigationState()
}

extension EnvironmentValues {
    var nestedNavigationState: NestedNavigationState {
        get { self[NestedNavigationStateKey.self] }
        set { self[NestedNavigationStateKey.self] = newValue }
    }
}

