//
//  MediaItemContextMenu.swift
//  Rivulet
//
//  Context menu for media items with common actions
//

import SwiftUI

// MARK: - Context Menu Source

/// Identifies where the context menu was triggered from
enum MediaItemContextSource {
    case continueWatching
    case library
    case other
}

// MARK: - Context Menu Actions

/// Callback type for context menu actions that may require data refresh
typealias MediaItemRefreshCallback = () async -> Void

/// Callback type for navigation actions (synchronous)
typealias MediaItemNavigationCallback = () -> Void

// MARK: - Context Menu Modifier

/// A view modifier that adds a context menu to media items with common Plex actions
struct MediaItemContextMenu: ViewModifier {
    let item: PlexMetadata
    let serverURL: String
    let authToken: String
    let source: MediaItemContextSource
    var onRefreshNeeded: MediaItemRefreshCallback?
    var onShowInfo: MediaItemNavigationCallback?
    var onGoToSeason: MediaItemNavigationCallback?
    var onGoToShow: MediaItemNavigationCallback?

    @State private var isPerformingAction = false

    private let networkManager = PlexNetworkManager.shared
    private let dataStore = PlexDataStore.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            // Watch from Beginning
            Button {
                performAction(optimisticWatched: false) {
                    try await networkManager.markUnwatched(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: item.ratingKey ?? ""
                    )
                }
            } label: {
                Label("Watch from Beginning", systemImage: "play.fill")
            }

            Divider()

            // Mark as Watched
            if item.viewCount == nil || item.viewCount == 0 || item.watchProgress != nil {
                Button {
                    performAction(optimisticWatched: true) {
                        try await networkManager.markWatched(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Mark as Watched", systemImage: "eye.fill")
                }
            }

            // Mark as Unwatched (only show if already watched)
            if let viewCount = item.viewCount, viewCount > 0 {
                Button {
                    performAction(optimisticWatched: false) {
                        try await networkManager.markUnwatched(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Mark as Unwatched", systemImage: "eye.slash.fill")
                }
            }

            // Remove from Continue Watching (only in continue watching section)
            if source == .continueWatching {
                Button(role: .destructive) {
                    performAction {
                        try await networkManager.removeFromContinueWatching(
                            serverURL: serverURL,
                            authToken: authToken,
                            ratingKey: item.ratingKey ?? ""
                        )
                    }
                } label: {
                    Label("Remove from Continue Watching", systemImage: "xmark.circle.fill")
                }
            }

            // Go to Season/Show (only for episodes)
            if item.type == "episode" {
                if let onGoToSeason = onGoToSeason, item.parentRatingKey != nil {
                    Button {
                        onGoToSeason()
                    } label: {
                        Label("Go to Season", systemImage: "list.number")
                    }
                }

                if let onGoToShow = onGoToShow, item.grandparentRatingKey != nil {
                    Button {
                        onGoToShow()
                    } label: {
                        Label("Go to Show", systemImage: "tv")
                    }
                }
            }

            Divider()

            // More Info (navigate to detail view)
            if let onShowInfo = onShowInfo {
                Button {
                    onShowInfo()
                } label: {
                    Label("More Info", systemImage: "info.circle")
                }
            }

            // Refresh Metadata
            Button {
                performAction {
                    try await networkManager.refreshMetadata(
                        serverURL: serverURL,
                        authToken: authToken,
                        ratingKey: item.ratingKey ?? ""
                    )
                }
            } label: {
                Label("Refresh Metadata", systemImage: "arrow.clockwise")
            }
        }
    }

    private func performAction(optimisticWatched: Bool? = nil, _ action: @escaping () async throws -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true

        Task {
            do {
                try await action()
                // Apply optimistic update immediately for instant UI feedback
                if let watched = optimisticWatched, let ratingKey = item.ratingKey {
                    await MainActor.run {
                        dataStore.updateItemWatchStatus(ratingKey: ratingKey, watched: watched)
                    }
                }
                // Also refresh from server for consistency
                await onRefreshNeeded?()
            } catch {
                print("Context menu action failed: \(error)")
            }
            isPerformingAction = false
        }
    }
}

// MARK: - View Extension

extension View {
    /// Adds a context menu with common Plex media actions
    func mediaItemContextMenu(
        item: PlexMetadata,
        serverURL: String,
        authToken: String,
        source: MediaItemContextSource = .other,
        onRefreshNeeded: MediaItemRefreshCallback? = nil,
        onShowInfo: MediaItemNavigationCallback? = nil,
        onGoToSeason: MediaItemNavigationCallback? = nil,
        onGoToShow: MediaItemNavigationCallback? = nil
    ) -> some View {
        modifier(MediaItemContextMenu(
            item: item,
            serverURL: serverURL,
            authToken: authToken,
            source: source,
            onRefreshNeeded: onRefreshNeeded,
            onShowInfo: onShowInfo,
            onGoToSeason: onGoToSeason,
            onGoToShow: onGoToShow
        ))
    }
}
