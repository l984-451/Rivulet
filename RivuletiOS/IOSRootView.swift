// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Tab bar on iPhone, sidebar on iPad (with each video library listed under Library).
struct IOSRootView: View {
    @EnvironmentObject private var plex: PlexSession
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("iosSelectedTab") private var selectedTab = "home"
    @ObservedObject private var playback = IOSPlaybackController.shared
    @State private var showingAccount = false
    @State private var showingWhatsNew = false
    @State private var whatsNewVersions: [String] = []
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @State private var choosingProfile = false
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    @AppStorage(IOSLibrarySettingsView.showPlaylistsKey) private var showPlaylists = true
    @AppStorage("showFavoritesTab") private var showFavorites = false
    @State private var backgroundedAt: Date?
    /// The Library tab's selection, column and detail path, so "Go to Downloads" can open it from any tab.
    @State private var librarySelection: IOSLibrarySelection?
    @State private var libraryColumn = NavigationSplitViewColumn.sidebar
    @State private var libraryPath = NavigationPath()
    /// Each sidebar library tab's pushed pages, by tab value, so they can follow the
    /// library into the Library tab when the window narrows and the tab goes away.
    @State private var sidebarPaths: [String: NavigationPath] = [:]
    /// Where the tab view shows its tabs, as the tabs' content reports it (only content can
    /// read it): the iPad sidebar or the top bar. Nil until the first report.
    @State private var tabBarPlacement: TabBarPlacement?
    @Namespace private var homeZoom
    @Namespace private var libraryZoom
    @Namespace private var sidebarZoom
    @Namespace private var searchZoom
    /// The app's one gate: a window opened after launch finds it finished and shows no splash.
    @ObservedObject private var splashGate: LaunchSplashGate
    /// The splash's exit has played; launch sheets wait for it.
    @State private var splashGone: Bool
    /// What's New found at launch, held until the splash has gone.
    @State private var whatsNewPending = false

