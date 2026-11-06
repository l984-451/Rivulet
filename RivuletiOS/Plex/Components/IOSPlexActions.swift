// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// What a tile, hero, detail page or menu can do with an item. Provided by
/// `IOSPlexActionHost`; the default does nothing.
struct IOSPlexActions {
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
    var open: (MediaItem) -> Void = { _ in }
    var setWatched: (MediaItem, Bool) -> Void = { _, _ in }
    var setWatchlisted: (MediaItem, Bool) -> Void = { _, _ in }
    /// Adds a movie or show to Favorites on its server, or removes it.
    var setFavorite: (MediaItem, Bool) -> Void = { _, _ in }
    /// A movie or episode, or every episode of a season. Plex items only.
    var download: (MediaItem) -> Void = { _ in }
    /// A trailer or extra from a title's page.
    var playExtra: (MediaItemDetail.Extra) -> Void = { _ in }
    var refreshMetadata: (MediaItem) -> Void = { _ in }
    /// Asks, then deletes the item and its files from its server.
    var delete: (MediaItem) -> Void = { _ in }
    /// `MediaItemRef.actionKey` of the item whose playback is being prepared, for a spinner.
    var preparingID: String?

    /// `preparingID` while a shuffle of this library or show loads its titles.
    static func shuffleID(providerID: String, itemID: String) -> String { "shuffle:\(providerID)/\(itemID)" }
}

extension EnvironmentValues {
    @Entry var plexActions = IOSPlexActions()
}

extension View {
    /// The one place playback starts. Applied to each stack root and
    /// each pushed page by `iosPlexDestinations()`.
    func iosPlexActionHost() -> some View {
        modifier(IOSPlexActionHost())
    }
}

private struct IOSPlexActionHost: ViewModifier {
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var browse: IOSBrowseStore
    @EnvironmentObject private var playback: IOSPlaybackController
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @State private var preparingID: String?
    @State private var pushed: MediaItem?
    @State private var failure: (title: String, message: String)?
    @State private var newPlaylistSeed: MediaItem?
    @State private var newPlaylistName = ""
    @State private var pendingDelete: (item: MediaItem, message: String)?

