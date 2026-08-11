// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsUIKitBridge.swift
//  Rivulet
//
//  Thin SwiftUI seam hosting the all-UIKit Settings surface
//  (`SettingsContainerViewController`). The only SwiftUI here is the
//  unavoidable host (like the Home/Library bridges) plus `.onExitCommand`,
//  which is the proven way to catch the Menu button in the `.sidebarAdaptable`
//  shell (the old SwiftUI Settings used it too). Menu pops the container's
//  page stack — and only when in a sub-page, so Menu at the root still exits
//  to the system. Left is handled inside the container (focus guide).
//

import SwiftUI
import UIKit
import Combine

@MainActor
final class SettingsContainerCoordinator: ObservableObject {
    /// Drives the conditional `.onExitCommand` (consume Menu only in sub-pages)
    /// and the shell's `isSettingsSubPage`.
    @Published var isSubPage = false
    weak var containerVC: SettingsContainerViewController?

    func requestPop() { containerVC?.pop() }
}

struct SettingsUIKitBridge: UIViewControllerRepresentable {
    let coordinator: SettingsContainerCoordinator
    var onSubPageChange: (Bool) -> Void

    func makeUIViewController(context: Context) -> SettingsContainerViewController {
        let vc = SettingsContainerViewController()
        wire(vc)
        return vc
    }

    func updateUIViewController(_ uiViewController: SettingsContainerViewController, context: Context) {
        wire(uiViewController)
    }

    private func wire(_ vc: SettingsContainerViewController) {
        coordinator.containerVC = vc
        let onSub = onSubPageChange
        let coord = coordinator
        vc.onDepthChange = { isSub in
            coord.isSubPage = isSub
            onSub(isSub)
        }
    }
}

/// SwiftUI wrapper for the UIKit Settings surface. Owns the Menu handler and
/// plumbs `nestedNavState.isSettingsSubPage` (the way `UIKitHomeContainer`
/// plumbs `isNested`).
struct UIKitSettingsContainer: View {
    @Environment(\.nestedNavigationState) private var nestedNavState
    @StateObject private var coordinator = SettingsContainerCoordinator()

    var body: some View {
        SettingsUIKitBridge(coordinator: coordinator, onSubPageChange: { isSub in
            nestedNavState.isSettingsSubPage = isSub
        })
        .ignoresSafeArea()
        // Conditional: consume Menu (→ pop) only in a sub-page; at the root
        // Menu is NOT consumed so it bubbles to the system, like Home.
        .onExitCommand(perform: coordinator.isSubPage ? { coordinator.requestPop() } : nil)
        .onDisappear { nestedNavState.isSettingsSubPage = false }
    }
}
