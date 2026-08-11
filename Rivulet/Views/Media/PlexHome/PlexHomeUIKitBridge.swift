// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexHomeUIKitBridge.swift
//  Rivulet
//
//  SwiftUI bridge to host `PlexHomeViewController` (UIKit/TVUIKit home).
//  Forwards music selections back to a SwiftUI binding so the surrounding
//  NavigationStack pushes the music routers. All other navigation is
//  handled inside the UIKit controller itself.
//

import SwiftUI
import UIKit

struct PlexHomeUIKitBridge: UIViewControllerRepresentable {
    /// Surface to render: .home (default) or .library(key:title:). Fixed for
    /// the lifetime of the hosted controller — library call sites must `.id`
    /// the container by library key so a key change rebuilds the VC.
    var mode: HomeMode = .home
    @Binding var selectedMusicItem: PlexMetadata?

    final class Coordinator {
        var selectedMusicItem: Binding<PlexMetadata?>
        init(selectedMusicItem: Binding<PlexMetadata?>) {
            self.selectedMusicItem = selectedMusicItem
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedMusicItem: $selectedMusicItem)
    }

    /// The single shared HOME controller. SwiftUI identity churn during
    /// launch (state flips re-evaluating the tab tree) was discarding the
    /// representable and calling make again ~1s in — TWO full home VCs each
    /// fetching, observing, and applying 5s snapshots through the whole
    /// launch window. The home is a singleton surface for the app's
    /// lifetime, so the bridge hands every make the SAME instance (UIKit
    /// reparents the view to the newest host automatically). Library mode is
    /// NOT cached: each library gets a fresh controller via .id(key).
    @MainActor private static var sharedHomeVC: PlexHomeViewController?

    func makeUIViewController(context: Context) -> PlexHomeViewController {
        if case .library = mode { StartupTimer.mark("bridge.makeUIViewController (library)") }
        else { StartupTimer.mark("bridge.makeUIViewController (home)") }

        let vc: PlexHomeViewController
        if case .home = mode {
            if let shared = Self.sharedHomeVC {
                StartupTimer.mark("bridge reusing shared home VC")
                vc = shared
            } else {
                vc = PlexHomeViewController(mode: mode)
                Self.sharedHomeVC = vc
            }
        } else {
            vc = PlexHomeViewController(mode: mode)
        }

        vc.onSelectMusic = { meta in
            context.coordinator.selectedMusicItem.wrappedValue = meta
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: PlexHomeViewController, context: Context) {
        // Refresh the callbacks to capture the latest bindings.
        uiViewController.onSelectMusic = { meta in
            context.coordinator.selectedMusicItem.wrappedValue = meta
        }
    }
}
