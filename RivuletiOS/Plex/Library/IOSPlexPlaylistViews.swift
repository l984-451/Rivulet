// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct IOSPlexPlaylistRoute: Hashable {
    let playlist: PlexPlaylist
    let serverID: String?
}

/// One server's video playlists.
struct IOSPlexPlaylistsView: View {
    let serverID: String?
    var showsAccount = false
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.plexActions) private var actions
    @State private var editing = IOSPlaylistEditState()
    @State private var pendingStart: IOSPlaylistStart?

    var body: some View {
        let lists = plex.playlists(serverID: serverID)
        Group {
            if lists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "list.and.film",
                                       description: Text("Add titles from their menu with Add to Playlist."))
            } else {
                List(lists, id: \.ratingKey) { playlist in
                    NavigationLink(value: IOSPlexPlaylistRoute(playlist: playlist, serverID: serverID)) {
                        IOSPlexPlaylistRow(playlist: playlist, serverID: serverID)
                    }
                    .contextMenu { menu(playlist) }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { editing.deleting = playlist }
                    }
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await plex.refreshPlaylists() }
        .navigationTitle(plex.displayTitle("Playlists", serverID: serverID))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if showsAccount { IOSAccountToolbarItem() }
        }
        .playlistEditAlerts($editing, serverID: serverID)
        .playlistContinueDialog($pendingStart, actions: actions)
    }

    @ViewBuilder
    private func menu(_ playlist: PlexPlaylist) -> some View {
        ForEach(PlaylistRules.playlistActions(isSmart: playlist.smart == true), id: \.self) { action in
            switch action {
            case .play: Button("Play", systemImage: "play.fill") { play(playlist, shuffled: false) }
            case .shuffle: Button("Shuffle", systemImage: "shuffle") { play(playlist, shuffled: true) }
            case .rename: Button("Rename", systemImage: "pencil") { editing.beginRename(playlist) }
            case .delete: Button("Delete", systemImage: "trash", role: .destructive) { editing.deleting = playlist }
            }
        }
    }

    private func play(_ playlist: PlexPlaylist, shuffled: Bool) {
        Task {
            do {
                let items = try await plex.playlistItems(playlist, serverID: serverID)
                pendingStart = IOSPlaylistStart.begin(items, title: playlist.title, shuffled: shuffled, actions: actions)
            } catch let error where isCancellationError(error) {
            } catch {
                editing.failure = error.localizedDescription
            }
        }
    }
}

