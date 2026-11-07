// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Go menu (sidebar jumps), Refresh, and Help > What's New. The Playback menu lives in Player/.
struct MacShellCommands: Commands {
    @ObservedObject var browse: BrowseStore
    @FocusedBinding(\.macSelection) private var selection: MacSidebarItem??
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Go") {
            Button("Home") { selection = .some(.home) }
                .keyboardShortcut("1")
            Button("Search") { selection = .some(.search) }
                .keyboardShortcut("f")
            Button("Live TV") { selection = .some(.liveTV) }
                .keyboardShortcut("2")
            Button("Favorites") { selection = .some(.favorites) }
                .keyboardShortcut("3")
                .disabled(!browse.offersFavorites)
            Divider()
            Button("Refresh") { Task { await browse.refresh() } }
                .keyboardShortcut("r")
        }
        CommandGroup(after: .help) {
            Button("What's New") { openWindow(id: MacWhatsNewWindow.id) }
        }
    }
}

enum MacWhatsNewWindow {
    static let id = "whats-new"
}
