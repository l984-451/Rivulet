// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Go menu (sidebar jumps), Refresh, and Help > What's New. The Playback menu lives in Player/.
struct MacShellCommands: Commands {
    @ObservedObject var browse: BrowseStore
    @FocusedBinding(\.macSelection) private var selection: MacSidebarItem??
    @Environment(\.openWindow) private var openWindow

    @AppStorage(MacSettingsKeys.showPlaylists) private var showPlaylists = true
    @AppStorage(MacSettingsKeys.showFavorites) private var showFavorites = false
    @FocusedValue(\.macHistory) private var history: MacHistory?
    @FocusedValue(\.macAccountMenu) private var account: MacAccountMenuActions?
    @FocusedValue(\.macPageRefresh) private var pageRefresh: MacPageRefresh?

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .appInfo) {
            Button("Account…") { account?.box.openAccount() }
                .disabled(account == nil)
            if let account, account.canSwitchProfile {
                Button("Switch Profile…") { account.box.switchProfile() }
            }
        }
        CommandMenu("Go") {
            Button("Back") { history?.box.back() }
                .keyboardShortcut("[")
                .disabled(history?.canBack != true)
            Button("Forward") { history?.box.forward() }
                .keyboardShortcut("]")
                .disabled(history?.canForward != true)
            Divider()
            Button("Home") { selection = .some(.home) }
                .keyboardShortcut("1")
            Button("Search") {
                selection = .some(.search)
                NotificationCenter.default.post(name: .macFocusSearch, object: nil)
            }
                .keyboardShortcut("f")
            Button("Live TV") { selection = .some(.liveTV) }
                .keyboardShortcut("2")
            if showFavorites, browse.offersFavorites {
                Button("Favorites") { selection = .some(.favorites) }
                    .keyboardShortcut("3")
            }
            let libraries = browse.sidebarAllLibraries.sidebarOrder(servers: browse.providerOrder)
            if !libraries.isEmpty { Divider() }
            ForEach(Array(libraries.enumerated()), id: \.element) { index, library in
                let title = browse.labels.title(library.title, providerID: library.providerID)
                if index < 6 {
                    Button(title) { selection = .some(.library(library)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 4))))
                } else {
                    Button(title) { selection = .some(.library(library)) }
                }
            }
            if showPlaylists {
                ForEach(browse.providerOrder.filter { browse.playlists[$0] != nil }, id: \.self) { id in
                    Button(browse.labels.title(String(localized: "Playlists"), providerID: id)) {
                        selection = .some(.playlists(providerID: id))
                    }
                }
            }
            Divider()
            Button("Refresh") {
                if let pageRefresh { pageRefresh() } else { Task { await browse.refresh() } }
            }
                .keyboardShortcut("r")
        }
        CommandGroup(after: .help) {
            Button("What's New") { openWindow(id: MacWhatsNewWindow.id) }
        }
    }
}

extension Notification.Name {
    /// Cmd-F: the search page focuses its field even when it is already showing.
    static let macFocusSearch = Notification.Name("macFocusSearch")
}

enum MacWhatsNewWindow {
    static let id = "whats-new"
}