private struct IOSPlexPlaylistRow: View {
    let playlist: PlexPlaylist
    let serverID: String?
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .body) private var artWidth: CGFloat = 120

    var body: some View {
        HStack(spacing: 12) {
            IOSPlexImage(url: plex.imageURL(path: playlist.composite, width: Int(artWidth * displayScale),
                                            height: Int(artWidth * displayScale * 9 / 16), serverID: serverID))
                .frame(width: artWidth, height: artWidth * 9 / 16)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title ?? "Untitled").font(.headline).lineLimit(2)
                if let info = playlist.info {
                    Text(info).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private extension PlexPlaylist {
    /// "12 items · 3 hr 10 min"
    var info: String? {
        let count = leafCount.map { "\($0) \($0 == 1 ? "item" : "items")" }
        let length = duration.flatMap { ms in
            Duration.seconds(ms / 1000).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        }
        let parts = [count, length].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A playlist's rows with Play and Shuffle. A regular list also edits: Edit moves and
/// removes rows, the menu renames or deletes. A smart list is the server's rules.
struct IOSPlexPlaylistView: View {
    let route: IOSPlexPlaylistRoute
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.plexActions) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PlexMetadata] = []
    @State private var error: String?
    @State private var loadedRevision: String?
    @State private var pendingStart: IOSPlaylistStart?
    @State private var editing = IOSPlaylistEditState()

    /// The listed copy, so a rename shows; the route's once the list no longer has it.
    private var playlist: PlexPlaylist {
        plex.playlists(serverID: route.serverID).first { $0.ratingKey == route.playlist.ratingKey } ?? route.playlist
    }
    private var isSmart: Bool { playlist.smart == true }

    var body: some View {
        Group {
            if items.isEmpty, let error {
                IOSPlexErrorView(title: "Couldn't Load Playlist", message: error) { await reload() }
            } else if items.isEmpty, loadedRevision != nil {
                ContentUnavailableView("Empty Playlist", systemImage: "list.and.film")
            } else if items.isEmpty {
                ProgressView()
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Button { start(shuffled: false) } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button { start(shuffled: true) } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                        .listRowSeparator(.hidden)
                    }
                    Section {
                        ForEach(Array(items.enumerated()), id: \.element.rowID) { index, item in
                            IOSPlexPlaylistItemRow(item: item, canRemove: !isSmart,
                                                   playFromHere: { playFromHere(index) },
                                                   remove: { remove(at: IndexSet(integer: index)) })
                        }
                        .onMove(perform: isSmart ? nil : { (from: IndexSet, to: Int) in move(from: from, to: to) })
                        .onDelete(perform: isSmart ? nil : { (offsets: IndexSet) in remove(at: offsets) })
                    }
                }
                .listStyle(.plain)
            }
        }
        .refreshable { await reload() }
        .navigationTitle(playlist.title ?? "Playlist")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !isSmart, !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    if !isSmart {
                        Button("Rename", systemImage: "pencil") { editing.beginRename(playlist) }
                    }
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) { editing.deleting = playlist }
                }
            }
        }
        .playlistEditAlerts($editing, serverID: route.serverID, onDeleted: { dismiss() })
        .playlistContinueDialog($pendingStart, actions: actions)
        .task(id: revision) {
            guard loadedRevision != revision else { return }
            await reload()
        }
    }

    /// Watch state, or an add from another page (the listed count changes).
    private var revision: String { "\(plex.watchStateRevision)|\(playlist.leafCount ?? 0)" }

    private func start(shuffled: Bool) {
        pendingStart = IOSPlaylistStart.begin(items, title: playlist.title, shuffled: shuffled, actions: actions)
    }

    /// Starts on the picked row itself: never the list's Continue prompt.
    private func playFromHere(_ index: Int) {
        if let queue = PlayQueue(entries: items, startingAt: index) { actions.playQueue(queue) }
    }

    /// Optimistic: the row moves at once, and a refusal reloads the server's order.
    private func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let before = items
        let landed = destination > from ? destination - 1 : destination
        items.move(fromOffsets: source, toOffset: destination)
        let entry = before[from]
        Task {
            do {
                try await plex.movePlaylistEntry(playlist, entry: entry, toIndex: landed, in: before, serverID: route.serverID)
            } catch {
                editing.failure = error.localizedDescription
                await reload()
            }
        }
    }

    private func remove(at offsets: IndexSet) {
        let removed = offsets.map { items[$0] }
        items.remove(atOffsets: offsets)
        Task {
            do {
                for entry in removed {
                    try await plex.removeFromPlaylist(playlist, entry: entry, serverID: route.serverID)
                }
            } catch {
                editing.failure = error.localizedDescription
                await reload()
            }
        }
    }

    private func reload() async {
        let revision = revision
        do {
            items = try await plex.playlistItems(route.playlist, serverID: route.serverID)
            error = nil
            loadedRevision = revision
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Tapping plays from this row on; the menu also removes it and has the item's own actions.
private struct IOSPlexPlaylistItemRow: View {
    let item: PlexMetadata
    let canRemove: Bool
    let playFromHere: () -> Void
    let remove: () -> Void
    private let watchStamp: [Int]
    @Environment(\.plexActions) private var actions
    @ScaledMetric(relativeTo: .body) private var artWidth: CGFloat = 120

    init(item: PlexMetadata, canRemove: Bool, playFromHere: @escaping () -> Void, remove: @escaping () -> Void) {
        self.item = item
        self.canRemove = canRemove
        self.playFromHere = playFromHere
        self.remove = remove
        watchStamp = item.watchStamp
    }

    var body: some View {
        Button(action: playFromHere) {
            HStack(spacing: 12) {
                IOSPlexArtwork(item: item, kind: item.type == "episode" ? .thumb : .backdrop,
                               width: artWidth, aspectRatio: 16 / 9)
                    .frame(width: artWidth, height: artWidth * 9 / 16)
                    .plexWatchState(item)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if actions.preparingID == item.id { ProgressView().tint(.white) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.headline).lineLimit(2)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let detail = item.timeLeftText ?? item.runtimeText {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play from Here", systemImage: "play.fill", action: playFromHere)
            if canRemove {
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive, action: remove)
            }
            Section { IOSPlexItemMenu(item: item, showsPlay: false, showsDetails: true) }
        }
        .accessibilityHint("Plays the playlist from here")
    }
}

private extension PlexMetadata {
    /// A row's identity: the same title can be in a list twice.
    var rowID: String { playlistItemID.map(String.init) ?? id }
}

// MARK: - Shared flows

/// Play from the top, held while the list asks where to start.
struct IOSPlaylistStart {
    let title: String
    let items: [PlexMetadata]
    let resume: Int

    /// Shuffled, or from the top: nil when it played at once, else the Continue choice to show.
    static func begin(_ items: [PlexMetadata], title: String?, shuffled: Bool, actions: IOSPlexActions) -> IOSPlaylistStart? {
        if shuffled {
            if let queue = PlayQueue.shuffled(items) { actions.playQueue(queue) }
            return nil
        }
        if let resume = PlayQueue.continuePoint(in: items, isPlayed: \.isWatched, isStarted: \.isInProgress), resume > 0 {
            return IOSPlaylistStart(title: title ?? "Playlist", items: items, resume: resume)
        }
        if let queue = PlayQueue(entries: items, startingAt: 0) { actions.playQueue(queue) }
        return nil
    }
}

/// Rename and delete prompts, and edit failures.
struct IOSPlaylistEditState {
    var renaming: PlexPlaylist?
    var renameText = ""
    var deleting: PlexPlaylist?
    var failure: String?

    mutating func beginRename(_ playlist: PlexPlaylist) {
        renameText = playlist.title ?? ""
        renaming = playlist
    }
}

extension View {
    fileprivate func playlistContinueDialog(_ start: Binding<IOSPlaylistStart?>, actions: IOSPlexActions) -> some View {
        confirmationDialog(start.wrappedValue?.title ?? "", isPresented: Binding(
            get: { start.wrappedValue != nil }, set: { if !$0 { start.wrappedValue = nil } }
        ), titleVisibility: .visible, presenting: start.wrappedValue) { pending in
            Button("Continue with \u{201C}\(pending.items[pending.resume].displayTitle)\u{201D}") {
                if let queue = PlayQueue(entries: pending.items, startingAt: pending.resume) { actions.playQueue(queue) }
            }
            Button("Play from Beginning") {
                if let queue = PlayQueue(entries: pending.items, startingAt: 0) { actions.playQueue(queue) }
            }
        }
    }

    fileprivate func playlistEditAlerts(_ state: Binding<IOSPlaylistEditState>, serverID: String?,
                                        onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(IOSPlaylistEditAlerts(state: state, serverID: serverID, onDeleted: onDeleted))
    }
}

private struct IOSPlaylistEditAlerts: ViewModifier {
    @Binding var state: IOSPlaylistEditState
    let serverID: String?
    let onDeleted: () -> Void
    @EnvironmentObject private var plex: IOSPlexSession

    func body(content: Content) -> some View {
        content
            .alert("Rename Playlist", isPresented: Binding(
                get: { state.renaming != nil }, set: { if !$0 { state.renaming = nil } }
            ), presenting: state.renaming) { playlist in
                TextField("Playlist Name", text: $state.renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let name = state.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, name != playlist.title else { return }
                    run { try await plex.renamePlaylist(playlist, to: name, serverID: serverID) }
                }
            }
            .alert(state.deleting.map { "Delete \u{201C}\($0.title ?? "Playlist")\u{201D}?" } ?? "",
                   isPresented: Binding(get: { state.deleting != nil }, set: { if !$0 { state.deleting = nil } }),
                   presenting: state.deleting) { playlist in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    run {
                        try await plex.deletePlaylist(playlist, serverID: serverID)
                        onDeleted()
                    }
                }
            } message: { _ in
                Text("This removes the playlist from your server. The titles stay in your library.")
            }
            .alert("Couldn't Update the Playlist", isPresented: Binding(
                get: { state.failure != nil }, set: { if !$0 { state.failure = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(state.failure ?? "")
            }
    }

    private func run(_ edit: @escaping () async throws -> Void) {
        Task {
            do { try await edit() } catch let error where isCancellationError(error) {} catch {
                state.failure = error.localizedDescription
            }
        }
    }
}
