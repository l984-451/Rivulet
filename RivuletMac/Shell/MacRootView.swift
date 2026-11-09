// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import SwiftUI

/// The window: a sidebar of Home, Search, Live TV, Favorites, then each server's libraries and
/// playlists, over a detail column with one NavigationStack per sidebar row.
struct MacRootView: View {
    @EnvironmentObject private var plex: PlexSession
    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var playback: MacPlaybackController
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @State private var selection: MacSidebarItem? = .home
    /// Each row's pushed pages, so switching rows and back keeps them.
    @State private var paths: [MacSidebarItem: [MacRoute]] = [:]
    /// Pages popped by Back or the back button, for Forward. A new push clears them.
    @State private var forwardPaths: [MacSidebarItem: [MacRoute]] = [:]
    @AppStorage("macSelectedRow") private var storedRow = "home"
    @State private var restoredRow = false
    @State private var pendingLink: RivuletLink?
    @State private var showingAccount = false
    @State private var shellBox = MacShellBox()
    @FocusedValue(\.macPageRefresh) private var pageRefresh: MacPageRefresh?
    @State private var showingWhatsNew = false
    @State private var choosingProfile = false
    @State private var backgroundedAt: Date?
    @AppStorage("lastSeenBuild") private var lastSeenBuild = ""
    @AppStorage(MacSettingsKeys.showPlaylists) private var showPlaylists = true
    @AppStorage(MacSettingsKeys.showFavorites) private var showFavorites = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detailStack
        }
        .environment(\.macOpen) { push($0) }
        .environment(\.macSelect) { selection = $0 }
        .environment(\.macOpenAccount) { showingAccount = true }
        .focusedSceneValue(\.macSelection, $selection)
        .focusedSceneValue(\.macHistory, history)
        .focusedSceneValue(\.macAccountMenu, MacAccountMenuActions(canSwitchProfile: profiles.hasMultipleProfiles, box: shellBox))
        .onOpenURL { if let link = RivuletLink(url: $0) { pendingLink = link } }
        .task(id: linkDeliveryKey) { await deliverLink() }
        .onChange(of: selection) { _, row in
            restoredRow = true
            storedRow = row?.storageKey ?? "home"
        }
        .sheet(isPresented: $showingAccount) { MacAccountView(showsDone: true) }
        .sheet(isPresented: $showingWhatsNew) { MacWhatsNewView(version: MacChangelog.currentVersion, showsContinue: true) }
        .sheet(isPresented: $choosingProfile) { MacProfilePickerSheet() }
        .macPlaybackHost(playback)
        // Content is withheld until a profile is entered, and nothing of the locked profile's keeps playing.
        .onChange(of: profiles.needsProfileSelection, initial: true) { _, needed in
            if needed { playback.close() }
            choosingProfile = needed
        }
        .task {
            HostPlatform.applySavedIcon()
            showWhatsNewIfUpdated()
        }
        .task {
            await plex.verifyConnection()
            // A launch that first had to enter the saved profile is signed in only now.
            showWhatsNewIfUpdated()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            backgroundedAt = .now
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The one foreground trigger: re-test a connection left for a while, then refetch stale content.
            let longAway = backgroundedAt.map { Date.now.timeIntervalSince($0) > 5 * 60 } ?? false
            Task {
                if longAway {
                    await plex.verifyConnection()
                    if profiles.needsProfileSelection, profiles.hasLoadedProfiles { choosingProfile = true }
                }
                await browse.refreshIfStale()
            }
            if profiles.needsProfileSelection, profiles.hasLoadedProfiles { choosingProfile = true }
            backgroundedAt = nil
        }
        // A server or profile switch drops every open page: they hold the old one's items.
        .onChange(of: browse.sessionGeneration) {
            // The playing title belongs to the old server or profile: its reports and Up Next would use the new one.
            playback.close()
            paths = [:]
            forwardPaths = [:]
            selection = .home
        }
        // Signing out of the last server ends the title it was playing and leaves nothing open.
        .onChange(of: browse.hasServers) { old, new in
            if old, !new {
                if playback.plexSession != nil { playback.close() }
                paths = [:]
                forwardPaths = [:]
                selection = .home
            }
        }
        // Signing out of one server drops its pages and rows, and the title it was playing.
        .onChange(of: browse.providerOrder) { old, new in
            let removed = Set(old).subtracting(new)
            guard !removed.isEmpty else { return }
            if playback.plexSession?.plays(from: removed) == true { playback.close() }
            for key in Array(paths.keys) { paths[key] = paths[key]?.filter { !removed.contains($0.providerID) } }
            for key in Array(forwardPaths.keys) { forwardPaths[key] = forwardPaths[key]?.filter { !removed.contains($0.providerID) } }
            if let id = selection?.providerID, removed.contains(id) { selection = .home }
        }
        .onChange(of: showFavorites) { _, shown in
            if !shown, selection == .favorites { selection = .home }
        }
        .onChange(of: showPlaylists) { _, shown in
            if !shown, case .playlists = selection { selection = .home }
        }
        .onChange(of: browse.playlists) {
            if case .playlists(let id) = selection, browse.playlists[id] == nil, !browse.isLoadingContent { selection = .home }
        }
        .onChange(of: browse.hiddenSidebarLibraries) {
            if case .library(let library) = selection, !browse.isSidebarLibraryShown(library) { selection = .home }
        }
        .onChange(of: browse.isLoadingOtherServers) { restoreRow() }
        .onChange(of: browse.libraries + browse.photoLibraries, initial: true) { _, libraries in
            restoreRow()
            guard case .library(let library) = selection, !libraries.isEmpty, !browse.isLoadingOtherServers else { return }
            // Match by id: a renamed or re-pinned library is the same row.
            if let fresh = libraries.first(where: { $0.id == library.id && $0.providerID == library.providerID }) {
                guard fresh != library else { return }
                paths[.library(fresh)] = paths.removeValue(forKey: .library(library))
                forwardPaths[.library(fresh)] = forwardPaths.removeValue(forKey: .library(library))
                selection = .library(fresh)
            } else {
                selection = .home
            }
        }
    }

    private var current: MacSidebarItem { selection ?? .home }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "house").tag(MacSidebarItem.home)
                Label("Search", systemImage: "magnifyingglass").tag(MacSidebarItem.search)
                Label("Live TV", systemImage: "play.tv").tag(MacSidebarItem.liveTV)
                if showFavorites, browse.offersFavorites {
                    Label("Favorites", systemImage: "heart").tag(MacSidebarItem.favorites)
                }
            }
            ForEach(serverGroups, id: \.providerID) { group in
                Section(group.name ?? String(localized: "Library")) {
                    ForEach(group.libraries) { library in
                        Label(library.title, systemImage: library.kind == .photos ? "photo.on.rectangle" : library.icon).tag(MacSidebarItem.library(library))
                    }
                    if showPlaylists, !browse.playlists(providerID: group.providerID).isEmpty {
                        Label("Playlists", systemImage: "list.and.film")
                            .tag(MacSidebarItem.playlists(providerID: group.providerID))
                    }
                }
            }
            ForEach(browse.failedServers) { failure in
                Section { MacServerFailureBanner(failure: failure).listRowInsets(EdgeInsets()) }
            }
        }
        .listStyle(.sidebar)
    }

    /// One section per server, under its name once there are several.
    private var serverGroups: [(providerID: String, name: String?, libraries: [MediaLibrary])] {
        let libraries = browse.sidebarAllLibraries.sidebarOrder(servers: browse.providerOrder)
        var ids: [String] = []
        for library in libraries where !ids.contains(library.providerID) { ids.append(library.providerID) }
        return ids.map { id in
            (id, ids.count > 1 ? browse.labels.badge(providerID: id) : nil, libraries.filter { $0.providerID == id })
        }
    }

    // MARK: Detail

    private var detailStack: some View {
        NavigationStack(path: Binding(get: { paths[current] ?? [] }, set: setPath)) {
            root
                .navigationDestination(for: MacRoute.self) { route in
                    // Pushed pages do not see the stack's actions, so each carries its own host.
                    Group {
                        switch route {
                        case .detail(let item): MacDetailView(item: item)
                        case .hub(let hub): MacHubGridView(hub: hub)
                        case .playlist(let playlist): MacPlaylistView(playlist: playlist)
                        case .library(let library): libraryPage(library)
                        case .photos(let library, let folder, let title):
                            MacPhotoLibraryView(library: library, folder: folder, title: title)
                        case .photoMemory(let library, let memory):
                            if memory.kind == .map, let (provider, library) = PhotoListing.source(for: library)() {
                                MacPhotoMapView(provider: provider, library: library)
                            } else {
                                MacPhotoLibraryView(library: library, memory: memory, title: memory.title)
                            }
                        case .person(let person, let providerID): MacPersonView(person: person, providerID: providerID)
                        case .liveRecordings: MacLiveRecordingsView()
                        }
                    }
                    .macActionHost()
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { if let pageRefresh { pageRefresh() } else { Task { await browse.refresh() } } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .disabled(browse.isLoadingContent)
                MacAccountButton()
            }
        }
        .macActionHost()
        // A new row or a server switch is a new stack: pages keep their items in view state.
        .id("\(current.hashValue)|\(browse.sessionGeneration)")
    }

    @ViewBuilder
    private func libraryPage(_ library: MediaLibrary) -> some View {
        if library.kind == .photos {
            MacPhotoLibraryView(library: library, title: browse.labels.title(library.title, providerID: library.providerID))
        } else {
            MacLibraryView(library: library)
        }
    }

    @ViewBuilder
    private var root: some View {
        switch current {
        case .liveTV:
            MacLiveTVView()
        case _ where !browse.hasServers:
            MacSignInLanding()
        case .home: MacHomeView()
        case .search: MacSearchView()
        case .favorites: MacFavoritesView()
        case .library(let library): libraryPage(library)
        case .playlists(let providerID): MacPlaylistsView(providerID: providerID)
        }
    }

    // MARK: History

    private var history: MacHistory {
        let canBack = paths[current]?.isEmpty == false
        let canForward = forwardPaths[current]?.isEmpty == false
        shellBox.back = { goBack() }
        shellBox.forward = { goForward() }
        shellBox.openAccount = { showingAccount = true }
        shellBox.switchProfile = { choosingProfile = true }
        return MacHistory(canBack: canBack, canForward: canForward, box: shellBox)
    }

    private func push(_ route: MacRoute) {
        paths[current, default: []].append(route)
        forwardPaths[current] = nil
    }

    /// The back button and swipe pop through here; what they drop becomes Forward.
    private func setPath(_ new: [MacRoute]) {
        let old = paths[current] ?? []
        if new.count < old.count {
            forwardPaths[current, default: []].append(contentsOf: old[new.count...].reversed())
        } else if new.count > old.count {
            forwardPaths[current] = nil
        }
        paths[current] = new
    }

    private func goBack() {
        guard let last = paths[current]?.popLast() else { return }
        forwardPaths[current, default: []].append(last)
    }

    private func goForward() {
        guard let next = forwardPaths[current]?.popLast() else { return }
        paths[current, default: []].append(next)
    }

    // MARK: Window restoration

    /// Reopens the row this window had. A library row waits for the libraries to load.
    private func restoreRow() {
        guard !restoredRow else { return }
        if !["home", "search", "live-tv"].contains(storedRow) {
            guard !(browse.libraries + browse.photoLibraries).isEmpty, !browse.isLoadingOtherServers else { return }
        }
        restoredRow = true
        guard let row = MacSidebarItem.restore(storedRow, libraries: browse.libraries + browse.photoLibraries) else { return }
        switch row {
        case .favorites where !(showFavorites && browse.offersFavorites): return
        case .playlists(let id) where !showPlaylists || browse.playlists[id] == nil: return
        default: selection = row
        }
    }

    // MARK: Links

    /// Changes when a link arrives or something it waits on (profile, servers) does.
    private var linkDeliveryKey: String {
        "\(pendingLink?.url?.absoluteString ?? "")|\(profiles.needsProfileSelection)|\(browse.hasServers)|\(browse.sessionGeneration)"
    }

    /// Opens or plays a held link once a profile is entered and a server is there to ask.
    private func deliverLink() async {
        guard let link = pendingLink, !profiles.needsProfileSelection else { return }
        guard !browse.allProviders.isEmpty else {
            // Signed out there is nothing to wait for: holding it would fire at the next sign-in.
            if !plex.isConfigured { pendingLink = nil }
            return
        }
        var item = await RivuletLinkResolver.item(for: link, in: browse)
        if item == nil {
            // A saved server address that stopped answering (cold launch): reconnect, retry once.
            await plex.verifyConnection()
            item = await RivuletLinkResolver.item(for: link, in: browse)
        }
        // The key changed while fetching (profile prompt, switch): the new task fetches again.
        guard !Task.isCancelled else { return }
        pendingLink = nil
        guard let item else {
            DiagLog.error(.deepLink, "Could not resolve \(link.ratingKey)")
            return
        }
        switch link.action {
        case .play: playback.play(item, startOffset: link.startOffset)
        case .detail:
            playback.close()
            push(.detail(item))
        }
    }

    /// Once per build, at launch and only when signed in, so it never stacks on the sign-in sheet.
    private func showWhatsNewIfUpdated() {
        let current = MacChangelog.currentVersion
        guard plex.isConfigured, current != lastSeenBuild else { return }
        lastSeenBuild = current
        showingWhatsNew = MacChangelog.lines(for: current) != nil
    }
}
