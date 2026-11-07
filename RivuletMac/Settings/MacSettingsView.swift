// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The Settings window (Cmd-,). One tab per iOS settings page. Parity sources, all in
/// RivuletiOS/Settings/: IOSAccountView (Account), IOSHomeSettings (Home, Library),
/// IOSSettingsPages (Playback), IOSLiveTVSettingsView (Live TV), IOSServerSignInView
/// (server accounts). iCloud sync and the app icon are rows of IOSAccountView.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            MacAccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            pane("Home", symbol: "house", source: "IOSHomeSettings.swift")
            pane("Library", symbol: "rectangle.stack", source: "IOSHomeSettings.swift (IOSLibrarySettingsView)")
            pane("Playback", symbol: "play.rectangle", source: "IOSSettingsPages.swift")
            pane("Live TV", symbol: "play.tv", source: "IOSLiveTVSettingsView.swift")
        }
        .frame(width: 560, height: 420)
    }

    private func pane(_ title: LocalizedStringKey, symbol: String, source: String) -> some View {
        MacFeaturePlaceholder(title: title, symbol: symbol, source: "RivuletiOS/Settings/\(source)")
            .tabItem { Label(title, systemImage: symbol) }
    }
}
