// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// What a tile, hero, detail page or menu can do with an item. Provided by `macActionHost()`;
/// the default does nothing. Playback goes through `MacPlaybackController`; there are no downloads on the Mac.
struct MacActions {
    var play: (MediaItem) -> Void = { _ in }
    var playFromBeginning: (MediaItem) -> Void = { _ in }
    /// Plays a playlist from its current entry, then on through the rest.
    var playQueue: (PlayQueue<MediaItem>) -> Void = { _ in }
    /// Plays a video library's titles at random, unwatched only when the flag is set.
    var shuffleLibrary: (MediaLibrary, Bool) -> Void = { _, _ in }
    /// Plays every episode of a show at random.
    var shuffleShow: (MediaItem) -> Void = { _ in }
    /// Adds to `playlist`, or asks for a name and makes a new one seeded with the item when nil.
    var addToPlaylist: (MediaItem, MediaPlaylist?) -> Void = { _, _ in }
    /// Pushes the item's detail page.
    var open: (MediaItem) -> Void = { _ in }
    var setWatched: (MediaItem, Bool) -> Void = { _, _ in }
    var removeFromContinueWatching: (MediaItem) -> Void = { _ in }
    var setWatchlisted: (MediaItem, Bool) -> Void = { _, _ in }
    var setFavorite: (MediaItem, Bool) -> Void = { _, _ in }
    /// A trailer or extra from a title's page.
    var playExtra: (MediaItemDetail.Extra) -> Void = { _ in }
    var refreshMetadata: (MediaItem) -> Void = { _ in }
    /// Asks, then deletes the item and its files from its server.
    var delete: (MediaItem) -> Void = { _ in }
    /// `MediaItemRef.actionKey` of the item being prepared, for a spinner.
    var preparingID: String?

    /// `preparingID` while a shuffle of this library or show loads its titles.
    static func shuffleID(providerID: String, itemID: String) -> String { "shuffle:\(providerID)/\(itemID)" }
}

extension EnvironmentValues {
    @Entry var macActions = MacActions()
}

extension View {
    /// The one place item actions run. Applied once at the root of the detail stack.
    func macActionHost() -> some View { modifier(MacActionHost()) }

    /// Right-click menu shared by every poster, card and row.
    func macContextMenu(_ item: MediaItem, showsDetails: Bool = false) -> some View {
        contextMenu { MacItemMenu(item: item, showsPlay: true, showsDetails: showsDetails) }
    }
}

private struct MacActionHost: ViewModifier {
    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var playback: MacPlaybackController
    @Environment(\.macOpen) private var openRoute
    @State private var preparingID: String?
    @State private var failure: (title: String, message: String)?
    @State private var newPlaylistSeed: MediaItem?
    @State private var newPlaylistName = ""
    @State private var pendingDelete: (item: MediaItem, message: String)?

