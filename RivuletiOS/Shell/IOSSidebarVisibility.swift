// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI
import UIKit

/// Whether the iPad's tab sidebar is open rather than the top tab bar. SwiftUI's TabView
/// reports no such state, and the sidebar's `isHidden` posts no KVO, so this stands in front
/// of SwiftUI's own sidebar delegate to hear `sidebarVisibilityWillChange`, passing every
/// call on to it. False on iPhone, where there is no sidebar.
@MainActor
final class IOSSidebarVisibility: ObservableObject {
    @Published private(set) var isShowing = false
    private weak var sidebar: UITabBarController.Sidebar?
    /// The sidebar's delegate is weak: this holds the proxy.
    private var proxy: SidebarDelegateProxy?

    /// Finds the window's tab bar controller and follows its sidebar. False until SwiftUI has made it.
    fileprivate func attach(in window: UIWindow) -> Bool {
        guard let controller = Self.tabBarController(in: window.rootViewController) else { return false }
        let sidebar = controller.sidebar
        if sidebar === self.sidebar, let proxy, sidebar.delegate === proxy { return true }
        let proxy = SidebarDelegateProxy(forwardingTo: sidebar.delegate) { [weak self] hidden in
            self?.isShowing = !hidden
        }
        sidebar.delegate = proxy
        self.proxy = proxy
        self.sidebar = sidebar
        isShowing = !sidebar.isHidden
        return true
    }

    /// Children only: a presented sheet never holds the root TabView.
    private static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = tabBarController(in: child) { return tabs }
        }
        return nil
    }
}

/// Hears the sidebar showing or hiding and hands every delegate call, that one included, to
/// the delegate it replaced (SwiftUI's), so the TabView behaves as before.
private final class SidebarDelegateProxy: NSObject, UITabBarController.Sidebar.Delegate {
    private weak var target: (any UITabBarController.Sidebar.Delegate)?
    private let changed: @MainActor (_ hidden: Bool) -> Void

    init(forwardingTo target: (any UITabBarController.Sidebar.Delegate)?, changed: @escaping @MainActor (Bool) -> Void) {
        self.target = target
        self.changed = changed
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          sidebarVisibilityWillChange sidebar: UITabBarController.Sidebar,
                          animator: any UITabBarController.Sidebar.Animating) {
        changed(sidebar.isHidden)
        target?.tabBarController?(tabBarController, sidebarVisibilityWillChange: sidebar, animator: animator)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (target?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        target?.responds(to: selector) == true ? target : super.forwardingTarget(for: selector)
    }
}

/// An empty view behind the root TabView that hooks `IOSSidebarVisibility` up once the
/// window holds the tab bar controller.
struct IOSSidebarVisibilityProbe: UIViewRepresentable {
    let visibility: IOSSidebarVisibility

    func makeUIView(context: Context) -> ProbeView { ProbeView(visibility: visibility) }
    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        private let visibility: IOSSidebarVisibility

        init(visibility: IOSSidebarVisibility) {
            self.visibility = visibility
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // The TabView's controller can land in the window a pass after this view does.
            Task { @MainActor [weak self] in
                for _ in 0..<20 {
                    guard let self, let window = self.window else { return }
                    if self.visibility.attach(in: window) { return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
}
