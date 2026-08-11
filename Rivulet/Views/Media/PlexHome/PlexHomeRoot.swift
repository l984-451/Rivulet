// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexHomeRoot.swift
//  Rivulet
//
//  SwiftUI shell for the Plex Home screen. Wraps the UIKit
//  `PlexHomeViewController` (via `PlexHomeUIKitBridge`) in a
//  NavigationStack so music selections still navigate via SwiftUI's stack
//  to the music routers. Everything else navigates inside UIKit.
//

import SwiftUI

struct PlexHomeRoot: View {
    var body: some View {
        UIKitHomeContainer()
    }
}

/// SwiftUI shell that owns the NavigationStack + music-selection binding
/// for the UIKit home. Media detail navigation happens inside the UIKit
/// controller; only music selections flip the binding here and push the
/// music routers.
///
/// Also mirrors the SwiftUI home's `nestedNavigationState.isNested` plumb:
/// the sidebar reads this flag to hide its tab bar while a detail view is
/// on top.
struct UIKitHomeContainer: View {
    /// Surface to render — .home (default) or .library(key:title:). Library
    /// call sites pass their key/title and `.id(key)` the container so each
    /// library gets a fresh controller.
    var mode: HomeMode = .home
    @State private var selectedMusicItem: PlexMetadata?
    @Environment(\.nestedNavigationState) private var nestedNavState

    var body: some View {
        NavigationStack {
            PlexHomeUIKitBridge(mode: mode, selectedMusicItem: $selectedMusicItem)
                .ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $selectedMusicItem) { meta in
                    switch meta.type {
                    case "artist": MusicSearchDetailRouter(plexMeta: meta, kind: .artist)
                    case "album": MusicSearchDetailRouter(plexMeta: meta, kind: .album)
                    default: EmptyView()
                    }
                }
        }
        .onChange(of: selectedMusicItem) { _, newValue in
            nestedNavState.isNested = newValue != nil
        }
    }
}