    func body(content: Content) -> some View {
        content
            .environment(\.macActions, MacActions(
                play: { play($0) },
                playFromBeginning: { play($0, fromBeginning: true) },
                playQueue: playQueue,
                shuffleLibrary: { library, unwatchedOnly in
                    shuffle(providerID: library.providerID, itemID: library.id) {
                        try await $0.shuffleQueue(for: library, unwatchedOnly: unwatchedOnly)
                    }
                },
                shuffleShow: { show in
                    let ref = show.ref
                    shuffle(providerID: ref.providerID, itemID: ref.itemID) { try await $0.shuffleQueue(forShow: ref) }
                },
                addToPlaylist: { item, playlist in
                    if let playlist {
                        run(String(localized: "Couldn't Add to Playlist")) { try await browse.addToPlaylist(playlist, item: item) }
                    } else {
                        newPlaylistName = ""
                        newPlaylistSeed = item
                    }
                },
                open: { openRoute(.detail($0)) },
                setWatched: { item, watched in
                    run(String(localized: "Couldn't Update")) { try await browse.setWatched(watched, for: item) }
                },
                removeFromContinueWatching: { item in
                    run(String(localized: "Couldn't Update")) { try await browse.removeFromContinueWatching(item) }
                },
                setWatchlisted: { item, on in
                    run(String(localized: "Couldn't Update Watchlist")) { try await browse.setWatchlisted(on, item: item) }
                },
                setFavorite: { item, on in
                    run(String(localized: "Couldn't Update Favorites")) { try await browse.setFavorite(on, item: item) }
                },
                playExtra: playExtra,
                refreshMetadata: { item in
                    run(String(localized: "Couldn't Refresh Metadata")) { try await browse.refreshMetadata(item) }
                },
                delete: { item in
                    Task { pendingDelete = (item, await browse.deleteConfirmation(for: item)) }
                },
                preparingID: preparingID
            ))
            .alert("New Playlist", isPresented: Binding(get: { newPlaylistSeed != nil },
                                                        set: { if !$0 { newPlaylistSeed = nil } })) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let item = newPlaylistSeed, !name.isEmpty else { return }
                    run(String(localized: "Couldn't Create Playlist")) { try await browse.createPlaylist(title: name, seededWith: item) }
                }
            }
            .alert(
                pendingDelete.map { String(localized: "Delete \u{201C}\($0.item.title)\u{201D}?") } ?? "",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete,
                actions: { pending in
                    Button("Delete", role: .destructive) {
                        run(String(localized: "Couldn't Delete")) { try await browse.delete(pending.item) }
                    }
                    Button("Cancel", role: .cancel) {}
                },
                message: { Text($0.message) }
            )
            .alert(
                failure?.title ?? "",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                actions: { Button("OK") {} },
                message: { Text(failure?.message ?? "") }
            )
    }

    private func play(_ item: MediaItem, fromBeginning: Bool = false) {
        guard IOSPlaybackGate.canPlay(item.ref) else { return }
        playback.play(item, fromBeginning: fromBeginning)
    }

    private func playExtra(_ extra: MediaItemDetail.Extra) {
        let ref = MediaItemRef(providerID: extra.providerID, itemID: extra.id)
        guard IOSPlaybackGate.canPlay(ref), preparingID == nil,
              let provider = MediaProviderRegistry.shared.provider(for: ref.providerID) else { return }
        preparingID = extra.id
        Task {
            defer { preparingID = nil }
            do {
                playback.play(try await provider.fullDetail(for: ref).item)
            } catch let error where isCancellationError(error) {
            } catch {
                failure = (String(localized: "Couldn't Play"), error.localizedDescription)
            }
        }
    }

    private func playQueue(_ queue: PlayQueue<MediaItem>) {
        guard IOSPlaybackGate.canPlay(queue.current.ref) else { return }
        playback.play(queue.current, queue: queue.playlistQueue)
    }

    /// Loads a shuffle's titles, then plays them as a playlist. `preparingID` holds while they load.
    private func shuffle(providerID: String, itemID: String,
                         _ load: @escaping @Sendable (any MediaProvider) async throws -> PlayQueue<MediaItem>?) {
        guard preparingID == nil, let provider = browse.provider(for: providerID) else { return }
        preparingID = MacActions.shuffleID(providerID: providerID, itemID: itemID)
        Task {
            defer { preparingID = nil }
            do {
                if let queue = try await load(provider) { playQueue(queue) }
            } catch let error where isCancellationError(error) {
            } catch {
                failure = (String(localized: "Couldn't Play"), error.localizedDescription)
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

/// Menu items for one item: Play, Details, Watched, Watchlist, Favorites, playlists, Go to Show.
/// A Plex-only feature is simply absent on Jellyfin and Emby.
struct MacItemMenu: View {
    let item: MediaItem
    var showsPlay = true
    var showsDetails = false
    var showsWatchlist = true
    /// The title page has its own heart and passes false.
    var showsFavorite = true
    var showsDelete = true
    @Environment(\.macActions) private var actions
    @EnvironmentObject private var browse: BrowseStore
    @ObservedObject private var watchlist = PlexWatchlistService.shared

    private var canPlay: Bool { IOSPlaybackGate.canPlay(item.ref) }
    private var isTitle: Bool { item.kind.plexType != nil }

    var body: some View {
        if showsPlay, canPlay {
            Button(item.isInProgress ? "Resume" : "Play", systemImage: "play.fill") { actions.play(item) }
        }
        if isTitle, canPlay {
            Button("Watch from Beginning", systemImage: "arrow.counterclockwise") { actions.playFromBeginning(item) }
        }
        if showsPlay, canPlay, item.kind == .show {
            Button("Shuffle", systemImage: "shuffle") { actions.shuffleShow(item) }
        }
        if showsDetails {
            Button("Details", systemImage: "info.circle") { actions.open(item) }
        }
        Section {
            // A rewatch in progress is not watched yet: the menu offers Mark as Watched.
            Button(
                item.countsAsWatched ? "Mark as Unwatched" : "Mark as Watched",
                systemImage: item.countsAsWatched ? "circle" : "checkmark.circle"
            ) { actions.setWatched(item, !item.countsAsWatched) }
            if browse.canRemoveFromContinueWatching(item) {
                Button("Remove from Continue Watching", systemImage: "xmark.circle") { actions.removeFromContinueWatching(item) }
            }
            if showsWatchlist, WatchlistMembership.canAnswer(item), browse.supportsWatchlist(item) {
                let onList = browse.isOnWatchlist(item)
                let standsForShow = item.kind == .episode || item.kind == .season
                Button(
                    onList ? "Remove from Watchlist" : (standsForShow ? "Add Show to Watchlist" : "Add to Watchlist"),
                    systemImage: onList ? "minus.circle" : "plus.circle"
                ) { actions.setWatchlisted(item, !onList) }
            }
            if showsFavorite, FavoritesFeed.canFavorite(item) {
                let isFavorite = browse.isFavorite(item)
                Button(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                ) { actions.setFavorite(item, !isFavorite) }
            }
        }
        if browse.supportsPlaylists(item) {
            Menu("Add to Playlist", systemImage: "text.badge.plus") {
                Button("New Playlist", systemImage: "plus") { actions.addToPlaylist(item, nil) }
                Section {
                    ForEach(browse.addTargets(for: item), id: \.item.ref) { playlist in
                        Button(playlist.item.title.isEmpty ? String(localized: "Untitled") : playlist.item.title) {
                            actions.addToPlaylist(item, playlist)
                        }
                    }
                }
            }
        }
        if item.kind == .episode || item.kind == .season {
            Section {
                if let show = item.showStub {
                    Button("Go to Show", systemImage: "tv") { actions.open(show) }
                }
                if let season = item.seasonStub {
                    Button("Go to Season", systemImage: "square.stack") { actions.open(season) }
                }
            }
        }
        if isTitle, browse.canRefreshMetadata(item) {
            Section {
                Button("Refresh Metadata", systemImage: "arrow.clockwise") { actions.refreshMetadata(item) }
            }
        }
        if showsDelete, browse.canDelete(item) {
            Section {
                Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(item) }
            }
        }
    }
}
