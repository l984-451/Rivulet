// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// PIN sign-in, then server choice, then the profile picker when the Plex Home has several users.
/// Parity source: IOSPlexConnectionSheet in RivuletiOS/Shell/IOSAccountViews.swift.
struct MacPlexSignInSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            MacFeaturePlaceholder(title: "Sign In to Plex", symbol: "person.crop.circle",
                                  source: "RivuletiOS/Shell/IOSAccountViews.swift (IOSPlexConnectionSheet)")
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 420, height: 320)
    }
}

/// Jellyfin or Emby sign-in. Parity source: RivuletiOS/Settings/IOSServerSignInView.swift.
struct MacServerSignInSheet: View {
    let kind: MediaProviderKind
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            MacFeaturePlaceholder(title: "Sign In", symbol: "server.rack",
                                  source: "RivuletiOS/Settings/IOSServerSignInView.swift")
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 420, height: 320)
    }
}
