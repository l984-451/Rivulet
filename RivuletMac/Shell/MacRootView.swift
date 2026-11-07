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
    @State private var paths: [MacSidebarItem: NavigationPath] = [:]
    @State private var showingAccount = false
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
        .environment(\.macOpen) { route in paths[current, default: NavigationPath()].append(route) }
        .environment(\.macSelect) { selection = $0 }
        .environment(\.macOpenAccount) { showingAccount = true }
        .focusedSceneValue(\.macSelection, $selection)
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
            paths = [:]
            selection = .home
        }
        .onChange(of: browse.libraries) { _, libraries in
            if case .library(let library) = selection, !libraries.isEmpty, !browse.isLoadingOtherServers,
               !libraries.contains(library) {
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
                        Label(library.title, systemImage: library.icon).tag(MacSidebarItem.library(library))
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                MacAccountButton()
                Spacer()
            }
            .padding(10)
        }
    }

    /// One section per server, under its name once there are several.
    private var serverGroups: [(providerID: String, name: String?, libraries: [MediaLibrary])] {
        let libraries = browse.libraries.sidebarOrder(servers: browse.providerOrder)
        var ids: [String] = []
        for library in libraries where !ids.contains(library.providerID) { ids.append(library.providerID) }
        return ids.map { id in
            (id, ids.count > 1 ? browse.labels.badge(providerID: id) : nil, libraries.filter { $0.providerID == id })
        }
    }

    // MARK: Detail

    private var detailStack: some View {
        NavigationStack(path: Binding(get: { paths[current] ?? NavigationPath() }, set: { paths[current] = $0 })) {
            root
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await browse.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh")
                            .disabled(browse.isLoadingContent)
                    }
                }
                .navigationDestination(for: MacRoute.self) { route in
                    switch route {
                    case .detail(let item): MacDetailView(item: item)
                    case .hub(let hub): MacHubGridView(hub: hub)
                    case .playlist(let playlist): MacPlaylistView(playlist: playlist)
                    case .library(let library): MacLibraryView(library: library)
                    }
                }
        }
        .macActionHost()
        // A new row or a server switch is a new stack: pages keep their items in view state.
        .id("\(current.hashValue)|\(browse.sessionGeneration)")
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
        case .library(let library): MacLibraryView(library: library)
        case .playlists(let providerID): MacPlaylistsView(providerID: providerID)
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
