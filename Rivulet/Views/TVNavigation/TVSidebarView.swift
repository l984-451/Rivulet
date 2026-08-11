// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TVSidebarView.swift
//  Rivulet
//
//  Main tvOS navigation using system TabView with sidebarAdaptable style
//

import SwiftUI
import os.log
import Sentry

// Temporary diagnostic logger for intermittent sidebar focus loss.
private let libraryIndexLog = Logger(subsystem: "com.rivulet.app", category: "LibraryIndex")

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
    @StateObject private var profileManager = PlexUserProfileManager.shared
    @StateObject private var nestedNavState = NestedNavigationState()
    @StateObject private var deepLinkHandler = DeepLinkHandler.shared
    @StateObject private var musicQueue = MusicQueue.shared
    @AppStorage("combineLiveTVSources") private var combineLiveTVSources = true
    @AppStorage("liveTVAboveLibraries") private var liveTVAboveLibraries = false
    @AppStorage("showDiscoverTab") private var showDiscoverTab = true
    @AppStorage("discoverAboveLibraries") private var discoverAboveLibraries = true
    @AppStorage("displaySize") private var displaySizeRaw = DisplaySize.normal.rawValue
    @State private var selectedTab: SidebarTab = .home
    @State private var showProfilePicker = false
    @State private var showProfileSwitcher = false
    @State private var hasCheckedProfilePicker = false
    @State private var isAwaitingProfileSelection = false
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    @State private var showWhatsNew = false
    @State private var didApplyDebugLaunch = false
    @State private var musicLibraryEntryToken = UUID()

    @Namespace private var contentNamespace

    private var uiScale: CGFloat {
        (DisplaySize(rawValue: displaySizeRaw) ?? .normal).scale
    }

    private var profileName: String {
        profileManager.selectedUser?.displayName ?? authManager.username ?? "Account"
    }

    private var isMusicLibrarySelected: Bool {
        guard case .library(let key) = selectedTab else { return false }
        return dataStore.libraries.first(where: { $0.key == key })?.isMusicLibrary ?? false
    }

    /// The sidebar's content, built from LIVE values: this view observes all
    /// the feeding stores, so any change re-renders and pushes fresh sections
    /// into the shell. The old snapshot dance existed only because the system
    /// sidebar wedged on live mutation; ours does not.
    private var shellSections: [ShellSidebarSection] {
        ShellSidebarModel.sections(
            libraries: dataStore.visibleMediaLibraries,
            liveTVSources: liveTVDataStore.sources,
            combineLiveTV: combineLiveTVSources,
            showDiscover: showDiscoverTab,
            discoverAbove: discoverAboveLibraries,
            liveTVAbove: liveTVAboveLibraries,
            serverName: authManager.savedServerName,
            profileName: profileName)
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

    var body: some View {
        // The UIKit shell replaces the TabView(.sidebarAdaptable). Menu-to-Home
        // (issue #192), the sidebar focus guard, and the focus watchdog were
        // all workarounds for the system sidebar and live on inside the shell
        // (or died with the TabView).
        RootShellHost(
            selection: tabSelection,
            interactionBlocked: nestedNavState.isNested || nestedNavState.isSettingsSubPage,
            pillSuppressed: isMusicLibrarySelected,
            sections: shellSections,
            content: { tab in contentViewController(for: tab) })
        .ignoresSafeArea()
        .onChange(of: selectedTab) { _, newTab in
            nestedNavState.isNested = false
            if isMusicLibraryTab(newTab) {
                musicLibraryEntryToken = UUID()
            }
        }
        .onChange(of: authManager.hasCredentials) { old, new in
            // Clear watchlist state on logout.
            if old && !new {
                PlexWatchlistService.shared.reset()
            }
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
        .task(id: authManager.hasCredentials) {
            StartupTimer.mark("TVSidebar .task entry")
            guard authManager.selectedServerToken != nil else { return }

            // If profile picker on launch is enabled, block content immediately
            if profileManager.showProfilePickerOnLaunch && !hasCheckedProfilePicker {
                isAwaitingProfileSelection = true
            }

            if profileManager.showProfilePickerOnLaunch && !hasCheckedProfilePicker {
                // Must await profile data before showing picker
                await profileManager.fetchHomeUsers()
                hasCheckedProfilePicker = true

                if profileManager.hasMultipleProfiles {
                    // Stand the launch splash down so the picker is the top
                    // surface (otherwise it renders under the splash, which
                    // rides its 15s safety timeout because hubs — and thus
                    // isHomeContentReady — are deferred until after selection).
                    profileManager.isPresentingLaunchPicker = true
                    showProfilePicker = true
                    // Content will load after profile is selected
                    return
                } else {
                    isAwaitingProfileSelection = false
                }
            } else {
                // Home users are NOT needed to render the home screen (single-user
                // content uses the main auth token); they only feed the profile
                // switcher / settings. The plex.tv /api/v2/home/users call can be
                // slow (18s on device) and was contending with the critical hub
                // fetch for the network + cooperative thread pool at launch — so
                // defer it until after the home content path has had its window.
                hasCheckedProfilePicker = true
                Task {
                    // 10s: the 3s defer landed this slow plex.tv call back
                    // inside the busy launch window. Nothing reads home users
                    // until the profile switcher/settings are opened.
                    try? await Task.sleep(for: .seconds(10))
                    await profileManager.fetchHomeUsers()
                }
            }

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

            // IMMEDIATE: hydrate the library GUID index from last launch's
            // persisted snapshot. Local decode (a few ms), so it runs with no
            // defer — this makes "do I own this?" answers (and the trending
            // hero upgrade) available right after the home paints, instead of
            // waiting ~20s for the network rebuild below. A fresh network
            // rebuild always supersedes this (see LibraryGUIDIndex.hasFreshData).
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
                dataStore.startBackgroundPrefetch(libraries: dataStore.visibleVideoLibraries)

                // Rebuild the library GUID index in the background. Used by Discover and
                // Watchlist surfaces to answer "do I own this?" in O(1). The index
                // matches by external GUID, so the fetch must include them
                // (Plex omits them from the default summary response).
                //
                // DEFERRED 5s past launch: this fetches ~5MB per page
                // (5000 items + includeGuids, paginated) — so it must stay
                // clear of the home's first-paint window. It no longer gates the
                // trending hero or "in your library" badges: hydrateFromDisk()
                // above serves last launch's snapshot in ms. This fetch refreshes
                // that snapshot from the server, and replace(with:) re-posts
                // .libraryGUIDIndexDidUpdate so the hero picks up any new data.
                Task.detached(priority: .background) {
                    try? await Task.sleep(for: .seconds(5))
                    let (serverURL, token) = await MainActor.run {
                        (PlexAuthManager.shared.selectedServerURL, PlexAuthManager.shared.selectedServerToken)
                    }
                    guard let serverURL, let token else { return }

                    let visible = await MainActor.run { PlexDataStore.shared.visibleVideoLibraries }

                    var allItems: [PlexMetadata] = []
                    // Completeness is tracked per section, not as a single global
                    // flag, because the two ways a build goes wrong look identical
                    // in aggregate: a section that threw on its very first page
                    // contributes nothing, and a section that threw at offset 5000
                    // of 12000 contributes a plausible-looking 5000 items. Both are
                    // incomplete, and the second one is the dangerous case, since
                    // the totals alone give no hint that anything is missing.
                    var incompleteSections = 0
                    let pageSize = 5000
                    for library in visible {
                        // Page through the whole section — libraries larger than one
                        // page used to be truncated, silently dropping ownership
                        // matches for everything past the first 5000 titles (#202).
                        var start = 0
                        var sectionComplete = false
                        while true {
                            do {
                                let result = try await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                                    serverURL: serverURL,
                                    authToken: token,
                                    sectionId: library.key,
                                    start: start,
                                    size: pageSize,
                                    includeGuids: true
                                )
                                allItems.append(contentsOf: result.items)
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

                    let withGuids = allItems.filter { ($0.Guid ?? []).isEmpty == false }
                    let sample = withGuids.first.flatMap { $0.Guid?.first?.id } ?? "(none)"
                    libraryIndexLog.info("[GUIDIndex] populated: \(allItems.count) items total, \(withGuids.count) with external GUIDs, \(incompleteSections) incomplete sections, sample=\(sample, privacy: .public)")

                    let crumb = Breadcrumb(level: .info, category: "guid_index")
                    crumb.message = "Library GUID index rebuilt"
                    crumb.data = [
                        "libraries": visible.count,
                        "failed_sections": incompleteSections,
                        "items": allItems.count,
                        "with_guids": withGuids.count
                    ]
                    SentryBridge.addBreadcrumb(crumb)

                    // No standalone Sentry event for an incomplete build. The
                    // underlying cause is the user's own Plex server going
                    // unreachable, and PlexNetworkManager already captures each
                    // transport failure with its endpoint, elapsed time and error
                    // code. An event here only duplicated that, once per launch, for
                    // users whose whole server was down. The breadcrumb above keeps
                    // the context on any real downstream error at no cost.

                    // An empty result with at least one section incomplete means we
                    // learned nothing from the server, so keep whatever the disk
                    // hydrate gave us rather than blanking a working index.
                    if allItems.isEmpty && completeness == .partial { return }
                    await LibraryGUIDIndex.shared.replace(with: allItems, completeness: completeness)
                }
            }
        }
        .task {
            // Start background preloading of Live TV data (low priority)
            liveTVDataStore.startBackgroundPreload()
        }
        .onChange(of: deepLinkHandler.pendingPlayback) { _, metadata in
            guard let metadata else { return }
            presentPlayerForDeepLink(metadata)
            deepLinkHandler.pendingPlayback = nil
        }
        // Handle detail deep links from Siri search results
        .onChange(of: deepLinkHandler.pendingDetail) { _, metadata in
            guard let metadata else { return }
            deepLinkHandler.pendingDetail = nil
            presentDetailForDeepLink(metadata)
        }
        // What's New: present the SAME UIKit glass changelog popup as
        // Settings → Changelog (not a separate SwiftUI dialog) for consistency.
        .onChange(of: showWhatsNew) { _, show in
            if show { presentWhatsNewPopup() }
        }
        .onAppear {
            applyDebugLaunchTab()
            // Defer What's New check if profile picker needs to be shown first
            if profileManager.showProfilePickerOnLaunch && authManager.selectedServerToken != nil {
                return
            }
            checkAndShowWhatsNew()
        }
        // DEBUG: launch straight into a named library, e.g.
        // `xcrun simctl launch --setenv RIVULET_OPEN_LIBRARY="TV Shows" ...`
        .onChange(of: dataStore.libraries.count) { _, _ in applyDebugLaunchTab() }
        // Profile picker overlay (launch-time "Who's Watching")
        .fullScreenCover(isPresented: $showProfilePicker) {
            ProfilePickerOverlay(isPresented: $showProfilePicker)
        }
        .onChange(of: showProfilePicker) { _, isShowing in
            if !isShowing {
                // Profile selected, unblock content
                isAwaitingProfileSelection = false
                profileManager.isPresentingLaunchPicker = false

                // Load content if not already loaded (profile switch handles its own reload)
                Task {
                    if dataStore.hubs.isEmpty {
                        // CRITICAL PATH: Only hubs needed for home screen to render
                        await dataStore.loadHubsIfNeeded()

                        // BACKGROUND: Libraries -> library hubs -> prefetch
                        Task {
                            await dataStore.loadLibrariesIfNeeded()
                            await dataStore.loadLibraryHubsIfNeeded()
                            dataStore.startBackgroundPrefetch(libraries: dataStore.visibleVideoLibraries)
                        }
                    }
                }

                // Now show What's New if applicable (was deferred for profile picker)
                checkAndShowWhatsNew()
            }
        }
        // Compact profile switcher popup (from sidebar account tab)
        .fullScreenCover(isPresented: $showProfileSwitcher) {
            ProfileSwitcherPopup(
                isPresented: $showProfileSwitcher,
                profileManager: profileManager
            )
            .presentationBackground(.clear)
        }
        // Music Now Playing overlay
        .fullScreenCover(isPresented: $musicQueue.showNowPlaying) {
            MusicNowPlayingView(isPresented: $musicQueue.showNowPlaying)
                .presentationBackground(.black)
        }
    }

    // MARK: - Tab Content

    /// Builds one tab's content view controller for the UIKit shell.
    ///
    /// A surface that is ALREADY UIKit mounts directly, with no
    /// `UIHostingController` in between. That sandwich is not free: a hosting
    /// controller is not focusable in the runloop turn it mounts in, which is
    /// the whole reason `RootShellViewController.driveFocusIntoContent` has to
    /// retry at all (issue #280), and every hosted tab's root is rebuilt on
    /// every SwiftUI update of this view.
    ///
    /// Still hosted, and correctly so: Music and Live TV are genuinely
    /// SwiftUI, and Home carries the welcome / profile-gate overlays.
    private func contentViewController(for tab: SidebarTab) -> UIViewController {
        switch tab {
        case .discover:
            return PlexHomeViewController(mode: .discover)
        case .search:
            let search = SearchContainerViewController()
            search.onNestedChange = { [nestedNavState] isNested in
                nestedNavState.isNested = isNested
            }
            return search
        case .library(let key):
            // The shell caches per `SidebarTab`, so each library key already
            // gets its own controller — this is what the SwiftUI `.id(key)`
            // was buying. Music libraries render MusicHomeView, so they fall
            // through to hosting.
            if let lib = dataStore.libraries.first(where: { $0.key == key }), !lib.isMusicLibrary {
                return PlexHomeViewController(mode: .library(key: lib.key, title: lib.title))
            }
        default:
            break
        }
        return RootShellHostingController(rootView: AnyView(tabContent(for: tab)))
    }

    /// Settings tab content. The Settings surface is pure UIKit
    /// (`UIKitSettingsContainer` → `SettingsContainerViewController`); the old
    /// SwiftUI `SettingsView` has been retired.
    @ViewBuilder
    private var settingsTabContent: some View {
        UIKitSettingsContainer()
    }

    @ViewBuilder
    private func tabContent(for tab: SidebarTab) -> some View {
        // The profile gate is an OVERLAY, not a structural branch. The old
        // `if isAwaitingProfileSelection { Color.clear } else { content }`
        // swapped the whole tree when the flag flipped, changing the
        // content's SwiftUI identity — which discarded and REBUILT the UIKit
        // home (two live home VCs through the entire launch window). An
        // overlay conceals without touching identity. (Focus isolation while
        // the gate is up comes from the profile picker's own presentation.)
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
                // PlexHomeRoot is ALWAYS rendered (never an if/else branch) so
                // its SwiftUI identity — and the singleton UIKit home VC it
                // hosts — stays stable across the `hasCredentials` false→true
                // flip on sign-in. The old `if hasCredentials { PlexHomeRoot }
                // else { welcomeView }` swapped the tree on sign-in, which made
                // SwiftUI tear the home VC out of the hierarchy (willMove(to:
                // nil) → window=nil, orphaned) and never re-host it: blank,
                // unfocusable Home + watchdog loop. This is the SAME structural-
                // branch anti-pattern the profile gate (below) already fixed by
                // becoming an overlay. The welcome screen is now an opaque
                // overlay; the home behind is `.disabled` so focus lands on the
                // welcome button, not a hidden home element.
                PlexHomeRoot()
                    .disabled(!authManager.hasCredentials)
                    .overlay {
                        if !authManager.hasCredentials {
                            welcomeView
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black)
                        }
                    }
            case .discover:
                // UIKit Discover: same hero + shelf surface as the home,
                // TMDB-fed (HomeMode.discover). (The retired SwiftUI
                // DiscoverView was removed — see git history.)
                UIKitHomeContainer(mode: .discover)
            case .library(let key):
                if let lib = dataStore.libraries.first(where: { $0.key == key }) {
                    if lib.isMusicLibrary {
                            MusicHomeView(libraryKey: lib.key, libraryTitle: lib.title)
                                .id("\(lib.key)-\(musicLibraryEntryToken.uuidString)")
                    } else {
                        // Library page = the home VC in .library mode (one
                        // implementation, two surfaces). `.id` rebuilds the
                        // controller when switching libraries.
                        UIKitHomeContainer(mode: .library(key: lib.key, title: lib.title))
                            .id(lib.key)
                    }
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
        .environment(\.uiScale, uiScale)
    }

    // MARK: - Welcome View

    private var welcomeView: some View {
        VStack(spacing: 28) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.3))

            VStack(spacing: 12) {
                Text("Welcome to Rivulet")
                    .font(.system(size: 46, weight: .semibold))

                Text("Connect your Plex server in Settings to get started.")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            Button {
                selectedTab = .settings
            } label: {
                Text("Open Settings")
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.card)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// DEBUG: jump straight to a library named by the RIVULET_OPEN_LIBRARY env
    /// var once libraries have loaded, so sim iteration skips the sidebar nav.
    private func applyDebugLaunchTab() {
        guard !didApplyDebugLaunch,
              let name = ProcessInfo.processInfo.environment["RIVULET_OPEN_LIBRARY"],
              let lib = dataStore.visibleMediaLibraries.first(where: { $0.title == name }) else { return }
        didApplyDebugLaunch = true
        selectedTab = .library(key: lib.key)
    }

    private func isMusicLibraryTab(_ tab: SidebarTab) -> Bool {
        guard case .library(let key) = tab else { return false }
        return dataStore.libraries.first(where: { $0.key == key })?.isMusicLibrary ?? false
    }

    /// Present the canonical UIKit changelog popup (same one Settings uses) for
    /// the fresh-launch "What's New", instead of a bespoke SwiftUI dialog.
    private func presentWhatsNewPopup() {
        guard let top = Self.topPresentedViewController() else { showWhatsNew = false; return }
        let popup = SettingsContent.makeChangelogPopup()
        popup.onDismiss = { showWhatsNew = false }
        top.present(popup, animated: true)
    }

    private static func topPresentedViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    // MARK: - Deep Link Detail

    /// Present detail for a `rivulet://detail` deep link (Top Shelf / Siri).
    /// Routes exactly like the home tile menu's `selectMediaItem`: episodes
    /// get the episode detail page, everything else the standalone expanded
    /// detail. Both are the UIKit surfaces normal in-app navigation uses.
    private func presentDetailForDeepLink(_ metadata: PlexMetadata) {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let top = Self.topPresentedViewController() else { return }
        let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
        let item = PlexMediaMapper.item(metadata, providerID: providerID, serverURL: serverURL, authToken: token)

        if item.kind == .episode {
            let page = MediaItemDetailPageViewController(
                item: item,
                seriesTitle: nil,
                onPlay: { episode in
                    // Close the page first so the player isn't presented
                    // underneath it, then resolve full metadata to play.
                    top.dismiss(animated: true) {
                        playDeepLinkItem(episode)
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
    private func playDeepLinkItem(_ item: MediaItem) {
        let ratingKey = item.ref.itemID
        guard !ratingKey.isEmpty,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        Task { @MainActor in
            guard let meta = try? await PlexNetworkManager.shared.getFullMetadata(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            ) else { return }
            presentPlayerForDeepLink(meta)
        }
    }

    // MARK: - Deep Link Player

    /// Present player for a deep link from Top Shelf
    private func presentPlayerForDeepLink(_ metadata: PlexMetadata) {
        Task {
            let (artImage, thumbImage) = await getPlayerImages(for: metadata)

            await MainActor.run {
                let viewModel = UniversalPlayerViewModel(
                    metadata: metadata,
                    serverURL: authManager.selectedServerURL ?? "",
                    authToken: authManager.selectedServerToken ?? "",
                    startOffset: metadata.viewOffset.map { Double($0) / 1000.0 },
                    loadingArtImage: artImage,
                    loadingThumbImage: thumbImage
                )
                let playerVC = PlayerPresenter.makeViewController(viewModel: viewModel)

                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = scene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    topVC.present(playerVC, animated: true)
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
            if WhatsNewView.features(for: current) != nil {
                showWhatsNew = true
            }
            lastSeenBuild = current
        }
    }
}

