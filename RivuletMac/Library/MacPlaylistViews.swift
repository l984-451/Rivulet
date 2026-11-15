// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// One server's video playlists. Parity source: RivuletiOS/Plex/Library/IOSPlexPlaylistViews.swift.
struct MacPlaylistsView: View {
    let providerID: String
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.macActions) private var actions
    @Environment(\.macOpen) private var open
    @State private var editing = MacPlaylistEditState()
    @State private var pendingStart: MacPlaylistStart?

    var body: some View {
        let lists = browse.playlists(providerID: providerID)
        Group {
            if lists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "list.and.film",
                                       description: Text("Add titles from their menu with Add to Playlist."))
            } else {
                List(lists, id: \.item.ref) { playlist in
                    Button { open(.playlist(playlist)) } label: { MacPlaylistRow(playlist: playlist) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(playlist) }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(browse.labels.title(String(localized: "Playlists"), providerID: providerID))
        .macPageRefresh { Task { await browse.refreshPlaylists() } }
        .playlistEditAlerts($editing)
        .playlistContinueDialog($pendingStart, actions: actions)
    }

    @ViewBuilder
    private func menu(_ playlist: MediaPlaylist) -> some View {
        ForEach(PlaylistRules.playlistActions(isSmart: playlist.isSmart), id: \.self) { action in
            switch action {
            // Play shows only where `IOSPlaybackGate` allows it.
            case .play:
                if IOSPlaybackGate.canPlay(playlist.item.ref) {
                    Button("Play", systemImage: "play.fill") { play(playlist, shuffled: false) }
                }
            case .shuffle:
                if IOSPlaybackGate.canPlay(playlist.item.ref) {
                    Button("Shuffle", systemImage: "shuffle") { play(playlist, shuffled: true) }
                }
            case .rename: Button("Rename", systemImage: "pencil") { editing.beginRename(playlist) }
            case .delete: Button("Delete", systemImage: "trash", role: .destructive) { editing.deleting = playlist }
            }
        }
    }

    private func play(_ playlist: MediaPlaylist, shuffled: Bool) {
        Task {
            do {
                let items = try await browse.playlistContents(playlist).entries.map(\.item)
                pendingStart = MacPlaylistStart.begin(items, title: playlist.item.title, shuffled: shuffled, actions: actions)
            } catch let error where isCancellationError(error) {
            } catch {
                editing.failure = error.localizedDescription
            }
        }
    }
}