    init(splashGate: LaunchSplashGate) {
        self.splashGate = splashGate
        _splashGone = State(initialValue: splashGate.isFinished)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: "home") {
                tabStack(homeZoom) {
                    IOSPlexHomeView().environment(\.launchHeroReady) { splashGate.heroIsReady() }
                }
            }
            // iPhone flattens sections into the tab bar, so libraries live only in the iPad sidebar.
            TabSection("Library") {
                // First in the section, so the iPad top bar's Library opens the list, not the last page picked.
                Tab("Library", systemImage: "rectangle.stack", value: "library") {
                    IOSPlexLibrarySplitView(selection: $librarySelection, column: $libraryColumn, path: $libraryPath)
                        // A server or profile switch drops the split: its pages hold the old one's items.
                        .id(browse.sessionGeneration)
                        .environment(\.plexZoomNamespace, libraryZoom)
                        .reportsTabBarPlacement($tabBarPlacement)
                }
                // The sidebar lists each library itself, so the list tab would repeat it.
                // While the sidebar shows, this tab hands its library to the library's own tab.
                .defaultVisibility(.hidden, for: .sidebar)
                if showsSidebarLibraries {
                    Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") {
                        sidebarStack("downloads") { IOSDownloadsView(showsAccount: true) }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
                if showsSidebarLibraries, showsFavorites {
                    Tab("Favorites", systemImage: "heart", value: "favorites") {
                        sidebarStack("favorites") { IOSFavoritesView(showsAccount: true) }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
                // Not by `id`: that is the server's own section number, so two servers collide and UIKit's sidebar throws.
                ForEach(showsSidebarLibraries ? videoLibraries : [], id: \.self) { library in
                    Tab(browse.labels.title(library.title, providerID: library.providerID), systemImage: library.iosIcon,
                        value: libraryTab(library)) {
                        sidebarStack(libraryTab(library)) { IOSLibraryPage(library: library, showsAccount: true) }
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
                    .reportsTabBarPlacement($tabBarPlacement)
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
        .sheet(isPresented: $showingAccount) { IOSAccountView().iosSessionObjects(plex) }
        .sheet(isPresented: $showingWhatsNew) { IOSWhatsNewSheet(versions: whatsNewVersions) }
        .sheet(isPresented: $choosingProfile) { IOSProfilePickerSheet() }
        // Content is withheld until a profile is entered: ask who is watching,
        // and nothing of the locked profile's keeps playing.
        .onChange(of: profiles.needsProfileSelection, initial: true) { _, needed in
            if needed { playback.close() }
            choosingProfile = needed
        }
        // Over the tab bar, sidebar and bars too, until its exit has played.
        .overlay {
            if !splashGone {
                IOSLaunchSplash(finished: splashGate.isFinished) { splashGone = true }
                    .ignoresSafeArea()
            }
        }
        // Only Home's hero is worth waiting for; another restored tab opens without it.
        .onChange(of: showsHome, initial: true) { _, home in
            if !home { splashGate.heroIsReady() }
        }
        .onChange(of: splashGone) { presentWhatsNewIfReady() }
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
        // regular width it returns to its sidebar tab if the sidebar shows.
        .onChange(of: showsSidebarLibraries) { _, sidebar in
            if sidebar { placeLibraryTab() } else { foldSidebarTab() }
        }
        // The sidebar shown or hidden, the Library tab picked, or a library loaded.
        .onChange(of: tabBarPlacement) { placeLibraryTab() }
        .onChange(of: selectedTab) { placeLibraryTab() }
        .onChange(of: sidebarTabs) { placeLibraryTab() }
        .onChange(of: browse.isLoadingContent) { placeLibraryTab() }
        .onChange(of: browse.sessionGeneration) {
            librarySelection = nil
            libraryColumn = .sidebar
            libraryPath = NavigationPath()
            sidebarPaths = [:]
        }
        .onChange(of: browse.libraries) { _, libraries in
            if !libraries.isEmpty, !browse.isLoadingOtherServers { dropOrphanedLibraryTab() }
            dropMissingLibrarySelection()
        }
        .onChange(of: browse.photoLibraries) { dropMissingLibrarySelection() }
        .onChange(of: browse.hiddenSidebarLibraries) {
            dropOrphanedLibraryTab()
            dropMissingLibrarySelection()
        }
        .onChange(of: browse.isLoadingOtherServers) { _, loading in
            if !loading, !browse.libraries.isEmpty { dropOrphanedLibraryTab() }
        }
        .onChange(of: playlistServers) { if !browse.isLoadingOtherServers { dropOrphanedLibraryTab() } }
        .onChange(of: showsFavorites) { if !browse.isLoadingOtherServers { dropOrphanedLibraryTab() } }
    }

    /// A library gone from the server or hidden in Settings leaves the selection.
    private func dropMissingLibrarySelection() {
        if case .library(let library) = librarySelection, !browse.shownLibraries.contains(library) {
            librarySelection = nil
            libraryPath = NavigationPath()
        }
    }

    /// Home is on screen: its own tab, or a stored tab this window does not have (a tab from an
    /// older build, or a library not loaded yet), for which the tab view shows its first tab, Home.
    private var showsHome: Bool {
        selectedTab == "home" || !(["library", "live-tv", "search"] + sidebarTabs).contains(selectedTab)
    }

    /// A sidebar library tab vanishes on a server without that library.
    private func dropOrphanedLibraryTab() {
        guard Self.isSidebarTab(selectedTab), !sidebarTabs.contains(selectedTab) else { return }
        selectedTab = "library"
    }

    /// Libraries are listed in one place at a time. While the iPad sidebar shows it lists
    /// them, so the Library tab's library carries on in its own sidebar tab, selected there.
    /// While the top bar shows, a sidebar tab folds into the Library tab, whose list is then
    /// the only one (the top bar's Library opens it). Compact width is `foldSidebarTab`'s.
    private func placeLibraryTab() {
        guard showsSidebarLibraries, let placement = tabBarPlacement else { return }
        if placement == .sidebar {
            unfoldLibraryTab()
        } else if placement == .topBar, librarySelection(forTab: selectedTab) != nil {
            // A tab whose library has not loaded yet waits for it (`sidebarTabs` changes).
            foldSidebarTab()
        }
    }

    /// The window narrowed or the top bar replaced the sidebar: the sidebar tab's library,
    /// and the pages pushed over it, carry on in the Library tab's detail column.
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

    /// The sidebar is showing: the Library tab's library, and the pages pushed over it,
    /// carry on in that library's sidebar tab. With none picked (or one gone), the first
    /// library opens, as the split view picks it; with no library loaded yet, it waits, and
    /// a load that found none (offline, failed) leaves Downloads.
    private func unfoldLibraryTab() {
        guard selectedTab == "library" else { return }
        let picked = librarySelection.map(tab(for:)).flatMap { sidebarTabs.contains($0) ? $0 : nil }
        let settled = browse.hasRefreshed && !browse.isLoadingContent
        guard let target = picked ?? videoLibraries.first.map(libraryTab) ?? (settled ? "downloads" : nil) else { return }
        sidebarPaths[target] = picked != nil ? libraryPath : NavigationPath()
        libraryColumn = .sidebar
        libraryPath = NavigationPath()
        selectedTab = target
    }

    private static func isSidebarTab(_ tab: String) -> Bool {
        tab.hasPrefix("library:") || tab.hasPrefix("playlists:") || tab == "downloads" || tab == "favorites"
    }

    private func tab(for selection: IOSLibrarySelection) -> String {
        switch selection {
        case .downloads: "downloads"
        case .favorites: "favorites"
        case .library(let library): libraryTab(library)
        case .playlists(let providerID): playlistsTab(providerID)
        }
    }

    private func librarySelection(forTab tab: String) -> IOSLibrarySelection? {
        if tab == "downloads" { return .downloads }
        if tab == "favorites", showsFavorites { return .favorites }
        if let library = videoLibraries.first(where: { libraryTab($0) == tab }) { return .library(library) }
        if let id = playlistServers.first(where: { playlistsTab($0) == tab }) { return .playlists(providerID: id) }
        return nil
    }

    /// Every sidebar library tab while they show, libraries first.
    private var sidebarTabs: [String] {
        guard showsSidebarLibraries else { return [] }
        return videoLibraries.map(libraryTab) + playlistServers.map(playlistsTab) + ["downloads"]
            + (showsFavorites ? ["favorites"] : [])
    }

    /// The sidebar is up, not the top bar, so it lists the libraries itself.
    private var sidebarListsLibraries: Bool {
        showsSidebarLibraries && tabBarPlacement == .sidebar
    }

    /// The Library list's Favorites row, which Account > Library turns on.
    private var showsFavorites: Bool { showFavorites && browse.offersFavorites }

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

    /// Movie, TV and photo libraries: iOS has no music player. Each server's together, the selected first.
    private var videoLibraries: [MediaLibrary] {
        browse.shownLibraries.sidebarOrder(servers: browse.providerOrder)
    }

    private func libraryTab(_ library: MediaLibrary) -> String { "library:\(library.providerID)|\(library.id)" }
    private func playlistsTab(_ providerID: String) -> String { "playlists:\(providerID)" }

    /// Once per build, at launch and only when signed in, so it never stacks on the sign-in sheet.
    private func showWhatsNewIfUpdated() {
        let current = IOSChangelog.currentVersion
        guard plex.isConfigured, current != lastSeenBuild else { return }
        whatsNewVersions = WhatsNewRange.versions(IOSChangelog.entries.map(\.version), current: current, lastSeen: lastSeenBuild)
        lastSeenBuild = current
        whatsNewPending = !whatsNewVersions.isEmpty
        presentWhatsNewIfReady()
    }

    /// What's New slides up once the launch splash has gone, never over it.
    private func presentWhatsNewIfReady() {
        guard whatsNewPending, splashGone else { return }
        whatsNewPending = false
        showingWhatsNew = true
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
        guard let item = try? await SearchResults.search(title, providers: browse.searchProviders).titles.first(where: { $0.title == title }) else { return }
        selectedTab = "library"
        libraryColumn = .detail
        // iPad's split view picks a library on appear and clears the path when it does, so pick first.
        if let library = browse.libraries.first(where: { $0.id == item.libraryID }) {
            librarySelection = .library(library)
            try? await Task.sleep(for: .seconds(2))
        }
        let path = NavigationPath([IOSPlexDetailRoute(item: item, scope: "")])
        // With the iPad sidebar showing, the library has moved to its sidebar tab.
        if Self.isSidebarTab(selectedTab) { sidebarPaths[selectedTab] = path } else { libraryPath = path }
    }
    #endif

    /// The sidebar's Downloads tab while the iPad sidebar shows, else Downloads in the Library tab.
    private func openDownloads() {
        if sidebarListsLibraries {
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
        .reportsTabBarPlacement($tabBarPlacement)
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
        .reportsTabBarPlacement($tabBarPlacement)
    }
}

private extension View {
    /// Passes the tab view's tab bar placement up to the root, which sits outside the
    /// tab view where the value is never set. Every tab's content carries this, so the
    /// root hears the sidebar shown or hidden on whichever tab is in front.
    func reportsTabBarPlacement(_ placement: Binding<TabBarPlacement?>) -> some View {
        modifier(TabBarPlacementReporter(reported: placement))
    }
}

private struct TabBarPlacementReporter: ViewModifier {
    @Environment(\.tabBarPlacement) private var placement
    @Binding var reported: TabBarPlacement?

    func body(content: Content) -> some View {
        // Nil is an unknown placement, not a change: the last known one stands.
        content.onChange(of: placement, initial: true) { _, now in
            if let now, now != reported { reported = now }
        }
    }
}

#Preview {
    let session = PlexSession()
    IOSRootView(splashGate: LaunchSplashGate(browse: session.browse))
        .environmentObject(session)
        .environmentObject(session.browse)
        .environmentObject(IOSDownloadCenter.shared)
}