    func body(content: Content) -> some View {
        content
            .environment(\.plexActions, IOSPlexActions(
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
                open: { pushed = $0 },
                setWatched: { item, watched in
                    run(String(localized: "Couldn't Update")) { try await browse.setWatched(watched, for: item) }
                },
                setWatchlisted: { item, on in
                    run(String(localized: "Couldn't Update Watchlist")) { try await browse.setWatchlisted(on, item: item) }
                },
                setFavorite: { item, on in
                    run(String(localized: "Couldn't Update Favorites")) { try await browse.setFavorite(on, item: item) }
                },
                download: download,
                playExtra: playExtra,
                refreshMetadata: { item in
                    run(String(localized: "Couldn't Refresh Metadata")) { try await browse.refreshMetadata(item) }
                },
                delete: { item in
                    Task { pendingDelete = (item, await browse.deleteConfirmation(for: item)) }
                },
                preparingID: preparingID
            ))
            .navigationDestination(item: $pushed) { IOSPlexDetailView(item: $0).iosPlexActionHost() }
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

    /// Plex items play through the Plex player path; Jellyfin and Emby items through the provider entry point.
    private func play(_ item: MediaItem, fromBeginning: Bool = false) {
        guard IOSPlaybackGate.canPlay(item.ref), preparingID == nil else { return }
        guard item.ref.providerID.hasPrefix("plex:") else {
            playback.play(item, fromBeginning: fromBeginning)
            return
        }
        guard serverIsKnown(item.ref) else { return }
        preparingID = item.ref.actionKey
        Task {
            defer { preparingID = nil }
            do {
                let target = try await plex.playableTarget(for: item.plexStub)
                playback.play(try await plex.playback(for: target, fromBeginning: fromBeginning))
            } catch let error where isCancellationError(error) {
            } catch {
                failure = (String(localized: "Couldn't Play"), error.localizedDescription)
            }
        }
    }

    private func playExtra(_ extra: MediaItemDetail.Extra) {
        let ref = MediaItemRef(providerID: extra.providerID, itemID: extra.id)
        guard IOSPlaybackGate.canPlay(ref), preparingID == nil else { return }
        guard ref.providerID.hasPrefix("plex:") else {
            playProviderExtra(ref)
            return
        }
        guard serverIsKnown(ref) else { return }
        preparingID = extra.id
        Task {
            defer { preparingID = nil }
            do {
                var clip = PlexMetadata(ratingKey: extra.id, type: "clip", title: extra.title,
                                        duration: extra.duration.map { Int($0 * 1000) })
                clip.serverID = ref.plexServerID
                playback.play(try await plex.playback(for: clip))
            } catch let error where isCancellationError(error) {
            } catch {
                failure = (String(localized: "Couldn't Play"), error.localizedDescription)
            }
        }
    }

    /// An extra off Plex is a library item of its own server.
    private func playProviderExtra(_ ref: MediaItemRef) {
        guard let provider = MediaProviderRegistry.shared.provider(for: ref.providerID) else { return }
        preparingID = ref.itemID
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
        guard IOSPlaybackGate.canPlay(queue.current.ref), preparingID == nil else { return }
        guard queue.current.ref.providerID.hasPrefix("plex:") else {
            playback.play(queue.current, queue: queue.playlistQueue)
            return
        }
        guard serverIsKnown(queue.current.ref),
              let plexQueue = PlayQueue(entries: queue.entries.map(\.plexStub), startingAt: queue.index) else { return }
        preparingID = queue.current.ref.actionKey
        Task {
            defer { preparingID = nil }
            do {
                playback.play(try await plex.playback(for: plexQueue.current), queue: plexQueue)
            } catch let error where isCancellationError(error) {
            } catch {
                failure = (String(localized: "Couldn't Play"), error.localizedDescription)
            }
        }
    }

    /// Loads a shuffle's titles, then plays them as a playlist. An empty result plays nothing.
    /// `preparingID` holds while they load, so a second tap does nothing.
    private func shuffle(providerID: String, itemID: String,
                         _ load: @escaping @Sendable (any MediaProvider) async throws -> PlayQueue<MediaItem>?) {
        guard preparingID == nil, let provider = browse.provider(for: providerID) else { return }
        preparingID = IOSPlexActions.shuffleID(providerID: providerID, itemID: itemID)
        Task {
            do {
                let queue = try await load(provider)
                // Cleared first: playQueue refuses while anything is preparing, and sets its own.
                preparingID = nil
                if let queue { playQueue(queue) }
            } catch let error where isCancellationError(error) {
                preparingID = nil
            } catch {
                preparingID = nil
                failure = (String(localized: "Couldn't Play"), error.localizedDescription)
            }
        }
    }

    private func download(_ item: MediaItem) {
        guard IOSDownloadGate.canDownload(item.ref) else {
            failure = (String(localized: "Couldn't Download"), MediaProviderError.unreachable.localizedDescription)
            return
        }
        if item.kind == .season {
            run(String(localized: "Couldn't Download Season")) { try await downloads.downloadSeason(item) }
        } else {
            downloads.download(item)
        }
    }

    /// A Plex item whose server has left the account is refused: its rating key means nothing on another server.
    private func serverIsKnown(_ ref: MediaItemRef) -> Bool {
        guard ref.hasKnownPlexServer else {
            failure = (String(localized: "Couldn't Play"), MediaProviderError.unreachable.localizedDescription)
            return false
        }
        return true
    }

    private func run(_ title: String, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch let error where isCancellationError(error) {} catch {
                failure = (title, error.localizedDescription)
            }
        }
    }
}

