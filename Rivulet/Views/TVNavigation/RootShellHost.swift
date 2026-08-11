// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RootShellHost.swift
//  Rivulet
//
//  SwiftUI seam for the UIKit navigation shell. TVSidebarView mounts this in
//  place of the old TabView(.sidebarAdaptable); tab content is still built by
//  TVSidebarView, which decides per tab whether the content is a plain UIKit
//  view controller or needs hosting (see `contentViewController(for:)`).
//

import SwiftUI
import UIKit

/// Hosting controller for one tab's content. The subclass exists so the
/// UIKit shell can re-point roots without naming SwiftUI types.
final class RootShellHostingController: UIHostingController<AnyView> {
    func adoptRoot(from other: UIViewController) {
        guard let other = other as? RootShellHostingController else { return }
        rootView = other.rootView
    }
}

struct RootShellHost: UIViewControllerRepresentable {
    @Binding var selection: SidebarTab
    var interactionBlocked: Bool
    var pillSuppressed: Bool
    var sections: [ShellSidebarSection]
    let content: (SidebarTab) -> UIViewController

    func makeUIViewController(context: Context) -> RootShellViewController {
        let shell = RootShellViewController()
        shell.makeContent = content
        shell.onTabChange = { tab in
            // Async: the shell reports intent mid-focus-update; writing the
            // binding synchronously would mutate state during a view update.
            DispatchQueue.main.async { selection = tab }
        }
        shell.updateSections(sections)
        shell.applySelection(selection)
        return shell
    }

    func updateUIViewController(_ shell: RootShellViewController, context: Context) {
        shell.makeContent = content
        // Only hosted tabs are rebuilt here; `refreshContentRoots` checks the
        // cached controller's type BEFORE calling this, so a directly-mounted
        // UIKit surface is never reconstructed just to be thrown away.
        shell.refreshContentRoots(content)
        shell.interactionBlocked = interactionBlocked
        shell.pillSuppressed = pillSuppressed
        shell.updateSections(sections)
        shell.applySelection(selection)
    }
}
