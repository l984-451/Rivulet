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
}

/// A detail push that remembers its source tile, so push and pop zoom from the tile tapped.
struct IOSPlexDetailRoute: Hashable {
    let item: PlexMetadata
    let sourceID: String

    init(item: PlexMetadata, scope: String) {
        self.item = item
        sourceID = Self.sourceID(item, scope: scope)
    }

    static func sourceID(_ item: PlexMetadata, scope: String) -> String {
        scope.isEmpty ? item.id : "\(scope)|\(item.id)"
    }
}

/// The avatar every tab root puts at the trailing end of its toolbar.
struct IOSAccountButton: View {
    @Environment(\.openAccount) private var openAccount
    @EnvironmentObject private var plex: IOSPlexSession
    @ObservedObject private var profiles = PlexUserProfileManager.shared

    var body: some View {
        Button(action: openAccount) {
            IOSPlexAccountAvatar(url: profiles.selectedUser?.avatarURL ?? plex.profileImageURL, size: 34)
        }
        .accessibilityLabel("Account")
        .accessibilityValue(profiles.selectedUser?.displayName ?? plex.profileDisplayName ?? "")
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
    /// Registers the Plex routes once at the root of a tab's NavigationStack.
    func iosPlexDestinations() -> some View { modifier(IOSPlexDestinations()) }

    /// Marks a tile as the source of the zoom into its detail page.
    func plexZoomSource(_ item: PlexMetadata) -> some View { modifier(IOSPlexZoomSource(item: item)) }
}

private struct IOSPlexDestinations: ViewModifier {
    @Environment(\.plexZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        content
            .iosPlexActionHost()
            .navigationDestination(for: PlexMetadata.self) { detail($0, sourceID: $0.id) }
            .navigationDestination(for: IOSPlexDetailRoute.self) { detail($0.item, sourceID: $0.sourceID) }
            .navigationDestination(for: PlexLibrary.self) { IOSPlexLibraryView(library: $0).iosPlexActionHost() }
            .navigationDestination(for: IOSPlexHubRoute.self) { IOSPlexHubGridView(route: $0).iosPlexActionHost() }
            .navigationDestination(for: IOSDownloadsRoute.self) { _ in IOSDownloadsView().iosPlexActionHost() }
    }

    @ViewBuilder
    private func detail(_ item: PlexMetadata, sourceID: String) -> some View {
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
    let item: PlexMetadata
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