// MARK: - Context menu

extension View {
    /// Long-press menu shared by every poster, card and row, with an art preview.
    func plexContextMenu(_ item: MediaItem, showsDetails: Bool = false) -> some View {
        modifier(IOSPlexContextMenu(item: item, showsDetails: showsDetails))
    }
}

/// The preview renders in its own host, which does not inherit environment objects.
private struct IOSPlexContextMenu: ViewModifier {
    let item: MediaItem
    let showsDetails: Bool
    @EnvironmentObject private var browse: IOSBrowseStore

    func body(content: Content) -> some View {
        content.contextMenu {
            IOSPlexItemMenu(item: item, showsPlay: true, showsDetails: showsDetails)
        } preview: {
            IOSPlexMenuPreview(item: item).environmentObject(browse)
        }
    }
}

/// Menu items for one item: Play, Details, Watched, Watchlist, Go to Show. Each one the item's
/// server supports; a Plex-only feature is simply absent on Jellyfin and Emby.
struct IOSPlexItemMenu: View {
    let item: MediaItem
    var showsPlay = true
    var showsDetails = false
    var showsWatchlist = true
    /// The title page has its own heart and passes false.
    var showsFavorite = true
    var showsDelete = true
    @Environment(\.plexActions) private var actions
    @EnvironmentObject private var browse: IOSBrowseStore
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @ObservedObject private var watchlist = PlexWatchlistService.shared

    private var canPlay: Bool { IOSPlaybackGate.canPlay(item.ref) }

    var body: some View {
        if showsPlay, canPlay {
            Button(item.isInProgress ? "Resume" : "Play", systemImage: "play.fill") { actions.play(item) }
        }
        if isTitle, canPlay {
            Button("Watch from Beginning", systemImage: "arrow.counterclockwise") { actions.playFromBeginning(item) }
        }
        // The show page has its own Shuffle button and passes showsPlay false.
        if showsPlay, canPlay, item.kind == .show {
            Button("Shuffle", systemImage: "shuffle") { actions.shuffleShow(item) }
        }
        if showsDetails {
            Button("Details", systemImage: "info.circle") { actions.open(item) }
        }
        Section {
            // A rewatch in progress is not watched yet (#270): the menu offers Mark as Watched.
            Button(
                item.countsAsWatched ? "Mark as Unwatched" : "Mark as Watched",
                systemImage: item.countsAsWatched ? "circle" : "checkmark.circle"
            ) { actions.setWatched(item, !item.countsAsWatched) }
            // An episode or season stands for its show, whose guid the Plex mapper carries.
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
        downloadItems
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

extension IOSPlexItemMenu {
    private var isTitle: Bool { item.kind.plexType != nil }

    @ViewBuilder
    private var downloadItems: some View {
        if browse.canDownload(item) {
            if item.isPlayable {
                if let record = downloads.record(for: item.ref) {
                    if case .failed = record.state {
                        Button("Retry Download", systemImage: "arrow.clockwise") { downloads.retry(recordID: record.id) }
                    }
                    Button(record.state.isSettled ? "Remove Download" : "Cancel Download",
                           systemImage: "trash", role: .destructive) {
                        downloads.delete(recordID: record.id)
                    }
                } else {
                    Button("Download", systemImage: "arrow.down.circle") { actions.download(item) }
                }
            } else if item.kind == .season {
                Button("Download Season", systemImage: "arrow.down.circle") { actions.download(item) }
            }
        }
    }
}

private struct IOSPlexMenuPreview: View {
    let item: MediaItem

    var body: some View {
        if item.kind == .episode {
            IOSItemArtwork(item: item, kind: .thumb, width: 320, aspectRatio: 16 / 9)
                .frame(width: 320, height: 180)
        } else {
            IOSItemArtwork(item: item, kind: .poster, width: 240, aspectRatio: 2 / 3)
                .frame(width: 240, height: 360)
        }
    }
}
