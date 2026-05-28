//
//  TVSidebarView.swift
//  Rivulet
//
//  Main tvOS navigation using system TabView with sidebarAdaptable style
//

import SwiftUI
import Combine
import os.log

// Temporary diagnostic logger for intermittent sidebar focus loss.
// Filter in Console.app with: subsystem:com.rivulet.app category:SidebarFocus
private let sidebarFocusLog = Logger(subsystem: "com.rivulet.app", category: "SidebarFocus")

private func headingDescription(_ heading: UIFocusHeading) -> String {
    var parts: [String] = []
    if heading.contains(.up) { parts.append("up") }
    if heading.contains(.down) { parts.append("down") }
    if heading.contains(.left) { parts.append("left") }
    if heading.contains(.right) { parts.append("right") }
    if heading.contains(.next) { parts.append("next") }
    if heading.contains(.previous) { parts.append("previous") }
    return parts.isEmpty ? "none" : parts.joined(separator: "|")
}

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
    @State private var previousTab: SidebarTab = .home
    @State private var showProfilePicker = false
    @State private var showProfileSwitcher = false
    @State private var hasCheckedProfilePicker = false
    @State private var isAwaitingProfileSelection = false
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    @State private var showWhatsNew = false
    @State private var whatsNewVersion = ""
    @State private var deepLinkDetailItem: MediaItem?
    @State private var musicLibraryEntryToken = UUID()

    @Namespace private var contentNamespace
    @Environment(\.resetFocus) private var resetFocus

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

    private var tabSelection: Binding<SidebarTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == .account {
                    if profileManager.hasMultipleProfiles {
                        showProfileSwitcher = true
                    }
                    return  // Never store .account — selectedTab stays unchanged
                }

                // When the user picks a sidebar tab while a detail view
                // (NavigationStack push) or a Settings sub-page is on
                // screen, tvOS locks the visible tab content to that
                // stack: writing `selectedTab` lands in @State but the
                // displayed tab doesn't follow. Signal the active tab's
                // content view to clear its detail @State (popping to
                // root), then write the new selection on the next
                // runloop so SwiftUI sees a clean root-level tab swap.
                // Matches Apple TV+ app behavior.
                if nestedNavState.isNested || nestedNavState.isSettingsSubPage {
                    nestedNavState.popToRootSubject.send()
                    Task { @MainActor in
                        selectedTab = newTab
                    }
                } else {
                    selectedTab = newTab
                }
            }
        )
    }

    var body: some View {
        sidebarTabView
        .onExitCommand { }
        .task { await Self.installSidebarFocusGuard() }
        .task { await focusRecoveryWatchdog() }
        // Handle tab selection
        .onChange(of: selectedTab) { _, newTab in
            nestedNavState.isNested = false
            previousTab = newTab
            if isMusicLibraryTab(newTab) {
                musicLibraryEntryToken = UUID()
            }
        }
        .onChange(of: authManager.hasCredentials) { old, new in
            // On fresh sign-in while the user is on Settings, jump to Home
            // before the library TabSection structurally appears. Sitting on
            // Settings while a new TabSection materializes above it wedges
            // sidebar focus on tvOS (sidebar opens then immediately closes).
            if !old && new && selectedTab == .settings {
                selectedTab = .home
            }
            if old && !new {
                // Clear watchlist state on logout
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
                    showProfilePicker = true
                    // Content will load after profile is selected
                    return
                } else {
                    isAwaitingProfileSelection = false
                }
            } else {
                // Fire and forget — data used later in settings
                Task { await profileManager.fetchHomeUsers() }
                hasCheckedProfilePicker = true
            }

            // CRITICAL PATH: Only hubs needed for home screen to render
            await dataStore.loadHubsIfNeeded()

            // Kick off watchlist fetch independently — doesn't block home screen
            Task { await PlexWatchlistService.shared.fetchWatchlist() }

            // BACKGROUND: Libraries -> library hubs -> prefetch (chained, not blocking home)
            Task {
                await dataStore.loadLibrariesIfNeeded()
                await dataStore.loadLibraryHubsIfNeeded()
                dataStore.startBackgroundPrefetch(libraries: dataStore.visibleVideoLibraries)

                // Rebuild the library GUID index in the background. Used by Discover and
                // Watchlist surfaces to answer "do I own this?" in O(1). The index
                // matches by external GUID, so the fetch must include them
                // (Plex omits them from the default summary response).
                Task.detached(priority: .background) {
                    let (serverURL, token) = await MainActor.run {
                        (PlexAuthManager.shared.selectedServerURL, PlexAuthManager.shared.selectedServerToken)
                    }
                    guard let serverURL, let token else { return }

                    let visible = await MainActor.run { PlexDataStore.shared.visibleVideoLibraries }

                    var allItems: [PlexMetadata] = []
                    for library in visible {
                        if let result = try? await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                            serverURL: serverURL,
                            authToken: token,
                            sectionId: library.key,
                            start: 0,
                            size: 5000,
                            includeGuids: true
                        ) {
                            allItems.append(contentsOf: result.items)
                        }
                    }
                    let withGuids = allItems.filter { ($0.Guid ?? []).isEmpty == false }
                    let sample = withGuids.first.flatMap { $0.Guid?.first?.id } ?? "(none)"
                    sidebarFocusLog.info("[GUIDIndex] populated: \(allItems.count) items total, \(withGuids.count) with external GUIDs, sample=\(sample, privacy: .public)")
                    await LibraryGUIDIndex.shared.replace(with: allItems)
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
            guard let metadata,
                  let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }
            let providerID = MediaProviderRegistry.shared.primaryProvider?.id ?? "plex:\(serverURL)"
            deepLinkDetailItem = PlexMediaMapper.item(metadata, providerID: providerID, serverURL: serverURL, authToken: token)
            deepLinkHandler.pendingDetail = nil
        }
        .fullScreenCover(item: $deepLinkDetailItem) { metadata in
            MediaDetailView(item: metadata)
                .presentationBackground(.black)
        }
        // What's New overlay
        .fullScreenCover(isPresented: $showWhatsNew) {
            WhatsNewView(isPresented: $showWhatsNew, version: whatsNewVersion)
        }
        .onAppear {
            // Defer What's New check if profile picker needs to be shown first
            if profileManager.showProfilePickerOnLaunch && authManager.selectedServerToken != nil {
                return
            }
            checkAndShowWhatsNew()
        }
        // Profile picker overlay (launch-time "Who's Watching")
        .fullScreenCover(isPresented: $showProfilePicker) {
            ProfilePickerOverlay(isPresented: $showProfilePicker)
        }
        .onChange(of: showProfilePicker) { _, isShowing in
            if !isShowing {
                // Profile selected, unblock content
                isAwaitingProfileSelection = false

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

    // MARK: - Tab Definitions

    private var sidebarTabView: some View {
        TabView(selection: tabSelection) {
            Tab(value: SidebarTab.account) {
                Color.clear.ignoresSafeArea()
            } label: {
                Label {
                    Text(selectedTab == .account ? "Switch Profile" : profileName)
                } icon: {
                    SidebarProfileAvatar(user: profileManager.selectedUser, size: 20, trailingPad: 10)
                        .frame(width: 28, height: 28)
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: SidebarTab.search) {
                tabContent(for: .search)
            }

            Tab("Home", systemImage: "house.fill", value: SidebarTab.home) {
                tabContent(for: .home)
            }

            // Discover above libraries — bare Tab, flush under Home.
            if showDiscoverTab && discoverAboveLibraries {
                Tab("Discover", systemImage: "sparkles", value: SidebarTab.discover) {
                    tabContent(for: .discover)
                }
            }

            if liveTVAboveLibraries {
                if liveTVDataStore.hasConfiguredSources {
                    liveTVTabSection
                }
                if authManager.hasCredentials && !dataStore.visibleMediaLibraries.isEmpty {
                    libraryTabSection
                }
            } else {
                if authManager.hasCredentials && !dataStore.visibleMediaLibraries.isEmpty {
                    libraryTabSection
                }
                if liveTVDataStore.hasConfiguredSources {
                    liveTVTabSection
                }
            }

            // Discover below libraries — TabSection so it separates from the
            // library/liveTV group above it.
            if showDiscoverTab && !discoverAboveLibraries {
                discoverTabSection
            }

            TabSection("") {
                Tab("Settings", systemImage: "gearshape.fill", value: SidebarTab.settings) {
                    tabContent(for: .settings)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Hiding the tab bar leaves the sidebar visually surfaceable via
        // touchpad swipe-left but non-interactive, so the user can summon
        // the menu and find that tab selection silently no-ops. Detail
        // views and Settings sub-pages are reached via swap-on-pop (see
        // `tabSelection.set`), so they no longer hide the tab bar. Music
        // library views own the whole screen with their own internal
        // layout — keep `.hidden` there.
        .toolbarVisibility(isMusicLibrarySelected ? .hidden : .automatic, for: .tabBar)
        .animation(.easeInOut(duration: 0.18), value: nestedNavState.isNested)
        .onChange(of: nestedNavState.isNested) { _, isNested in
            guard isNested else { return }
            resetFocus(in: contentNamespace)
        }
    }

    private var libraryTabSection: some TabContent<SidebarTab> {
        TabSection(authManager.savedServerName ?? "Library") {
            ForEach(dataStore.visibleMediaLibraries, id: \.key) { library in
                Tab(library.title, systemImage: iconForLibrary(library),
                    value: SidebarTab.library(key: library.key)) {
                    tabContent(for: .library(key: library.key))
                }
            }
        }
    }

    private var discoverTabSection: some TabContent<SidebarTab> {
        TabSection("") {
            Tab("Discover", systemImage: "sparkles", value: SidebarTab.discover) {
                tabContent(for: .discover)
            }
        }
    }

    @TabContentBuilder<SidebarTab>
    private var liveTVTabSection: some TabContent<SidebarTab> {
        TabSection("Live TV") {
            if combineLiveTVSources {
                Tab("Channels", systemImage: "tv.and.mediabox",
                    value: SidebarTab.liveTV(sourceId: nil)) {
                    tabContent(for: .liveTV(sourceId: nil))
                }
            } else {
                ForEach(liveTVDataStore.sources) { source in
                    Tab(source.displayName.replacingOccurrences(of: " Live TV", with: ""),
                        systemImage: iconForSourceType(source.sourceType),
                        value: SidebarTab.liveTV(sourceId: source.id)) {
                        tabContent(for: .liveTV(sourceId: source.id))
                    }
                }
            }
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(for tab: SidebarTab) -> some View {
        Group {
            if isAwaitingProfileSelection {
                Color.clear.ignoresSafeArea()
            } else {
                switch tab {
                case .account:
                    Color.clear
                case .search:
                    PlexSearchView()
                case .home:
                    if authManager.hasCredentials {
                        PlexHomeView()
                    } else {
                        welcomeView
                    }
                case .discover:
                    DiscoverView()
                case .library(let key):
                    if let lib = dataStore.libraries.first(where: { $0.key == key }) {
                        if lib.isMusicLibrary {
                                MusicHomeView(libraryKey: lib.key, libraryTitle: lib.title)
                                    .id("\(lib.key)-\(musicLibraryEntryToken.uuidString)")
                        } else {
                            PlexLibraryView(libraryKey: lib.key, libraryTitle: lib.title)
                        }
                    }
                case .liveTV(let sourceId):
                    LiveTVContainerView(sourceIdFilter: sourceId)
                case .settings:
                    SettingsView()
                }
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

    // MARK: - Icon Helpers

    private func iconForLibrary(_ library: PlexLibrary) -> String {
        switch library.type {
        case "movie": return "film.fill"
        case "show": return "tv.fill"
        case "artist": return "music.note"
        case "photo": return "photo.fill"
        default: return "folder.fill"
        }
    }

    private func iconForSourceType(_ sourceType: LiveTVSourceType) -> String {
        switch sourceType {
        case .plex: return "play.rectangle.fill"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        case .genericM3U: return "list.bullet.rectangle"
        }
    }

    private func isMusicLibraryTab(_ tab: SidebarTab) -> Bool {
        guard case .library(let key) = tab else { return false }
        return dataStore.libraries.first(where: { $0.key == key })?.isMusicLibrary ?? false
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
                let useApplePlayer = UserDefaults.standard.bool(forKey: "useApplePlayer")
                let playerVC: UIViewController
                if useApplePlayer {
                    playerVC = NativePlayerViewController(viewModel: viewModel)
                } else {
                    let inputCoordinator = PlaybackInputCoordinator()
                    let playerView = UniversalPlayerView(viewModel: viewModel, inputCoordinator: inputCoordinator)
                    let container = PlayerContainerViewController(
                        rootView: playerView,
                        viewModel: viewModel,
                        inputCoordinator: inputCoordinator
                    )
                    playerVC = container
                }

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

    // MARK: - Focus Recovery

    /// Monitors for lost focus and restores it to the content area.
    /// Catches cases where focus ends up in limbo after overlays, popups, etc.
    @MainActor
    private func focusRecoveryWatchdog() async {
        // Wait for initial layout
        try? await Task.sleep(for: .seconds(2))

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))

            // Skip recovery while overlays are active
            guard !showProfileSwitcher, !showProfilePicker, !showWhatsNew else { continue }

            // Check if any view in the window has focus
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first,
                  let focusSystem = window.rootViewController?.view.window?.windowScene?.focusSystem
            else { continue }

            if focusSystem.focusedItem == nil {
                sidebarFocusLog.warning("[Watchdog] focusedItem == nil — calling resetFocus(in: contentNamespace). tab=\(String(describing: self.selectedTab)) nested=\(self.nestedNavState.isNested)")
                resetFocus(in: contentNamespace)
            }
        }
    }

    // MARK: - Sidebar Focus Containment

    /// Overrides shouldUpdateFocus on the sidebar's collection view class
    /// to prevent focus from escaping downward (like the Apple TV app).
    @MainActor
    private static func installSidebarFocusGuard() async {
        try? await Task.sleep(for: .seconds(1))

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return }

        var hasSwizzled = false

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))

            if let cv = findSidebarCollectionView(in: window) {
                // Disable scroll bounce
                cv.bounces = false
                cv.alwaysBounceVertical = false

                // Swizzle shouldUpdateFocus once on the collection view's class
                if !hasSwizzled {
                    Self.overrideSidebarFocusBehavior(on: type(of: cv))
                    hasSwizzled = true
                }
            }
        }
    }

    /// Replaces shouldUpdateFocus(in:) on the sidebar collection view class
    /// to block downward focus escape while allowing all other focus movement.
    private static func overrideSidebarFocusBehavior(on cvClass: AnyClass) {
        let selector = #selector(UIView.shouldUpdateFocus(in:))

        // Save the original implementation (if any) so we can call it for non-blocked cases
        let originalIMP = class_getMethodImplementation(cvClass, selector)

        typealias OriginalFunc = @convention(c) (AnyObject, Selector, UIFocusUpdateContext) -> Bool
        let originalFunc = unsafeBitCast(originalIMP, to: OriginalFunc.self)

        let block: @convention(block) (AnyObject, UIFocusUpdateContext) -> Bool = { obj, context in
            guard let selfView = obj as? UICollectionView else { return true }

            let heading = headingDescription(context.focusHeading)
            let width = selfView.frame.width
            let nextDesc = context.nextFocusedView.map { String(describing: type(of: $0)) } ?? "nil"
            let prevDesc = context.previouslyFocusedView.map { String(describing: type(of: $0)) } ?? "nil"

            // Only apply to sidebar-width collection views (not content area lists)
            guard width > 0 && width < 500 else {
                sidebarFocusLog.debug("[Swizzle] pass-through (wide cv) heading=\(heading, privacy: .public) width=\(width) prev=\(prevDesc, privacy: .public) next=\(nextDesc, privacy: .public)")
                return originalFunc(obj, selector, context)
            }

            // Block focus from leaving the sidebar downward
            if context.focusHeading == .down {
                if let nextView = context.nextFocusedView,
                   !nextView.isDescendant(of: selfView) {
                    sidebarFocusLog.warning("[Swizzle] BLOCK down-escape from sidebar cv (width=\(width)) next=\(nextDesc, privacy: .public)")
                    return false
                }
            }

            sidebarFocusLog.debug("[Swizzle] allow heading=\(heading, privacy: .public) width=\(width) prev=\(prevDesc, privacy: .public) next=\(nextDesc, privacy: .public)")
            return originalFunc(obj, selector, context)
        }

        let imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        let method = class_getInstanceMethod(UIView.self, selector)!
        let types = method_getTypeEncoding(method)!
        class_replaceMethod(cvClass, selector, imp, types)
    }

    /// Finds the sidebar's UICollectionView by looking for a narrow, left-aligned collection view
    private static func findSidebarCollectionView(in view: UIView) -> UICollectionView? {
        if let cv = view as? UICollectionView {
            let frame = cv.frame
            // Sidebar is narrow (< 500pt) and left-aligned
            if frame.origin.x == 0 && frame.width > 0 && frame.width < 500 {
                return cv
            }
        }
        for subview in view.subviews {
            if let found = findSidebarCollectionView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func checkAndShowWhatsNew() {
        guard !isAwaitingProfileSelection else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let current = "\(version) (\(build))"

        if current != lastSeenBuild {
            if WhatsNewView.features(for: current) != nil {
                whatsNewVersion = current
                showWhatsNew = true
            }
            lastSeenBuild = current
        }
    }
}

// MARK: - Sidebar Profile Avatar

struct SidebarProfileAvatar: View {
    let user: PlexHomeUser?
    let size: CGFloat
    var trailingPad: CGFloat = 0

    @State private var circularImage: UIImage?

    private var totalWidth: CGFloat { size + trailingPad }

    var body: some View {
        Group {
            if let circularImage {
                Image(uiImage: circularImage)
                    .renderingMode(.original)
            } else {
                HStack(spacing: 0) {
                    placeholder
                        .frame(width: size, height: size)
                    if trailingPad > 0 {
                        Color.clear.frame(width: trailingPad)
                    }
                }
            }
        }
        .frame(width: totalWidth, height: size)
        .task(id: user?.thumb) {
            await loadCircularAvatar()
        }
    }

    private func loadCircularAvatar() async {
        guard let thumbURL = user?.thumb, let url = URL(string: thumbURL) else {
            circularImage = nil
            return
        }

        // Try loading from ImageCacheManager first, then network
        let image: UIImage?
        if let cached = await ImageCacheManager.shared.image(for: url) {
            image = cached
        } else {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let downloaded = UIImage(data: data) else {
                return
            }
            image = downloaded
        }

        guard let source = image else { return }

        // Render circular image with border (wider canvas for trailing pad)
        let canvasWidth = size + trailingPad
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasWidth, height: size))
        let circular = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let circlePath = UIBezierPath(ovalIn: rect)
            circlePath.addClip()

            // Draw image scaled to fill
            let imageSize = source.size
            let scale = max(size / imageSize.width, size / imageSize.height)
            let drawWidth = imageSize.width * scale
            let drawHeight = imageSize.height * scale
            let drawRect = CGRect(
                x: (size - drawWidth) / 2,
                y: (size - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
            source.draw(in: drawRect)

            // Draw subtle border
            ctx.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
            ctx.cgContext.setLineWidth(1)
            ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }

        circularImage = circular
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(profileColor.gradient)
            Text(initial)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var initial: String {
        (user?.displayName ?? "?").prefix(1).uppercased()
    }

    private var profileColor: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        guard let id = user?.id else { return .gray }
        return colors[abs(id) % colors.count]
    }
}
