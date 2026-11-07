// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Profile, servers, sync, icon and sign-out. Shown as the Settings Account tab and, with
/// `showsDone`, as the sheet the toolbar avatar opens. Parity source: RivuletiOS/Settings/IOSAccountView.swift.
struct MacAccountView: View {
    var showsDone = false
    @EnvironmentObject private var plex: PlexSession
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingSignIn = false

    var body: some View {
        Form {
            Section("Plex") {
                if plex.isSignedIn {
                    LabeledContent("Signed in as", value: plex.profileDisplayName ?? profiles.selectedUser?.displayName ?? "")
                    if let server = plex.selectedServerName { LabeledContent("Server", value: server) }
                } else {
                    Button("Sign In to Plex") { showingSignIn = true }
                }
            }
            Section("Servers") {
                Text("Jellyfin and Emby sign-in not built yet.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingSignIn) { MacPlexSignInSheet() }
        .toolbar {
            if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}
