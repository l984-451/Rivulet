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
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @State private var choosingProfile = false
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    @AppStorage(IOSLibrarySettingsView.showPlaylistsKey) private var showPlaylists = true
    @State private var backgroundedAt: Date?
    /// The Library tab's selection, column and detail path, so "Go to Downloads" can open it from any tab.
    @State private var librarySelection: IOSLibrarySelection?
    @State private var libraryColumn = NavigationSplitViewColumn.sidebar
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
                IOSPlexLibrarySplitView(selection: $librarySelection, column: $libraryColumn, path: $libraryPath)
                    // A server or profile switch drops the split: its pages hold the old one's items.
                    .id(plex.sessionGeneration)
                    .environment(\.plexZoomNamespace, libraryZoom)
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
                    Tab(plex.displayTitle(library.title, serverID: library.serverID), systemImage: library.icon,
                        value: "library:\(library.id)") {
                        tabStack(sidebarZoom) { IOSPlexLibraryView(library: library, showsAccount: true) }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
                ForEach(showsSidebarLibraries ? playlistServers : [], id: \.self) { key in
                    let serverID = key.isEmpty ? nil : key
                    Tab(plex.displayTitle("Playlists", serverID: serverID), systemImage: "list.and.film",
                        value: "playlists:\(key)") {
                        tabStack(sidebarZoom) { IOSPlexPlaylistsView(serverID: serverID, showsAccount: true) }
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
        .sheet(isPresented: $choosingProfile) { IOSProfilePickerSheet() }
        // Content is withheld until a profile is entered: ask who is watching,
        // and nothing of the locked profile's keeps playing.
        .onChange(of: profiles.needsProfileSelection, initial: true) { _, needed in
            if needed { playback.close() }
            choosingProfile = needed
        }
        .iosPlaybackHost(playback)
        .task { showWhatsNewIfUpdated() }
        #if DEBUG
        .task { await applyScreenshotState() }
        #endif
        .task {
            await plex.verifyConnection()
            // A launch that first had to enter the saved profile is signed in only now.
            showWhatsNewIfUpdated()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
            case .active:
                // The one foreground trigger: re-test a connection left for a while, then refetch stale content.
                let longAway = backgroundedAt.map { Date.now.timeIntervalSince($0) > 5 * 60 } ?? false
                Task {
                    if longAway {
                        await plex.verifyConnection()
                        // The list may have loaded just now and found the profile locked.
                        if profiles.needsProfileSelection, profiles.hasLoadedProfiles { choosingProfile = true }
                    }
                    await plex.refreshIfStale()
                }
                // A dismissed picker leaves content locked; ask again on return.
                if profiles.needsProfileSelection, profiles.hasLoadedProfiles { choosingProfile = true }
                backgroundedAt = nil
            default:
                break
            }
        }
        .onChange(of: sizeClass) { dropOrphanedLibraryTab() }
        .onChange(of: plex.sessionGeneration) {
            librarySelection = nil
            libraryColumn = .sidebar
            libraryPath = NavigationPath()
        }
        .onChange(of: plex.libraries) { _, libraries in
            if !libraries.isEmpty { dropOrphanedLibraryTab() }
            if case .library(let library) = librarySelection, !libraries.contains(library) { librarySelection = nil }
        }
        .onChange(of: playlistServers) { dropOrphanedLibraryTab() }
    }

    /// A sidebar library tab vanishes at compact width or on a server without that library.
    private func dropOrphanedLibraryTab() {
        guard selectedTab.hasPrefix("library:") || selectedTab.hasPrefix("playlists:") || selectedTab == "downloads" else { return }
        let live = showsSidebarLibraries
            ? videoLibraries.map { "library:\($0.id)" } + playlistServers.map { "playlists:\($0)" } + ["downloads"] : []
        if !live.contains(selectedTab) { selectedTab = "library" }
    }

    /// iPad only: a Plus/Max/Air iPhone is regular width in landscape, and tabs added
    /// there crashed UIKit's tab bar rebuild on rotation.
    private var showsSidebarLibraries: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }

    /// Servers with video playlists, by `serverID ?? ""`: the selected one first.
    private var playlistServers: [String] {
        guard showPlaylists else { return [] }
        return plex.videoPlaylists.keys.sorted { lhs, rhs in lhs.isEmpty || (!rhs.isEmpty && lhs < rhs) }
    }

    /// Movie and TV libraries only: iOS has no music player.
    private var videoLibraries: [PlexLibrary] {
        plex.libraries
            .filter { $0.type == "movie" || $0.type == "show" }
            .sorted { lhs, rhs in
                // The selected server's first, then each other server's together.
                guard lhs.serverID == rhs.serverID else { return lhs.serverID == nil }
                return lhs.type != rhs.type
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

    #if DEBUG
    /// Screenshot mode: switch tab, or open a demo library or title on the Library tab.
    private func applyScreenshotState() async {
        if let tab = IOSScreenshotMode.tab { selectedTab = tab }
        guard let title = IOSScreenshotMode.openTitle else { return }
        while plex.libraries.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        if let library = plex.libraries.first(where: { $0.title == title }) {
            selectedTab = "library"
            librarySelection = .library(library)
            libraryColumn = .detail
            return
        }
        guard let item = try? await plex.search(title).first(where: { $0.title == title }) else { return }
        selectedTab = "library"
        libraryColumn = .detail
        libraryPath = NavigationPath([IOSPlexDetailRoute(item: item, scope: "")])
    }
    #endif

    private func openDownloads() {
        if showsSidebarLibraries {
            selectedTab = "downloads"
        } else {
            librarySelection = .downloads
            libraryColumn = .detail
            libraryPath = NavigationPath()
            selectedTab = "library"
        }
    }

    private func tabStack<Content: View>(
        _ namespace: Namespace.ID,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack { content().iosPlexDestinations() }
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
