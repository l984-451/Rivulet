// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Tab bar on iPhone, sidebar on iPad (with each video library listed under Library).
struct IOSRootView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var browse: IOSBrowseStore
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
    /// Each sidebar library tab's pushed pages, by tab value, so they can follow the
    /// library into the Library tab when the window narrows and the tab goes away.
    @State private var sidebarPaths: [String: NavigationPath] = [:]
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
                    .id(browse.sessionGeneration)
                    .environment(\.plexZoomNamespace, libraryZoom)
            }
            // The sidebar lists each library itself, so the list tab would repeat it.
            .defaultVisibility(.hidden, for: .sidebar)
            // iPhone flattens sections into the tab bar, so libraries live only in the iPad sidebar.
            TabSection("Library") {
                if showsSidebarLibraries {
                    Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") {
                        sidebarStack("downloads") { IOSDownloadsView(showsAccount: true) }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
                ForEach(showsSidebarLibraries ? videoLibraries : []) { library in
                    Tab(browse.labels.title(library.title, providerID: library.providerID), systemImage: library.icon,
                        value: libraryTab(library)) {
                        sidebarStack(libraryTab(library)) { IOSPlexLibraryView(library: library, showsAccount: true) }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
                ForEach(showsSidebarLibraries ? playlistServers : [], id: \.self) { providerID in
                    Tab(browse.labels.title(String(localized: "Playlists"), providerID: providerID), systemImage: "list.and.film",
                        value: playlistsTab(providerID)) {
                        sidebarStack(playlistsTab(providerID)) { IOSPlexPlaylistsView(providerID: providerID, showsAccount: true) }
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
                    await browse.refreshIfStale()
                }
                // A dismissed picker leaves content locked; ask again on return.
                if profiles.needsProfileSelection, profiles.hasLoadedProfiles { choosingProfile = true }
                backgroundedAt = nil
            default:
                break
            }
        }
        // Stage Manager and Split View resize the window: at compact width the sidebar's
        // library tabs vanish, and the one in use folds into the Library tab. Back at
        // regular width the Library tab's library returns to its sidebar tab.
        .onChange(of: showsSidebarLibraries) { _, sidebar in
            if sidebar { unfoldLibraryTab() } else { foldSidebarTab() }
        }
        .onChange(of: browse.sessionGeneration) {
            librarySelection = nil
            libraryColumn = .sidebar
            libraryPath = NavigationPath()
            sidebarPaths = [:]
        }
        .onChange(of: browse.libraries) { _, libraries in
            if !libraries.isEmpty, !browse.isLoadingOtherServers { dropOrphanedLibraryTab() }
            if case .library(let library) = librarySelection, !libraries.contains(library) {
                librarySelection = nil
                libraryPath = NavigationPath()
            }
        }
        .onChange(of: browse.isLoadingOtherServers) { _, loading in
            if !loading, !browse.libraries.isEmpty { dropOrphanedLibraryTab() }
        }
        .onChange(of: playlistServers) { if !browse.isLoadingOtherServers { dropOrphanedLibraryTab() } }
    }

    /// A sidebar library tab vanishes on a server without that library.
    private func dropOrphanedLibraryTab() {
        guard Self.isSidebarTab(selectedTab), !sidebarTabs.contains(selectedTab) else { return }
        selectedTab = "library"
    }

    /// The window narrowed: the sidebar tab's library, and the pages pushed over it,
    /// carry on in the Library tab's detail column.
    private func foldSidebarTab() {
        guard Self.isSidebarTab(selectedTab) else { return }
        guard let selection = librarySelection(forTab: selectedTab) else {
            selectedTab = "library"
            return
        }
        librarySelection = selection
        libraryColumn = .detail
        libraryPath = sidebarPaths.removeValue(forKey: selectedTab) ?? NavigationPath()
        selectedTab = "library"
    }

    /// The window widened: the Library tab's library, and the pages pushed over it,
    /// carry on in that library's sidebar tab.
    private func unfoldLibraryTab() {
        guard selectedTab == "library", let selection = librarySelection else { return }
        let tab = tab(for: selection)
        guard sidebarTabs.contains(tab) else { return }
        sidebarPaths[tab] = libraryPath
        libraryColumn = .sidebar
        libraryPath = NavigationPath()
        selectedTab = tab
    }

    private static func isSidebarTab(_ tab: String) -> Bool {
        tab.hasPrefix("library:") || tab.hasPrefix("playlists:") || tab == "downloads"
    }

    private func tab(for selection: IOSLibrarySelection) -> String {
        switch selection {
        case .downloads: "downloads"
        case .favorites: "favorites"  // not a sidebar tab: stays under Library
        case .library(let library): libraryTab(library)
        case .playlists(let providerID): playlistsTab(providerID)
        }
    }

    private func librarySelection(forTab tab: String) -> IOSLibrarySelection? {
        if tab == "downloads" { return .downloads }
        if let library = videoLibraries.first(where: { libraryTab($0) == tab }) { return .library(library) }
        if let id = playlistServers.first(where: { playlistsTab($0) == tab }) { return .playlists(providerID: id) }
        return nil
    }

    /// Every sidebar library tab while they show, libraries first.
    private var sidebarTabs: [String] {
        guard showsSidebarLibraries else { return [] }
        return videoLibraries.map(libraryTab) + playlistServers.map(playlistsTab) + ["downloads"]
    }

    /// iPad only: a Plus/Max/Air iPhone is regular width in landscape, and tabs added
    /// there crashed UIKit's tab bar rebuild on rotation.
    private var showsSidebarLibraries: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }

    /// Servers with video playlists, the selected one first.
    private var playlistServers: [String] {
        guard showPlaylists else { return [] }
        return browse.providerOrder.filter { browse.playlists[$0] != nil }
    }

    /// Movie and TV libraries only: iOS has no music player. Each server's together, the selected first.
    private var videoLibraries: [MediaLibrary] {
        browse.libraries.sidebarOrder(servers: browse.providerOrder)
    }

    private func libraryTab(_ library: MediaLibrary) -> String { "library:\(library.providerID)|\(library.id)" }
    private func playlistsTab(_ providerID: String) -> String { "playlists:\(providerID)" }

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
        while browse.libraries.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        if let library = browse.libraries.first(where: { $0.title == title }) {
            selectedTab = "library"
            librarySelection = .library(library)
            libraryColumn = .detail
            return
        }
        guard let item = try? await SearchResults.search(title, providers: browse.searchProviders).first(where: { $0.title == title }) else { return }
        selectedTab = "library"
        libraryColumn = .detail
        // iPad's split view picks a library on appear and clears the path when it does, so pick first.
        if let library = browse.libraries.first(where: { $0.id == item.libraryID }) {
            librarySelection = .library(library)
            try? await Task.sleep(for: .seconds(2))
        }
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
        .id(browse.sessionGeneration)
        .environment(\.plexZoomNamespace, namespace)
    }

    /// A sidebar library tab's stack, its pages kept in `sidebarPaths` under the tab's value.
    private func sidebarStack<Content: View>(_ tab: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: Binding(
            get: { sidebarPaths[tab] ?? NavigationPath() },
            set: { sidebarPaths[tab] = $0 }
        )) {
            content().iosPlexDestinations()
        }
        .id(browse.sessionGeneration)
        .environment(\.plexZoomNamespace, sidebarZoom)
    }
}

#Preview {
    let session = IOSPlexSession()
    IOSRootView()
        .environmentObject(session)
        .environmentObject(session.browse)
        .environmentObject(IOSDownloadCenter.shared)
}
