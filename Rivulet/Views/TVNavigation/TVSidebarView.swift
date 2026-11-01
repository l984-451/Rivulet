// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TVSidebarView.swift
//  Rivulet
//
//  Main tvOS navigation state, hosting the UIKit shell (RootShellViewController)
//

import SwiftUI
import os.log
import Sentry

// Temporary diagnostic logger for intermittent sidebar focus loss.
nonisolated private let libraryIndexLog = Logger(subsystem: "com.rivulet.app", category: "LibraryIndex")

// MARK: - TVSidebarView

struct TVSidebarView: View {
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var dataStore = PlexDataStore.shared
    // Observed directly so the sidebar rebuilds when library visibility/order
    // changes in settings. `dataStore.visibleMediaLibraries` reads from this
    // manager but holds it as a plain `let`, so without an explicit
    // @StateObject here, SwiftUI doesn't see hiddenLibraryKeys updates.
    @StateObject private var librarySettings = LibrarySettingsManager.shared
    @StateObject private var liveTVDataStore = LiveTVDataStore.shared
    // Other servers' libraries (sidebar sections) and sign-ins (welcome gate).
    @StateObject private var serverStore = ServerDataStore.shared
    @StateObject private var profileManager = PlexUserProfileManager.shared
    @StateObject private var nestedNavState = NestedNavigationState()
    @StateObject private var deepLinkHandler = DeepLinkHandler.shared
    @AppStorage("combineLiveTVSources") private var combineLiveTVSources = true
    @AppStorage("showDiscoverTab") private var showDiscoverTab = true
    @AppStorage("showWatchlistTab") private var showWatchlistTab = true
    @State private var selectedTab: SidebarTab = .home
    @State private var showProfilePicker = false
    /// A profile was entered through the picker; any other close re-presents it.
    @State private var profileChosen = false
    @State private var showProfileSwitcher = false
    /// The last profile entered, and the sidebar close a switch away from it asks for.
    @State private var lastProfileId: Int?
    @State private var sidebarCollapseRequest = 0
    /// The profile the switcher opened on, and the sidebar reopen that closing
    /// it on the same profile asks for.
    @State private var switcherProfileId: Int?
    @State private var sidebarProfileRowRequest = 0
    @State private var hasCheckedProfilePicker = false
    @State private var isAwaitingProfileSelection = false
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    /// The setup landing was finished. Unset, an install that already has a source counts as set up.
    @AppStorage("setupComplete") private var setupComplete = SetupLandingViewController.hasAnySource
    @State private var showWhatsNew = false
    @State private var didApplyDebugLaunch = false

    @Namespace private var contentNamespace

    /// Home's welcome overlay stands down for any signed-in server.
    private var isSignedInToAnyServer: Bool {
        authManager.hasCredentials || serverStore.isSignedIn
    }

    /// Signing out of everything brings the setup landing back.
    private var hasAnySource: Bool {
        isSignedInToAnyServer || liveTVDataStore.sources.contains { !$0.sourceType.followsServer }
    }

    private var profileName: String {
        profileManager.selectedUser?.displayName ?? authManager.username ?? "Account"
    }

    private var isMusicLibrarySelected: Bool {
        guard case .library(let key) = selectedTab else { return false }
        return dataStore.libraries.first(where: { $0.key == key })?.isMusicLibrary ?? false
    }

    /// The collapsed pill sits top-left, over the guide's info bar, which puts
    /// it on top of the focused programme's poster. Hide it here rather than
    /// pushing the whole guide down to clear it.
    private var isLiveTVSelected: Bool {
        if case .liveTV = selectedTab { return true }
        return false
    }

    /// Same collision on Search: the pill sits on the left end of the system
    /// search field (#292). The field cannot be pushed clear of it — the search
    /// controller owns that layout and restores it with its own arithmetic, so
    /// insetting it left the keyboard clipped on the way back from a result
    /// (see `SearchContainerViewController.viewDidLoad`). Hide the pill instead.
    private var isSearchSelected: Bool {
        if case .search = selectedTab { return true }
        return false
    }

