// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Tab bar on iPhone, sidebar on iPad (with each video library listed under Library).
struct IOSRootView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("iosSelectedTab") private var selectedTab = "home"
    @StateObject private var playback = IOSPlaybackController()
    @State private var showingAccount = false
    @State private var showingWhatsNew = false
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    @State private var backgroundedAt: Date?
    /// The Library stack's path, so "Go to Downloads" can push the list from any tab.
    @State private var libraryPath = NavigationPath()
    @Namespace private var homeZoom
    @Namespace private var libraryZoom
    @Namespace private var sidebarZoom
    @Namespace private var searchZoom

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: "home") {
                tabStack(homeZoom) { IOSPlexHomeView() }
            }
            Tab("Library", systemImage: "rectangle.stack", value: "library") {
                tabStack(libraryZoom, path: $libraryPath) { IOSPlexLibrariesView() }
            }
            // The sidebar lists each library itself, so the list tab would repeat it.
            .defaultVisibility(.hidden, for: .sidebar)
            // iPhone flattens sections into the tab bar, so libraries live only in the iPad sidebar.
            TabSection("Library") {
                if showsSidebarLibraries {
                    Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") {
                        tabStack(sidebarZoom) { IOSDownloadsView(showsAccount: true) }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
                ForEach(showsSidebarLibraries ? videoLibraries : []) { library in
                    Tab(library.title, systemImage: library.icon, value: "library:\(library.key)") {
                        tabStack(sidebarZoom) { IOSPlexLibraryView(library: library, showsAccount: true) }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
            }
            Tab("Live TV", systemImage: "play.tv", value: "live-tv") {
                NavigationStack { IOSLiveTVView() }
            }
            Tab(value: "search", role: .search) {
                tabStack(searchZoom) { IOSPlexSearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(\.openAccount) { showingAccount = true }
        .environment(\.openDownloads, openDownloads)
        .sheet(isPresented: $showingAccount) { IOSAccountView() }
        .sheet(isPresented: $showingWhatsNew) { IOSWhatsNewSheet(version: IOSChangelog.currentVersion) }
        .iosPlaybackHost(playback)
        .task { showWhatsNewIfUpdated() }
        .task { await plex.verifyConnection() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
            case .active:
                // The one foreground trigger: re-test a connection left for a while, then refetch stale content.
                let longAway = backgroundedAt.map { Date.now.timeIntervalSince($0) > 5 * 60 } ?? false
                Task {
                    if longAway { await plex.verifyConnection() }
                    await plex.refreshIfStale()
                }
                backgroundedAt = nil
            default:
                break
            }
        }
        .onChange(of: sizeClass) { dropOrphanedLibraryTab() }
        .onChange(of: plex.sessionGeneration) { libraryPath = NavigationPath() }
        .onChange(of: plex.libraries) { _, libraries in
            if !libraries.isEmpty { dropOrphanedLibraryTab() }
        }
    }

    /// A sidebar library tab vanishes at compact width or on a server without that library.
    private func dropOrphanedLibraryTab() {
        guard selectedTab.hasPrefix("library:") || selectedTab == "downloads" else { return }
        let live = showsSidebarLibraries ? videoLibraries.map { "library:\($0.key)" } + ["downloads"] : []
        if !live.contains(selectedTab) { selectedTab = "library" }
    }

    /// iPad only: a Plus/Max/Air iPhone is regular width in landscape, and tabs added
    /// there crashed UIKit's tab bar rebuild on rotation.
    private var showsSidebarLibraries: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }

    /// Movie and TV libraries only: iOS has no music player.
    private var videoLibraries: [PlexLibrary] {
        plex.libraries
            .filter { $0.type == "movie" || $0.type == "show" }
            .sorted { lhs, rhs in
                lhs.type != rhs.type
                    ? lhs.type == "movie"
                    : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// The sidebar's Downloads tab on iPad, else the list pushed on the Library tab.
    /// Once per build, at launch and only when signed in, so it never stacks on the sign-in sheet.
    private func showWhatsNewIfUpdated() {
        let current = IOSChangelog.currentVersion
        guard plex.isConfigured, current != lastSeenBuild else { return }
        lastSeenBuild = current
        showingWhatsNew = IOSChangelog.lines(for: current) != nil
    }

    private func openDownloads() {
        if showsSidebarLibraries {
            selectedTab = "downloads"
        } else {
            libraryPath = NavigationPath([IOSDownloadsRoute()])
            selectedTab = "library"
        }
    }

    private func tabStack<Content: View>(
        _ namespace: Namespace.ID,
        path: Binding<NavigationPath>? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if let path {
                NavigationStack(path: path) { content().iosPlexDestinations() }
            } else {
                NavigationStack { content().iosPlexDestinations() }
            }
        }
        // A server or profile switch pops every stack: open pages hold the old one's items.
        .id(plex.sessionGeneration)
        .environment(\.plexZoomNamespace, namespace)
    }
}

#Preview {
    IOSRootView()
        .environmentObject(IOSPlexSession())
        .environmentObject(IOSDownloadCenter.shared)
}
