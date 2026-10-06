// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// What a tile, hero, detail page or menu can do with an item. Provided by
/// `IOSPlexActionHost`; the default does nothing.
struct IOSPlexActions {
    var play: (PlexMetadata) -> Void = { _ in }
    var open: (PlexMetadata) -> Void = { _ in }
    var setWatched: (PlexMetadata, Bool) -> Void = { _, _ in }
    var setWatchlisted: (PlexMetadata, Bool) -> Void = { _, _ in }
    /// A movie or episode, or every episode of a season.
    var download: (PlexMetadata) -> Void = { _ in }
    /// Item whose playback is being prepared, for a spinner.
    var preparingID: String?
}

extension EnvironmentValues {
    @Entry var plexActions = IOSPlexActions()
}

extension View {
    /// The one place Plex playback starts. Applied to each stack root and
    /// each pushed page by `iosPlexDestinations()`.
    func iosPlexActionHost() -> some View {
        modifier(IOSPlexActionHost())
    }
}

private struct IOSPlexActionHost: ViewModifier {
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var playback: IOSPlaybackController
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @State private var preparingID: String?
    @State private var pushed: PlexMetadata?
    @State private var failure: (title: String, message: String)?

    func body(content: Content) -> some View {
        content
            .environment(\.plexActions, IOSPlexActions(
                play: play,
                open: { pushed = $0 },
                setWatched: { item, watched in
                    run("Couldn't Update") { try await plex.setWatched(watched, for: item) }
                },
                setWatchlisted: { item, on in
                    run("Couldn't Update Watchlist") { try await plex.setWatchlisted(on, item: item) }
                },
                download: { item in
                    if item.type == "season" {
                        run("Couldn't Download Season") { try await downloads.downloadSeason(item) }
                    } else {
                        downloads.download(item)
                    }
                },
                preparingID: preparingID
            ))
            .navigationDestination(item: $pushed) { IOSPlexDetailView(item: $0).iosPlexActionHost() }
            .alert(
                failure?.title ?? "",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                actions: { Button("OK") {} },
                message: { Text(failure?.message ?? "") }
            )
    }

    private func play(_ item: PlexMetadata) {
        guard preparingID == nil else { return }
        preparingID = item.id
        Task {
            defer { preparingID = nil }
            do {
                let target = try await plex.playableTarget(for: item)
                playback.play(try await plex.playback(for: target))
            } catch let error where isCancellationError(error) {
            } catch {
                failure = ("Couldn't Play", error.localizedDescription)
            }
        }
    }

    private func run(_ title: String, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch let error where isCancellationError(error) {} catch {
                failure = (title, error.localizedDescription)
            }
        }
    }
}

// MARK: - Item menu

extension View {
    /// Long-press menu shared by every poster, card and row, with an art preview.
    func plexContextMenu(_ item: PlexMetadata, showsDetails: Bool = false) -> some View {
        modifier(IOSPlexContextMenu(item: item, showsDetails: showsDetails))
    }
}

/// The preview renders in its own host, which does not inherit environment objects.
private struct IOSPlexContextMenu: ViewModifier {
    let item: PlexMetadata
    let showsDetails: Bool
    @EnvironmentObject private var plex: IOSPlexSession

    func body(content: Content) -> some View {
        content.contextMenu {
            IOSPlexItemMenu(item: item, showsPlay: true, showsDetails: showsDetails)
        } preview: {
            IOSPlexMenuPreview(item: item).environmentObject(plex)
        }
    }
}

/// Menu items for one item: Play, Details, Watched, Watchlist, Go to Show.
struct IOSPlexItemMenu: View {
    let item: PlexMetadata
    var showsPlay = true
    var showsDetails = false
    var showsWatchlist = true
    @Environment(\.plexActions) private var actions
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @ObservedObject private var watchlist = PlexWatchlistService.shared

    var body: some View {
        if showsPlay {
            Button(item.isInProgress ? "Resume" : "Play", systemImage: "play.fill") { actions.play(item) }
        }
        if showsDetails {
            Button("Details", systemImage: "info.circle") { actions.open(item) }
        }
        Section {
            Button(
                item.isWatched ? "Mark as Unwatched" : "Mark as Watched",
                systemImage: item.isWatched ? "circle" : "checkmark.circle"
            ) { actions.setWatched(item, !item.isWatched) }
            if showsWatchlist, ["movie", "show", "season", "episode"].contains(item.type ?? "") {
                let onList = plex.isOnWatchlist(item)
                let standsForShow = item.type == "episode" || item.type == "season"
                Button(
                    onList ? "Remove from Watchlist" : (standsForShow ? "Add Show to Watchlist" : "Add to Watchlist"),
                    systemImage: onList ? "minus.circle" : "plus.circle"
                ) { actions.setWatchlisted(item, !onList) }
            }
        }
        downloadItems
        if item.type == "episode" || item.type == "season" {
            Section {
                if let show = item.showStub {
                    Button("Go to Show", systemImage: "tv") { actions.open(show) }
                }
                if let season = item.seasonStub {
                    Button("Go to Season", systemImage: "square.stack") { actions.open(season) }
                }
            }
        }
    }
}

extension IOSPlexItemMenu {
    @ViewBuilder
    private var downloadItems: some View {
        if item.isPlayable, let key = item.ratingKey {
            if let record = downloads.record(for: key) {
                if case .failed = record.state {
                    Button("Retry Download", systemImage: "arrow.clockwise") { downloads.retry(recordID: record.id) }
                }
                Button(record.state.isSettled ? "Remove Download" : "Cancel Download",
                       systemImage: "trash", role: .destructive) {
                    downloads.delete(recordID: record.id)
                }
            } else if plex.isConfigured {
                Button("Download", systemImage: "arrow.down.circle") { actions.download(item) }
            }
        } else if item.type == "season", plex.isConfigured {
            Button("Download Season", systemImage: "arrow.down.circle") { actions.download(item) }
        }
    }
}

private struct IOSPlexMenuPreview: View {
    let item: PlexMetadata

    var body: some View {
        if item.type == "episode" {
            IOSPlexArtwork(item: item, kind: .thumb, width: 320, aspectRatio: 16 / 9)
                .frame(width: 320, height: 180)
        } else {
            IOSPlexArtwork(item: item, kind: .poster, width: 240, aspectRatio: 2 / 3)
                .frame(width: 240, height: 360)
        }
    }
}

extension PlexMetadata {
    /// Enough of the parent show for a detail page to load the rest.
    var showStub: PlexMetadata? {
        let key = type == "episode" ? grandparentRatingKey : (type == "season" ? parentRatingKey : nil)
        guard let key else { return nil }
        return PlexMetadata(
            ratingKey: key,
            guid: type == "episode" ? grandparentGuid : parentGuid,
            type: "show",
            title: type == "episode" ? grandparentTitle : parentTitle,
            thumb: type == "episode" ? grandparentThumb : parentThumb,
            art: grandparentArt ?? art
        )
    }

    /// An episode's season.
    var seasonStub: PlexMetadata? {
        guard type == "episode", let parentRatingKey else { return nil }
        return PlexMetadata(
            ratingKey: parentRatingKey,
            guid: parentGuid,
            type: "season",
            title: parentIndex.map { "Season \($0)" } ?? parentTitle,
            thumb: parentThumb,
            art: grandparentArt,
            parentRatingKey: grandparentRatingKey,
            parentGuid: grandparentGuid,
            parentTitle: grandparentTitle,
            index: parentIndex
        )
    }
}