    /// The sidebar's content, built from LIVE values: this view observes all
    /// the feeding stores, so any change re-renders and pushes fresh sections
    /// into the shell. The old snapshot dance existed only because the system
    /// sidebar wedged on live mutation; ours does not.
    private var shellSections: [ShellSidebarSection] {
        ShellSidebarModel.sections(
            libraries: SidebarLibrary.current(),
            liveTVSources: liveTVDataStore.sources,
            combineLiveTV: combineLiveTVSources,
            showDiscover: showDiscoverTab,
            showWatchlist: showWatchlistTab,
            order: librarySettings.libraryOrder,
            hiddenKeys: librarySettings.hiddenLibraryKeys,
            profileName: profileName,
            profileAvatar: profileManager.selectedUser?.thumb.flatMap { URL(string: $0) },
            canSwitchProfile: profileManager.hasMultipleProfiles,
            hasMediaServer: isSignedInToAnyServer,
            playlistServers: PlaylistServer.current(visiblePlaylistProviders))
    }

    /// Servers that get a Playlists row: those with playlists, less the rows Settings hides.
    private var visiblePlaylistProviders: Set<String> {
        Set(PlaylistServer.current(PlaylistAvailability.shared.providerIDs)
            .filter { librarySettings.isPlaylistsRowVisible(SidebarArrangement.playlists(server: $0.serverID)) }
            .map(\.providerID))
    }

    private var opensToLiveTV: Bool {
        ShellSidebarModel.opensToLiveTV(hasMediaServer: isSignedInToAnyServer, liveTVSources: liveTVDataStore.sources)
    }

    private var tabSelection: Binding<SidebarTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                // Block tab changes while in nested navigation (carousel,
                // detail view, or deep Settings sub-page).
                if nestedNavState.isNested || nestedNavState.isSettingsSubPage {
                    return
                }

