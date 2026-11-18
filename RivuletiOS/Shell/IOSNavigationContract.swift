// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

extension EnvironmentValues {
    /// Opens the account sheet. The root view sets it; every tab root's avatar calls it.
    @Entry var openAccount: () -> Void = {}
    /// Shows the Downloads list. The root view sets it.
    @Entry var openDownloads: () -> Void = {}
    /// Per-tab namespace for the poster-to-detail zoom. The root sets one per NavigationStack.
    @Entry var plexZoomNamespace: Namespace.ID? = nil
    /// Prefix for zoom source ids, so the same item in two rows (or the hero) has distinct sources.
    @Entry var plexZoomScope = ""
    /// The iPad sidebar's Library section, for the title menu on each of its pages. The root view sets it.
    @Entry var libraryTabs: IOSLibraryTabs? = nil
}

/// The iPad sidebar's Library section: Downloads, each library, each server's Playlists.
/// In the top tab bar the whole section is one Library item that reopens the last tab
/// picked, so each of its pages titles itself with a menu of the others.
struct IOSLibraryTabs {
    struct Entry {
        let tab: String
        let title: String
    }

    let entries: [Entry]
    /// The tab whose page shows the menu.
    let current: String
    /// The sidebar is open and lists the tabs itself, so the menu leaves them out.
    let sidebarShowing: Bool
    let select: (String) -> Void
    /// Account > Library, as a sheet.
    let edit: () -> Void
}

extension View {
    /// On an iPad sidebar tab's own page, the page's title, in the bar beside the tab bar and
    /// at its size: the large title slot below takes no taps on iPadOS 26. The page draws no
    /// title of its own. While the top tab bar shows, the title is a menu of the Library
    /// section, then `views` (the page's own choices); with the sidebar open, of `views` alone.
    /// Over a hero's artwork it takes the bar's glass, which keeps it legible over art and,
    /// once scrolled, over a light page alike.
    func iosLibraryTitleMenu<Views: View>(isSidebarTab: Bool, overArtwork: Bool = false,
                                          @ViewBuilder views: () -> Views) -> some View {
        modifier(IOSLibraryTitleMenu(isSidebarTab: isSidebarTab, overArtwork: overArtwork, views: views()))
    }

    func iosLibraryTitleMenu(isSidebarTab: Bool) -> some View {
        modifier(IOSLibraryTitleMenu<EmptyView>(isSidebarTab: isSidebarTab, overArtwork: false, views: nil))
    }
}

private struct IOSLibraryTitleMenu<Views: View>: ViewModifier {
    let isSidebarTab: Bool
    let overArtwork: Bool
    let views: Views?
    @Environment(\.libraryTabs) private var tabs

    func body(content: Content) -> some View {
        content.toolbar {
            // `isSidebarTab` too: a page pushed over the tab's own can still read the environment.
            if isSidebarTab, let tabs {
                ToolbarItem(placement: .topBarLeading) { title(tabs) }
                    .sharedBackgroundVisibility(overArtwork ? .visible : .hidden)
            }
        }
    }

    /// Always a Menu, empty when there is nothing to offer (a page without views, with the
    /// sidebar open): swapping it for plain text and back rebuilt the bar item, and the rebuilt
    /// menu ignored its first tap.
    private func title(_ tabs: IOSLibraryTabs) -> some View {
        let title = tabs.entries.first { $0.tab == tabs.current }?.title ?? ""
        let offersMenu = !tabs.sidebarShowing || views != nil
        return Menu {
            if !tabs.sidebarShowing {
                Picker("Library", selection: Binding(get: { tabs.current }, set: tabs.select)) {
                    ForEach(tabs.entries, id: \.tab) { Text(verbatim: $0.title).tag($0.tab) }
                }
                .pickerStyle(.inline)
            }
            views
            if !tabs.sidebarShowing {
                Divider()
                Button("Edit Libraries…", systemImage: "slider.horizontal.3", action: tabs.edit)
            }
        } label: {
            label(title, menu: offersMenu)
        }
        .accessibilityLabel(offersMenu ? Text("Library, \(title)") : Text(verbatim: title))
    }

    /// The tab bar's own text size and weight.
    private func label(_ title: String, menu: Bool) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: title).lineLimit(1)
            if menu { Image(systemName: "chevron.down").font(.caption.weight(.semibold)) }
        }
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
    }
}