private struct MacPlaylistRow: View {
    let playlist: MediaPlaylist
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    private let artWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 14) {
            MacImage(url: browse.imageURL(playlist.item.artwork.backdrop ?? playlist.item.artwork.poster,
                                          providerID: playlist.item.ref.providerID, width: Int(artWidth * displayScale),
                                          height: Int(artWidth * displayScale * 9 / 16)))
                .frame(width: artWidth, height: artWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.item.title.isEmpty ? String(localized: "Untitled") : playlist.item.title)
                    .font(.headline).lineLimit(2)
                if let info = playlist.info {
                    Text(info).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private extension MediaPlaylist {
    /// "3 hr 10 min": the list's length, when the server says. Item counts are not offered: Plex's disagrees with its rows.
    var info: String? {
        item.runtime.flatMap { seconds in
            seconds > 0 ? Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) : nil
        }
    }
}

/// A playlist's rows with Play and Shuffle. A regular list also edits: drag moves rows, the menu removes,
/// renames or deletes. A smart list is the server's rules. Pushed by `MacRoute.playlist`.
struct MacPlaylistView: View {
    let playlist: MediaPlaylist
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.macActions) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PlaylistEntry] = []
    /// Smart lists are the server's rules; a refresh reads it from the contents.
    @State private var smartContents: Bool?
    @State private var error: String?
    @State private var loadedRevision: String?
    @State private var pendingStart: MacPlaylistStart?
    @State private var editing = MacPlaylistEditState()
    @State private var selection: String?

    /// The listed copy, so a rename shows; the pushed one once the list no longer has it.
    private var current: MediaPlaylist {
        browse.playlists(providerID: playlist.item.ref.providerID).first { $0.item.ref == playlist.item.ref } ?? playlist
    }
    private var isSmart: Bool { smartContents ?? current.isSmart }
    private var canPlay: Bool { IOSPlaybackGate.canPlay(playlist.item.ref) }
    private var items: [MediaItem] { entries.map(\.item) }

    var body: some View {
        Group {
            if entries.isEmpty, let error {
                MacErrorView(title: "Couldn't Load Playlist", message: error) { await reload() }
            } else if entries.isEmpty, loadedRevision != nil {
                ContentUnavailableView("Empty Playlist", systemImage: "list.and.film")
            } else if entries.isEmpty {
                ProgressView()
            } else {
                List(selection: $selection) {
                    ForEach(Array(entries.enumerated()), id: \.element.entryID) { index, entry in
                        MacPlaylistItemRow(item: entry.item, canRemove: !isSmart, canPlay: canPlay,
                                           canMoveUp: !isSmart && index > 0,
                                           canMoveDown: !isSmart && index < entries.count - 1,
                                           playFromHere: { playFromHere(index) },
                                           remove: { remove(at: IndexSet(integer: index)) },
                                           moveUp: { move(from: IndexSet(integer: index), to: index - 1) },
                                           moveDown: { move(from: IndexSet(integer: index), to: index + 2) })
                            .tag(entry.entryID)
                    }
                    .onMove(perform: isSmart ? nil : { (from: IndexSet, to: Int) in move(from: from, to: to) })
                    .onDelete(perform: isSmart ? nil : { (offsets: IndexSet) in remove(at: offsets) })
                }
                .listStyle(.inset)
                // Delete removes the selected row, as in Finder's lists.
                .onDeleteCommand {
                    guard !isSmart, let selection, let index = entries.firstIndex(where: { $0.entryID == selection }) else { return }
                    remove(at: IndexSet(integer: index))
                }
            }
        }
        .navigationTitle(current.item.title.isEmpty ? String(localized: "Playlist") : current.item.title)
        .toolbar {
            if canPlay, !entries.isEmpty {
                ToolbarItemGroup {
                    Button("Play", systemImage: "play.fill") { start(shuffled: false) }
                    Button("Shuffle", systemImage: "shuffle") { start(shuffled: true) }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }
            ToolbarItem {
                Menu("More", systemImage: "ellipsis") {
                    if !isSmart {
                        Button("Rename", systemImage: "pencil") { editing.beginRename(current) }
                    }
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) { editing.deleting = current }
                }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
            }
        }
        .macPageRefresh { Task { await reload() } }
        .playlistEditAlerts($editing, onDeleted: { dismiss() })
        .playlistContinueDialog($pendingStart, actions: actions)
        .task(id: revision) {
            guard loadedRevision != revision else { return }
            await reload()
        }
    }

    /// Watch state, or an add from another page (the listed count changes).
    private var revision: String { "\(browse.watchStateRevision)|\(browse.playlists(providerID: playlist.item.ref.providerID).count)" }

    private func start(shuffled: Bool) {
        pendingStart = MacPlaylistStart.begin(items, title: current.item.title, shuffled: shuffled, actions: actions)
    }

    /// Starts on the picked row itself: never the list's Continue prompt.
    private func playFromHere(_ index: Int) {
        if let queue = PlayQueue(entries: items, startingAt: index) { actions.playQueue(queue) }
    }

    /// Optimistic: the row moves at once, and a refusal reloads the server's order.
    private func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first, destination >= 0, destination <= entries.count else { return }
        let before = entries
        let landed = destination > from ? destination - 1 : destination
        guard landed != from else { return }
        entries.move(fromOffsets: source, toOffset: destination)
        let entry = before[from]
        Task {
            do {
                try await browse.movePlaylistEntry(current, entry: entry, toIndex: landed, in: before)
            } catch {
                editing.failure = error.localizedDescription
                await reload()
            }
        }
    }

    private func remove(at offsets: IndexSet) {
        let removed = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
        Task {
            do {
                for entry in removed {
                    try await browse.removeFromPlaylist(current, entry: entry)
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
            let contents = try await browse.playlistContents(playlist)
            entries = contents.entries
            smartContents = contents.isSmart
            error = nil
            loadedRevision = revision
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Double-click plays from this row on; the menu also removes or moves it and has the item's own actions.
private struct MacPlaylistItemRow: View {
    let item: MediaItem
    let canRemove: Bool
    let canPlay: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let playFromHere: () -> Void
    let remove: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    @Environment(\.macActions) private var actions
    private let artWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 14) {
            MacItemArtwork(item: item, kind: item.kind == .episode ? .thumb : .backdrop,
                           width: artWidth, aspectRatio: 16 / 9)
                .frame(width: artWidth, height: artWidth * 9 / 16)
                .macWatchState(item)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if actions.preparingID == item.ref.actionKey { ProgressView().controlSize(.small) }
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // A server whose playback is not connected yet opens the row's page instead.
        .onTapGesture(count: 2) { canPlay ? playFromHere() : actions.open(item) }
        .contextMenu {
            if canPlay {
                Button("Play from Here", systemImage: "play.fill", action: playFromHere)
            }
            if canMoveUp { Button("Move Up", systemImage: "arrow.up", action: moveUp) }
            if canMoveDown { Button("Move Down", systemImage: "arrow.down", action: moveDown) }
            if canRemove {
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive, action: remove)
            }
            Section { MacItemMenu(item: item, showsPlay: false, showsDetails: true) }
        }
    }
}

/// Play from the top, held while the list asks where to start.
struct MacPlaylistStart {
    let title: String
    let items: [MediaItem]
    let resume: Int

    /// Shuffled, or from the top: nil when it played at once, else the Continue choice to show.
    static func begin(_ items: [MediaItem], title: String?, shuffled: Bool, actions: MacActions) -> MacPlaylistStart? {
        if shuffled {
            if let queue = PlayQueue.shuffled(items) { actions.playQueue(queue) }
            return nil
        }
        if let resume = PlayQueue.continuePoint(in: items, isPlayed: \.countsAsWatched, isStarted: \.isInProgress), resume > 0 {
            return MacPlaylistStart(title: title ?? String(localized: "Playlist"), items: items, resume: resume)
        }
        if let queue = PlayQueue(entries: items, startingAt: 0) { actions.playQueue(queue) }
        return nil
    }
}

/// Rename and delete prompts, and edit failures.
struct MacPlaylistEditState {
    var renaming: MediaPlaylist?
    var renameText = ""
    var deleting: MediaPlaylist?
    var failure: String?

    mutating func beginRename(_ playlist: MediaPlaylist) {
        renameText = playlist.item.title
        renaming = playlist
    }
}

extension View {
    fileprivate func playlistContinueDialog(_ start: Binding<MacPlaylistStart?>, actions: MacActions) -> some View {
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

    fileprivate func playlistEditAlerts(_ state: Binding<MacPlaylistEditState>,
                                        onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(MacPlaylistEditAlerts(state: state, onDeleted: onDeleted))
    }
}

private struct MacPlaylistEditAlerts: ViewModifier {
    @Binding var state: MacPlaylistEditState
    let onDeleted: () -> Void
    @EnvironmentObject private var browse: BrowseStore

    func body(content: Content) -> some View {
        content
            .alert("Rename Playlist", isPresented: Binding(
                get: { state.renaming != nil }, set: { if !$0 { state.renaming = nil } }
            ), presenting: state.renaming) { playlist in
                TextField("Playlist Name", text: $state.renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let name = state.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, name != playlist.item.title else { return }
                    run { try await browse.renamePlaylist(playlist, to: name) }
                }
            }
            .alert(state.deleting.map { String(localized: "Delete \u{201C}\($0.item.title)\u{201D}?") } ?? "",
                   isPresented: Binding(get: { state.deleting != nil }, set: { if !$0 { state.deleting = nil } }),
                   presenting: state.deleting) { playlist in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    run {
                        try await browse.deletePlaylist(playlist)
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
