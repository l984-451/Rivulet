// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

@main
struct RivuletiOSApp: App {
    @StateObject private var plex = IOSPlexSession()
    @StateObject private var navigation = IOSNavigationSettings()

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(plex)
                .environmentObject(navigation)
        }
    }
}