extension View {
    /// The app-wide objects, passed into a sheet by hand: on a Mac the sheet's body
    /// is built before it inherits them from the presenter, and reading one crashes.
    func iosSessionObjects(_ plex: PlexSession) -> some View {
        environmentObject(plex)
            .environmentObject(plex.browse)
            .environmentObject(IOSDownloadCenter.shared)
    }
}

/// A detail push that remembers its source tile, so push and pop zoom from the tile tapped.
struct IOSPlexDetailRoute: Hashable {
    let item: MediaItem
    let sourceID: String

    init(item: MediaItem, scope: String) {
        self.item = item
        sourceID = Self.sourceID(item, scope: scope)
    }

    static func sourceID(_ item: MediaItem, scope: String) -> String {
        let id = "\(item.ref.providerID)|\(item.ref.itemID)"
        return scope.isEmpty ? id : "\(scope)|\(id)"
    }
}

/// The avatar every tab root puts at the trailing end of its toolbar.
struct IOSAccountButton: View {
    @Environment(\.openAccount) private var openAccount
    @EnvironmentObject private var plex: PlexSession
    /// Its libraries change on every Jellyfin or Emby sign-in and sign-out, which re-reads the name.
    @EnvironmentObject private var browse: BrowseStore
    @ObservedObject private var profiles = PlexUserProfileManager.shared

    var body: some View {
        Button(action: openAccount) {
            IOSPlexAccountAvatar(url: profiles.selectedUser?.avatarURL ?? plex.profileImageURL, size: 34)
        }
        .accessibilityLabel("Account")
        .accessibilityValue(accountName)
    }

    /// Same rule as the tvOS sidebar's profile row (`AccountName`).
    private var accountName: String {
        AccountName.resolve(plexProfile: profiles.selectedUser?.displayName,
                                   plexUser: plex.profileDisplayName,
                                   otherServerUsers: AccountName.otherServerUsers) ?? ""
    }
}

/// The avatar as its own trailing toolbar item. The shared glass is hidden so the
/// circle stands alone, and the spacer keeps it out of any neighbouring button group.
struct IOSAccountToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) { IOSAccountButton() }
            .sharedBackgroundVisibility(.hidden)
    }
}

extension View {
    /// A large title, or none drawn: it stays set for the Back button of pages pushed over it.
    func iosLargeTitle(_ title: String, shown: Bool) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(shown ? .large : .inline)
            .toolbar(removing: shown ? nil : .title)
    }

    /// Registers the browse routes once at the root of a tab's NavigationStack.
    func iosPlexDestinations() -> some View { modifier(IOSPlexDestinations()) }

    /// Marks a tile as the source of the zoom into its detail page.
    func plexZoomSource(_ item: MediaItem) -> some View { modifier(IOSPlexZoomSource(item: item)) }
}

private struct IOSPlexDestinations: ViewModifier {
    @Environment(\.plexZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        content
            .iosPlexActionHost()
            .navigationDestination(for: MediaItem.self) { detail($0, sourceID: IOSPlexDetailRoute.sourceID($0, scope: "")) }
            .navigationDestination(for: IOSPlexDetailRoute.self) { detail($0.item, sourceID: $0.sourceID) }
            .navigationDestination(for: MediaPerson.self) { IOSPersonView(person: $0).iosPlexActionHost() }
            .navigationDestination(for: MediaLibrary.self) { IOSLibraryPage(library: $0).iosPlexActionHost() }
            .navigationDestination(for: IOSPlexHubRoute.self) { IOSPlexHubGridView(route: $0).iosPlexActionHost() }
            .navigationDestination(for: IOSPlexPlaylistRoute.self) { IOSPlexPlaylistView(route: $0).iosPlexActionHost() }
    }

    @ViewBuilder
    private func detail(_ item: MediaItem, sourceID: String) -> some View {
        if let namespace {
            IOSPlexDetailView(item: item)
                .iosPlexActionHost()
                .navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            IOSPlexDetailView(item: item).iosPlexActionHost()
        }
    }
}

private struct IOSPlexZoomSource: ViewModifier {
    let item: MediaItem
    @Environment(\.plexZoomNamespace) private var namespace
    @Environment(\.plexZoomScope) private var scope

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: IOSPlexDetailRoute.sourceID(item, scope: scope), in: namespace)
        } else {
            content
        }
    }
}