                if newTab == .account {
                    if profileManager.hasMultipleProfiles {
                        showProfileSwitcher = true
                    }
                    return  // Never store .account — selectedTab stays unchanged
                }
                selectedTab = newTab
            }
        )
    }

    /// The UIKit shell, which owns Menu-to-Home (#192) and the sidebar focus
    /// rules. Its modifiers keep the selected tab valid.
    private var shell: some View {
        RootShellHost(
            selection: tabSelection,
            interactionBlocked: nestedNavState.isNested || nestedNavState.isSettingsSubPage,
            pillSuppressed: isMusicLibrarySelected || isLiveTVSelected || isSearchSelected,
            collapseRequest: sidebarCollapseRequest,
            profilePanelOpen: showProfileSwitcher,
            profileRowRequest: sidebarProfileRowRequest,
            sections: shellSections,
            content: { tab in contentViewController(for: tab) })
        .ignoresSafeArea()
        .onChange(of: selectedTab) { _, newTab in
            nestedNavState.isNested = false
        }
        .onChange(of: authManager.hasCredentials) { old, new in
            // Clear watchlist state on logout.
            if old && !new {
                PlexWatchlistService.shared.reset()
                deepLinkHandler.dropHeldLink()
            }
        }
        // A switch to another profile arrives at Home with the sidebar closed,
        // as the TV app's relaunch does. The launch restore (nil to saved) is not one.
        .onChange(of: profileManager.selectedUser?.id) { _, newId in
            guard let newId else { return }
            if let lastProfileId, lastProfileId != newId {
                selectedTab = .home
                sidebarCollapseRequest += 1
            }
            lastProfileId = newId
        }
        // The panel closed on the profile it opened on: back to the open sidebar.
        .onChange(of: showProfileSwitcher) { _, shown in
            if shown {
                switcherProfileId = profileManager.selectedUser?.id
            } else if switcherProfileId == profileManager.selectedUser?.id {
                sidebarProfileRowRequest += 1
            }
        }
        // Live TV and no media server: open on Live TV, since Home is hidden.
        .onChange(of: opensToLiveTV, initial: true) { _, liveOnly in
            guard liveOnly, !isLiveTVSelected, selectedTab != .settings else { return }
            selectedTab = .liveTV(sourceId: combineLiveTVSources ? nil : liveTVDataStore.sources.first?.id)
        }
        // Reset tab selection when live TV source mode changes
        .onChange(of: combineLiveTVSources) { _, combined in
            if case .liveTV = selectedTab {
                selectedTab = .liveTV(sourceId: combined ? nil : liveTVDataStore.sources.first?.id)
            }
        }
        // If the user disables the Discover tab while it's selected, bounce
        // back to Home so they're not stuck on a hidden tab.
        .onChange(of: showDiscoverTab) { _, shown in
            if !shown && selectedTab == .discover {
                selectedTab = .home
            }
        }
        .onChange(of: serverStore.visibleLibraries) { _, libraries in
            if case .providerLibrary(let providerID, let libraryID) = selectedTab,
               !libraries.contains(where: { $0.providerID == providerID && $0.id == libraryID }) {
                selectedTab = .home
            }
        }
        .onChange(of: showWatchlistTab) { _, shown in
            if !shown && selectedTab == .watchlist {
                selectedTab = .home
            }
        }
        // The toggle went off, or the server's last playlist went.
        .onChange(of: visiblePlaylistProviders) { _, providers in
            if case .playlists(let providerID) = selectedTab, !providers.contains(providerID) {
                selectedTab = .home
            }
        }
    }

    var body: some View {
        // Split from `shell`: the whole chain as one expression outran the
        // type checker on CI ("unable to type-check this expression").
        ZStack {
            if setupComplete {
                shell
            } else {
                // Start Watching fades the landing away over the home, which mounts under it at once.
                SetupLandingHost { withAnimation(.easeInOut(duration: 0.8)) { setupComplete = true } }
                    .ignoresSafeArea()
                    .zIndex(1)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    // Store the key, so connecting a source here can't flip the unset default.
                    .onAppear { setupComplete = false }
            }
        }
        .onChange(of: hasAnySource) { _, has in
            if !has { setupComplete = false }
        }
        .task(id: authManager.hasCredentials) {
            StartupTimer.mark("TVSidebar .task entry")
            guard authManager.hasCredentials else { return }

            // A saved profile with no stored token of its own: nothing may load
            // until plex.tv lets it in, so resolve it now instead of deferring.
            let wantsPicker = profileManager.showProfilePickerOnLaunch && !hasCheckedProfilePicker
            if wantsPicker || authManager.isContentWithheld {
                // Block content immediately; profile data must load before the picker shows
                isAwaitingProfileSelection = true
                deepLinkHandler.isShellReady = false
                await profileManager.fetchHomeUsers()
                hasCheckedProfilePicker = true

                if authManager.isContentWithheld {
                    // `needsProfileSelection` presents the picker; content loads after it.
                    return
                } else if wantsPicker && profileManager.hasMultipleProfiles {
                    // Stand the launch splash down so the picker is the top
                    // surface (otherwise it renders under the splash, which
                    // rides its 15s safety timeout because hubs, and thus
                    // isHomeContentReady, are deferred until after selection).
                    profileManager.isPresentingLaunchPicker = true
                    profileChosen = false
                    showProfilePicker = true
                    // Content will load after profile is selected
                    return
                } else {
                    isAwaitingProfileSelection = false
                    // No picker after all: What's New was deferred for it.
                    checkAndShowWhatsNew()
                }
            } else {
                // Home users are NOT needed to render the home screen (the saved
                // profile's own token is already installed); they feed the profile
                // switcher / settings and re-validate that profile. The plex.tv
                // /api/v2/home/users call can be slow (18s on device) and was
                // contending with the critical hub fetch for the network +
                // cooperative thread pool at launch, so defer it until after the
                // home content path has had its window.
                hasCheckedProfilePicker = true
                Task {
                    // 10s: the 3s defer landed this slow plex.tv call back
                    // inside the busy launch window. Nothing reads home users
                    // until the profile switcher/settings are opened.
                    try? await Task.sleep(for: .seconds(10))
                    await profileManager.fetchHomeUsers()
                }
            }

            // Past the profile gate: a deep link held since launch may open now.
            deepLinkHandler.isShellReady = true
            await loadLaunchContent()
        }
        .task {
            // Start background preloading of Live TV data (low priority)
            liveTVDataStore.startBackgroundPreload()
        }
        .onChange(of: deepLinkHandler.pendingPlayback) { _, metadata in
            guard let metadata else { return }
            deepLinkHandler.pendingPlayback = nil
            playForDeepLink(metadata)
        }
        // Handle detail deep links from Siri search results
        .onChange(of: deepLinkHandler.pendingDetail) { _, metadata in
            guard let metadata else { return }
            deepLinkHandler.pendingDetail = nil
            presentDetailForDeepLink(metadata)
        }
        .onChange(of: deepLinkHandler.pendingProviderLink) { _, link in
            guard let link else { return }
            deepLinkHandler.pendingProviderLink = nil
            presentReplacingStack { top in
                switch link.action {
                case .play: ProviderPlayer.play(link.item, fromBeginning: false, from: top, onDismiss: nil)
                case .detail: presentDetail(link.item, from: top)
                }
            }
        }
        // What's New: present the SAME UIKit glass changelog popup as
        // Settings → Changelog (not a separate SwiftUI dialog) for consistency.
        .onChange(of: showWhatsNew) { _, show in
            if show { presentWhatsNewPopup() }
        }
        .onAppear {
            MusicNowPlayingViewController.installPresenter()
            applyDebugLaunchTab()
            // Defer What's New check if profile picker needs to be shown first
            if authManager.isContentWithheld
                || (profileManager.showProfilePickerOnLaunch && authManager.selectedServerToken != nil) {
                return
            }
            checkAndShowWhatsNew()
        }
        // DEBUG: launch straight into a named library, e.g.
        // `xcrun simctl launch --setenv RIVULET_OPEN_LIBRARY="TV Shows" ...`
        .onChange(of: dataStore.libraries.count) { _, _ in applyDebugLaunchTab() }
        // Profile picker overlay (launch-time "Who's Watching")
        // What's New waits for the dismissal to finish: presented any sooner it
        // lands on the closing picker and leaves with it.
        .fullScreenCover(isPresented: $showProfilePicker, onDismiss: checkAndShowWhatsNew) {
            ProfilePickerOverlay(isPresented: $showProfilePicker, onSelected: { profileChosen = true })
        }
        .onChange(of: showProfilePicker) { _, isShowing in
            if !isShowing {
                // The picker is a hard gate: closed without a profile entered
                // (or with content still withheld), ask again.
                guard profileChosen, !profileManager.needsProfileSelection else {
                    showProfilePicker = true
                    return
                }
                profileChosen = false
                // Profile selected, unblock content
                isAwaitingProfileSelection = false
                profileManager.isPresentingLaunchPicker = false
                deepLinkHandler.isShellReady = true

                // Load content if not already loaded (profile switch handles its own reload)
                if dataStore.hubs.isEmpty {
                    Task { await loadLaunchContent() }
                }
            }
        }
        // Content is withheld until a profile is entered: ask who is watching.
        .onChange(of: profileManager.needsProfileSelection) { _, needed in
            if needed {
                isAwaitingProfileSelection = true
                deepLinkHandler.isShellReady = false
                profileManager.isPresentingLaunchPicker = true
                // The picker cannot present over a player, and nothing may keep playing.
                MusicQueue.shared.stop()
                MusicQueue.shared.clear()
                // The Home screen row is the locked profile's too.
                TopShelfCache.shared.clear()
                Self.rootViewController()?.dismiss(animated: false)
            }
            // Withheld content only clears when a profile is entered.
            profileChosen = !needed
            showProfilePicker = needed
        }
        // Compact profile switcher popup (from sidebar account tab)
        .fullScreenCover(isPresented: $showProfileSwitcher) {
            ProfileSwitcherPopup(
                isPresented: $showProfileSwitcher,
                profileManager: profileManager
            )
            .presentationBackground(.clear)
        }
    }

    // MARK: - Launch Content

    /// Everything the shell loads once a content token is installed: at launch,
    /// or after the launch profile picker when content waited for it.
    private func loadLaunchContent() async {
        // CRITICAL PATH: Only hubs needed for home screen to render
        StartupTimer.mark("TVSidebar → loadHubsIfNeeded")
        await dataStore.loadHubsIfNeeded()
        StartupTimer.mark("TVSidebar loadHubsIfNeeded returned")

        // Kick off watchlist fetch — DEFERRED so it doesn't contend with
        // the home's cache decode + first paint at launch (the watchlist
        // row fills in a couple seconds later).
        Task {
            try? await Task.sleep(for: .seconds(2))
            await PlexWatchlistService.shared.fetchWatchlist()
        }

        // Hydrate the GUID index from last launch's snapshot (a few ms) so
        // ownership answers are ready at first paint; the network rebuild
        // below supersedes it.
        Task.detached(priority: .userInitiated) {
            _ = await LibraryGUIDIndex.shared.hydrateFromDisk()
        }

        // BACKGROUND: Libraries -> library hubs -> prefetch (chained, not blocking home).
        // Delayed so the big per-library hub decodes (316KB/550KB payloads)
        // don't saturate the cores during the home's first paint.
        Task {
            try? await Task.sleep(for: .seconds(2))
            await dataStore.loadLibrariesIfNeeded()
            await dataStore.loadLibraryHubsIfNeeded()
            dataStore.startBackgroundPrefetch(libraries: dataStore.visibleMediaLibraries)

            // Rebuild the GUID index ("do I own this?") with includeGuids, which
            // Plex omits by default. Deferred 5s: each 5000-movie page is ~12MB, so
            // each page is cut to index entries before the next one arrives (#409).
            Task.detached(priority: .background) {
                try? await Task.sleep(for: .seconds(5))
                let (serverURL, token) = await MainActor.run {
                    (PlexAuthManager.shared.selectedServerURL, PlexAuthManager.shared.selectedServerToken)
                }
                guard let serverURL, let token else { return }
                guard await LibraryGUIDIndex.shared.claimRebuild() else { return }
                defer { Task { await LibraryGUIDIndex.shared.finishRebuild() } }

                let visible = await MainActor.run { PlexDataStore.shared.visibleVideoLibraries }

                // One 1-item probe per section (about 3 KB); an unchanged library skips the
                // full refetch, about 130 MB at 56k items.
                var stamps: [String: String] = [:]
                for library in visible {
                    if let probe = try? await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                        serverURL: serverURL, authToken: token, sectionId: library.key,
                        start: 0, size: 1, sort: "updatedAt:desc"
                    ), let stamp = LibraryGUIDIndex.sectionStamp(totalSize: probe.totalSize, newest: probe.items.first) {
                        stamps[library.key] = stamp
                    }
                }
                if stamps.count == visible.count, await LibraryGUIDIndex.shared.isCurrent(for: stamps) {
                    libraryIndexLog.info("[GUIDIndex] unchanged since last build, skipping rebuild")
                    return
                }

                var allItems: [LibraryGUIDIndex.Entry] = []
                var fetchedCount = 0
                // Per section: one that failed mid-way still contributes a
                // plausible count, and the totals would hide it.
                var incompleteSections = 0
                let pageSize = 5000
                for library in visible {
                    // Page through the whole section (#202).
                    var start = 0
                    var sectionComplete = false
                    while true {
                        // Not alongside playback: a 4K software decode needs the headroom (#409).
                        while await MainActor.run(body: { PlexDataStore.shared.isPlaybackActive }) {
                            try? await Task.sleep(for: .seconds(10))
                        }
                        do {
                            let result = try await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                                serverURL: serverURL,
                                authToken: token,
                                sectionId: library.key,
                                start: start,
                                size: pageSize,
                                includeGuids: true
                            )
                            allItems += result.items.compactMap { LibraryGUIDIndex.Entry($0, sectionID: library.key) }
                            fetchedCount += result.items.count
                            start += result.items.count
                            // An empty page or reaching the reported total is the
                            // only way out that means we actually saw the section
                            // in full. Anything else leaves sectionComplete false.
                            if result.items.isEmpty || start >= (result.totalSize ?? 0) {
                                sectionComplete = true
                                break
                            }
                        } catch {
                            // The break abandons every remaining page of this
                            // section, so the section is partial from here on.
                            libraryIndexLog.error("[GUIDIndex] fetch failed for section \(library.key, privacy: .public) at offset \(start): \(error.localizedDescription, privacy: .public)")
                            let crumb = Breadcrumb(level: .error, category: "guid_index")
                            crumb.message = "Library GUID fetch failed"
                            crumb.data = ["section": library.key, "offset": start, "error": error.localizedDescription]
                            SentryBridge.addBreadcrumb(crumb)
                            break
                        }
                    }
                    if !sectionComplete { incompleteSections += 1 }
                }

                // Only a build where every visible section ran to completion may
                // overwrite the disk cache. See LibraryGUIDIndex.Completeness.
                let completeness: LibraryGUIDIndex.Completeness =
                    incompleteSections == 0 ? .complete : .partial

                let sample = allItems.first?.guids.first ?? "(none)"
                libraryIndexLog.info("[GUIDIndex] populated: \(fetchedCount) items total, \(allItems.count) with external GUIDs, \(incompleteSections) incomplete sections, sample=\(sample, privacy: .public)")

                let crumb = Breadcrumb(level: .info, category: "guid_index")
                crumb.message = "Library GUID index rebuilt"
                crumb.data = [
                    "libraries": visible.count,
                    "failed_sections": incompleteSections,
                    "items": fetchedCount,
                    "with_guids": allItems.count
                ]
                SentryBridge.addBreadcrumb(crumb)

                // No Sentry event for an incomplete build: PlexNetworkManager
                // already captures each transport failure.

                // An empty result with at least one section incomplete means we
                // learned nothing from the server, so keep whatever the disk
                // hydrate gave us rather than blanking a working index.
                if fetchedCount == 0 && completeness == .partial { return }
                // The token changed hands while this ran: not that profile's library.
                guard await MainActor.run(body: { PlexAuthManager.shared.selectedServerToken }) == token else { return }
                await LibraryGUIDIndex.shared.replace(
                    with: allItems, completeness: completeness,
                    stamps: completeness == .complete && stamps.count == visible.count ? stamps : [:]
                )
            }
        }
    }

    // MARK: - Tab Content

    /// Builds one tab's content view controller for the UIKit shell. UIKit
    /// surfaces mount directly: a hosting controller is not focusable in its
    /// first runloop turn (#280) and is rebuilt on every update of this view.
    private func contentViewController(for tab: SidebarTab) -> UIViewController {
        switch tab {
        case .discover:
            return PlexHomeViewController(mode: .discover)
        case .watchlist:
            return PlexHomeViewController(mode: .watchlist)
        case .playlists(let providerID):
            return PlexHomeViewController(mode: .playlists(providerID: providerID))
        case .search:
            let search = SearchContainerViewController()
            search.onNestedChange = { [nestedNavState] isNested in
                nestedNavState.isNested = isNested
            }
            return search
        case .library(let key):
            // The shell caches per `SidebarTab`, so each library key gets its
            // own controller.
            if let lib = dataStore.libraries.first(where: { $0.key == key }) {
                if lib.hasNoMetadataAgent { return FolderLibraryViewController(plex: lib) }
                if lib.isVideoLibrary { return PlexLibraryModeViewController(library: lib) }
                if lib.isPhotoLibrary {
                    return PhotoLibraryViewController(title: lib.title) {
                        guard let provider = MediaProviderRegistry.shared.plexProvider,
                              let photos = provider as? any PhotoProvider else { return nil }
                        return (photos, PlexMediaMapper.library(lib, providerID: provider.id))
                    }
                }
                return lib.isMusicLibrary
                    ? MusicLibraryViewController(libraryKey: lib.key, title: lib.title)
                    : PlexHomeViewController(mode: .library(key: lib.key, title: lib.title))
            }
        case .providerLibrary(let providerID, let libraryID):
            // The same page as a Plex library, through the provider.
            if let library = serverStore.libraries.first(where: { $0.providerID == providerID && $0.id == libraryID }) {
                if library.browsesByFolder {
                    return FolderLibraryViewController(title: library.title) {
                        (MediaProviderRegistry.shared.provider(for: library.providerID) as? any FolderProvider)
                            .map { ($0, library) }
                    }
                }
                if library.kind == .photos {
                    return PhotoLibraryViewController(title: library.title) {
                        (MediaProviderRegistry.shared.provider(for: library.providerID) as? any PhotoProvider)
                            .map { ($0, library) }
                    }
                }
                if library.kind == .music {
                    return MusicLibraryViewController(libraryKey: library.id, title: library.title,
                                                      providerID: library.providerID)
                }
                return PlexHomeViewController(mode: .library(key: library.settingsKey, title: library.title),
                                              providerLibrary: library)
            }
        default:
            break
        }
        return RootShellHostingController(rootView: AnyView(tabContent(for: tab)))
    }

    /// Settings tab content (`SettingsContainerViewController`).
    @ViewBuilder
    private var settingsTabContent: some View {
        UIKitSettingsContainer()
    }

    @ViewBuilder
    private func tabContent(for tab: SidebarTab) -> some View {
        // Gates are overlays, never if/else branches: a branch changes the
        // content's SwiftUI identity and rebuilds or orphans the UIKit home.
        Group {
            switch tab {
            case .account:
                Color.clear
            case .search:
                // Unreachable: `contentViewController(for:)` mounts
                // SearchContainerViewController directly. Kept so this switch
                // stays exhaustive over SidebarTab.
                Color.clear
            case .home:
                PlexHomeRoot()
            case .providerLibrary:
                // Unreachable: mounted directly as a UIKit VC above. Kept so
                // this switch stays exhaustive over SidebarTab.
                Color.clear
            case .watchlist, .playlists:
                // Unreachable: mounted directly as a UIKit VC above. Kept so
                // this switch stays exhaustive over SidebarTab.
                Color.clear
            case .discover:
                // UIKit Discover: same hero + shelf surface as the home,
                // TMDB-fed (HomeMode.discover). (The retired SwiftUI
                // DiscoverView was removed — see git history.)
                UIKitHomeContainer(mode: .discover)
            case .library(let key):
                // Both library surfaces mount directly as UIKit VCs above. This
                // is left for a tab built before the library list held its key.
                if let lib = dataStore.libraries.first(where: { $0.key == key }), lib.isVideoLibrary {
                    UIKitHomeContainer(mode: .library(key: lib.key, title: lib.title))
                        .id(lib.key)
                }
            case .liveTV(let sourceId):
                LiveTVContainerView(sourceIdFilter: sourceId)
            case .settings:
                settingsTabContent
            }
        }
        .overlay {
            if isAwaitingProfileSelection {
                Color.black.ignoresSafeArea()
            }
        }
        .focusScope(contentNamespace)
        .environment(\.nestedNavigationState, nestedNavState)
    }

    /// DEBUG: jump straight to a library named by the RIVULET_OPEN_LIBRARY env
    /// var once libraries have loaded, so sim iteration skips the sidebar nav.
    private func applyDebugLaunchTab() {
        guard !didApplyDebugLaunch,
              let name = ProcessInfo.processInfo.environment["RIVULET_OPEN_LIBRARY"],
              let lib = dataStore.visibleSidebarLibraries.first(where: { $0.title == name }) else { return }
        didApplyDebugLaunch = true
        selectedTab = .library(key: lib.key)
        #if DEBUG
        MusicPresenter.debugOpenIfRequested()
        #endif
    }

    /// Present the canonical UIKit changelog popup (same one Settings uses) for
    /// the fresh-launch "What's New", instead of a bespoke SwiftUI dialog.
    private func presentWhatsNewPopup() {
        guard let top = Self.topPresentedViewController() else { showWhatsNew = false; return }
        let popup = SettingsContent.makeChangelogPopup()
        popup.onDismiss = { showWhatsNew = false }
        top.present(popup, animated: true)
    }

    private static func rootViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return nil }
        return window.rootViewController
    }

    private static func topPresentedViewController() -> UIViewController? {
        guard var top = rootViewController() else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    // MARK: - Deep Link Detail

    /// Present detail for a `rivulet://detail` deep link (Top Shelf / Siri).
    /// Routes exactly like the home tile menu's `selectMediaItem`: episodes and
    /// seasons get the title-first detail page, everything else the standalone
    /// expanded detail. Both are the UIKit surfaces normal in-app navigation uses.
    private func presentDetailForDeepLink(_ metadata: PlexMetadata) {
        guard let item = deepLinkItem(metadata) else { return }
        presentReplacingStack { top in
            presentDetail(item, from: top)
        }
    }

    private func deepLinkItem(_ metadata: PlexMetadata) -> MediaItem? {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        let providerID = MediaProviderRegistry.shared.plexProvider?.id ?? "plex:\(serverURL)"
        return PlexMediaMapper.item(metadata, providerID: providerID, serverURL: serverURL, authToken: token)
    }

    /// A deep link replaces whatever is presented: stacking it would leave a
    /// player running underneath.
    private func presentReplacingStack(_ present: @escaping (UIViewController) -> Void) {
        // A profile prompt came up while the link was resolving: it owns the screen.
        guard deepLinkHandler.isShellReady else { return }
        guard let root = Self.rootViewController() else { return }
        showProfileSwitcher = false
        guard root.presentedViewController != nil else { return present(root) }
        root.dismiss(animated: false) { present(root) }
    }

    /// Play for a `rivulet://play` link. A show or a season resolves to the
    /// episode its own Play button means; with none to play, its detail opens.
    private func playForDeepLink(_ metadata: PlexMetadata) {
        guard let item = deepLinkItem(metadata), item.kind == .show || item.kind == .season,
              let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            presentPlayerForDeepLink(metadata)
            return
        }
        Task { @MainActor in
            if let episode = await EpisodePicker.resolvePlayTarget(for: item, provider: provider) {
                playDeepLinkItem(episode)
            } else {
                presentDetailForDeepLink(metadata)
            }
        }
    }

    private func presentDetail(_ item: MediaItem, from top: UIViewController) {
        if item.kind == .season {
            top.present(SeasonDetailViewController(season: item), animated: true)
        } else if item.kind == .episode {
            let page = MediaItemDetailPageViewController(
                item: item,
                seriesTitle: nil,
                onPlay: { episode, sourceID in
                    // Close the page first so the player isn't presented
                    // underneath it, then resolve full metadata to play.
                    top.dismiss(animated: true) {
                        playDeepLinkItem(episode, sourceID: sourceID)
                    }
                })
            top.present(page, animated: true)
        } else {
            let detail = PreviewCarouselViewController(
                items: [item],
                selectedIndex: 0,
                sourceFrame: .zero,
                sourceTarget: nil,
                standaloneDetail: true,
                onDismiss: { _ in })
            top.present(detail, animated: true)
        }
    }

    /// Play a MediaItem surfaced by the detail page: resolve full metadata by
    /// ratingKey (MediaItem carries no PlexMetadata), then hand to the player.
    private func playDeepLinkItem(_ item: MediaItem, sourceID: String? = nil) {
        if !item.ref.isPlex {
            guard let top = Self.topPresentedViewController() else { return }
            ProviderPlayer.play(item, fromBeginning: false, sourceID: sourceID, from: top, onDismiss: nil)
            return
        }
        let ratingKey = item.ref.itemID
        guard !ratingKey.isEmpty,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        Task { @MainActor in
            guard let meta = try? await PlexNetworkManager.shared.getFullMetadata(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            ) else { return }
            presentPlayerForDeepLink(meta, mediaID: sourceID)
        }
    }

    // MARK: - Deep Link Player

    /// Present player for a deep link from Top Shelf
    private func presentPlayerForDeepLink(_ metadata: PlexMetadata, mediaID: String? = nil) {
        Task {
            let (artImage, thumbImage) = await getPlayerImages(for: metadata)

            await MainActor.run {
                let viewModel = UniversalPlayerViewModel(
                    metadata: metadata,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? "",
                    startOffset: metadata.viewOffset.map { Double($0) / 1000.0 },
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage,
                    preferredMediaID: mediaID
                )
                presentReplacingStack { rootVC in
                    PlayerPresenter.present(viewModel: viewModel, from: rootVC)
                }
            }
        }
    }

    /// Get art and poster images for the player loading screen (from cache or fetch)
    private func getPlayerImages(for metadata: PlexMetadata) async -> (UIImage?, UIImage?) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return (nil, nil) }

        let request = metadata.heroBackdropRequest(
            serverURL: serverURL,
            authToken: token
        )
        return await HeroBackdropResolver.shared.playerLoadingImages(for: request)
    }

    // MARK: - What's New

    private func checkAndShowWhatsNew() {
        guard !isAwaitingProfileSelection else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let current = "\(version) (\(build))"

        if current != lastSeenBuild {
            // A new install sets up instead; What's New is for updates.
            if setupComplete, WhatsNewView.features(for: current) != nil {
                showWhatsNew = true
            }
            lastSeenBuild = current
        }
    }
}

/// The setup landing, standing in for the shell until the user finishes it.
private struct SetupLandingHost: UIViewControllerRepresentable {
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> SetupLandingViewController {
        let vc = SetupLandingViewController()
        vc.onDone = onDone
        return vc
    }
    func updateUIViewController(_ vc: SetupLandingViewController, context: Context) {}
}
