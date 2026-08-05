// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Touch-first navigation using Apple's native five-item tab bar.
struct IOSRootView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var navigation: IOSNavigationSettings
    @State private var selectedID = "home"
    @State private var showingSettings = false

    var body: some View {
        let items = navigation.visibleItems(for: plex.libraries)
        TabView(selection: $selectedID) {
            ForEach(items) { item in
                Tab(item.title, systemImage: item.icon, value: item.id) {
                    tabContent(item)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) { IOSPlexSettingsView() }
        .onChange(of: items) { _, updated in
            if !updated.contains(where: { $0.id == selectedID }) {
                selectedID = updated.first?.id ?? "home"
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ item: IOSNavigationSettings.Item) -> some View {
        switch item.kind {
        case .home:
            IOSPlexHomeView(showSettings: { showingSettings = true })
        case .library:
            if let library = item.library {
                NavigationStack {
                    IOSPlexLibraryView(library: library, showSettings: { showingSettings = true })
                }
            }
        case .recordings:
            IOSPlexRecordingsView(showSettings: { showingSettings = true })
        case .liveTV:
            IOSLiveTVView(showSettings: { showingSettings = true })
        case .settings:
            IOSPlexSettingsView()
        case .search:
            IOSPlexSearchView(showSettings: { showingSettings = true })
        }
    }
}

private struct IOSPlexRecordingsView: View {
    let showSettings: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Recordings",
                systemImage: "rectangle.stack.badge.play",
                description: Text("Plex DVR recordings will appear here when the recording library is available.")
            )
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    IOSAccountMenu(showSettings: showSettings)
                }
            }
        }
    }
}

#Preview {
    IOSRootView()
        .environmentObject(IOSPlexSession())
        .environmentObject(IOSNavigationSettings())
}
