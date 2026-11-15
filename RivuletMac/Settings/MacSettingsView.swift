// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The Settings window (Cmd-,). One tab per iOS settings page. Parity sources, all in
/// RivuletiOS/Settings/: IOSAccountView (Account, General), IOSHomeSettings (Home, Library),
/// IOSSettingsPages (Playback), IOSLiveTVSettingsView (Live TV). Downloads is iOS only.
struct MacSettingsView: View {
    @ObservedObject private var profiles = PlexUserProfileManager.shared

    var body: some View {
        TabView {
            MacAccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            MacHomeSettingsView()
                .tabItem { Label("Home", systemImage: "house") }
            MacLibrarySettingsView()
                .tabItem { Label("Library", systemImage: "rectangle.stack") }
            MacPlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            MacPhotoSettingsView()
                .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
            // Sources and server choice are the owner's, not a restricted profile's.
            if !profiles.isRestrictedProfile {
                MacLiveTVSettingsView()
                    .tabItem { Label("Live TV", systemImage: "play.tv") }
            }
            MacGeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 440, idealHeight: 520)
    }
}
