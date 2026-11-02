// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicMenus.swift
//  Rivulet
//
//  Every Music menu, in Apple's order minus what Plex cannot back. Builders
//  return a neutral item list with two renderers: the system `UIMenu` for
//  buttons, and the hand-built tile popup for long press (dead in UIKit on
//  tvOS 26, and a `UIAction` handler cannot be invoked from code).
//

import UIKit

struct MusicMenuItem {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var children: [MusicMenuItem] = []
    var handler: () -> Void = {}

    /// A literal `title` is extracted to the string catalog; a server's text goes through `verbatim:`.
    init(title: String.LocalizationValue, symbol: String, subtitle: String? = nil,
         children: [MusicMenuItem] = [], handler: @escaping () -> Void = {}) {
        self.init(verbatim: String(localized: title), symbol: symbol, subtitle: subtitle, children: children, handler: handler)
    }

    init(verbatim title: String, symbol: String, subtitle: String? = nil,
         children: [MusicMenuItem] = [], handler: @escaping () -> Void = {}) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.children = children
        self.handler = handler
    }
}

@MainActor
enum MusicMenus {
    /// Where a track menu opens: it decides which "Go to" rows make sense.
    enum Screen { case album, playlist, songs, nowPlaying }

    // MARK: - Renderers

    static func uiMenu(_ items: [MusicMenuItem]) -> UIMenu {
        UIMenu(children: items.map { item -> UIMenuElement in
            let image = UIImage(systemName: item.symbol)
            if !item.children.isEmpty {
                return UIMenu(title: item.title, image: image, children: uiMenu(item.children).children)
            }
            return UIAction(title: item.title, subtitle: item.subtitle, image: image) { _ in item.handler() }
        })
    }

    /// Long press: the tile popup beside `sourceFrame`. A row with children
    /// opens a second popup, which works because the first has dismissed.
    static func presentPopup(_ items: [MusicMenuItem], from presenter: UIViewController, sourceFrame: CGRect?,
                             header: TileMenuHeader? = nil) {
        guard !items.isEmpty, presenter.presentedViewController == nil else { return }
        let actions = items.map { item in
            TileMenuAction(verbatim: item.title, systemImage: item.symbol) {
                if item.children.isEmpty {
                    item.handler()
                } else {
                    presentPopup(item.children, from: presenter, sourceFrame: sourceFrame)
                }
            }
        }
        presenter.present(TileMenuPopupViewController(sections: [actions], sourceFrame: sourceFrame, header: header),
                          animated: false)
    }

    // MARK: - Builders

    /// `showsArtist` is false on the artist's own page, where the row would reopen it.
    static func album(_ album: MusicAlbum, showsArtist: Bool = true,
                      navigate: @escaping (MusicNavigationRequest) -> Void) -> [MusicMenuItem] {
        let tracks: TrackSource = { try await registry.provider(for: album.ref)?.tracks(for: album.ref) ?? [] }
        var items = [MusicMenuItem(title: "Play", symbol: "play") { play(tracks) }]
        if showsArtist, let artistRef = album.artistRef {
            items.append(MusicMenuItem(title: "Go to Artist", symbol: "music.microphone") { navigate(.artist(artistRef)) })
        }
        items += addToPlaylist(tracks, on: album.ref.providerID)
        items.append(MusicMenuItem(title: "Shuffle", symbol: "shuffle") { play(tracks, shuffled: true) })
        return items + queueing(tracks)
    }

    static func playlist(_ playlist: MusicPlaylist) -> [MusicMenuItem] {
        let tracks: TrackSource = { try await playlistTracks(playlist) }
        return [
            MusicMenuItem(title: "Play", symbol: "play") { play(tracks) },
            MusicMenuItem(title: "Shuffle", symbol: "shuffle") {
                play({ try await playlistTracks(playlist, from: shuffleOffset(count: playlist.trackCount)) },
                     shuffled: true)
            },
        ] + queueing(tracks)
    }

    static func artist(_ artist: MusicArtist) -> [MusicMenuItem] {
        let tracks: TrackSource = { try await registry.provider(for: artist.ref)?.allTracks(for: artist.ref) ?? [] }
        return [
            MusicMenuItem(title: "Play", symbol: "play") { play(tracks) },
            MusicMenuItem(title: "Shuffle", symbol: "shuffle") { play(tracks, shuffled: true) },
        ] + queueing(tracks)
    }

    static func track(_ track: MusicTrack, screen: Screen,
                      navigate: @escaping (MusicNavigationRequest) -> Void) -> [MusicMenuItem] {
        let tracks: TrackSource = { [track] }
        var goTo: [MusicMenuItem] = []
        if screen != .album, let albumRef = track.albumRef {
            goTo.append(MusicMenuItem(title: "Go to Album", symbol: "square.stack") { navigate(.album(albumRef)) })
        }
        if let artistRef = track.artistRef {
            goTo.append(MusicMenuItem(title: "Go to Artist", symbol: "music.microphone") { navigate(.artist(artistRef)) })
        }
        // Now Playing's More menu: Apple's order, and the queue rows mean nothing there.
        if screen == .nowPlaying { return addToPlaylist(tracks, on: track.ref.providerID) + goTo }
        let favorite = MusicQueue.shared.isFavorite(track)
        // Apple sorts a track menu by action rank: go-to rows, playlist, queue, favorite.
        return goTo.reversed() + addToPlaylist(tracks, on: track.ref.providerID) + queueing(tracks) + [
            MusicMenuItem(title: favorite ? "Undo Favorite" : "Favorite", symbol: favorite ? "star.slash" : "star") {
                MusicQueue.shared.toggleFavorite(track)
            },
        ]
    }

    // MARK: - Shared rows

    typealias TrackSource = @MainActor () async throws -> [MusicTrack]

    /// With nothing playing there is no queue to add to, so both rows start the tracks.
    private static func queueing(_ tracks: @escaping TrackSource) -> [MusicMenuItem] {
        let queue = MusicQueue.shared
        return [
            MusicMenuItem(title: "Play Next", symbol: "text.line.first.and.arrowtriangle.forward") {
                run(tracks) { queue.isActive ? queue.addNext(tracks: $0) : queue.playAlbum(tracks: $0) }
            },
            // Apple names the track the addition will follow.
            MusicMenuItem(title: "Play After", symbol: "text.line.last.and.arrowtriangle.forward",
                          subtitle: queue.queue.last?.title ?? queue.currentTrack?.title) {
                run(tracks) { queue.isActive ? queue.addToEnd(tracks: $0) : queue.playAlbum(tracks: $0) }
            },
        ]
    }

    /// New Playlist first, then only the tracks' own server's playlists: a playlist holds one server's items.
    private static func addToPlaylist(_ tracks: @escaping TrackSource, on providerID: String) -> [MusicMenuItem] {
        let playlists = playlists.filter { $0.ref.providerID == providerID }
        let newPlaylist = MusicMenuItem(title: "New Playlist", symbol: "plus") {
            // Resolved after the system menu has closed: nil = the window's top.
            PlaylistMenus.presentNameEntry(title: "New Playlist", initialText: "", from: nil) { name in
                run(tracks) { tracks in
                    Task {
                        do {
                            guard let created = try await registry.provider(for: providerID)?
                                .createPlaylist(title: name, seededWith: tracks.map(\.ref)) else { return }
                            if loaded?.generation == registry.generation { loaded?.playlists.append(created) }
                        } catch {
                            MusicPresenter.reportFailure(error)
                        }
                    }
                }
            }
        }
        let children = [newPlaylist] + playlists.map { playlist in
            MusicMenuItem(verbatim: playlist.title, symbol: "music.note.list") {
                run(tracks) { tracks in
                    Task {
                        do {
                            try await registry.provider(for: playlist.ref)?
                                .addToPlaylist(playlist.ref, tracks: tracks.map(\.ref))
                        } catch {
                            MusicPresenter.reportFailure(error)
                        }
                    }
                }
            }
        }
        return [MusicMenuItem(title: "Add to Playlist", symbol: "text.badge.plus", children: children)]
    }

    /// The Play or Shuffle still fetching its tracks. A newer one replaces it and a
    /// closing page cancels it, so Now Playing never opens over where the user went next.
    private static var pendingPlay: Task<Void, Never>?

    /// Every Play and Shuffle on a Music page, button or menu row.
    static func play(_ tracks: @escaping TrackSource, shuffled: Bool = false, startingAt index: Int = 0) {
        pendingPlay?.cancel()
        pendingPlay = run(tracks) { tracks in
            if shuffled {
                MusicQueue.shared.playShuffled(tracks: tracks)
            } else {
                MusicQueue.shared.playAlbum(tracks: tracks, startingAt: index)
            }
        }
    }

    static func cancelPendingPlay() { pendingPlay?.cancel() }

    @discardableResult
    private static func run(_ tracks: @escaping TrackSource,
                            _ then: @escaping @MainActor ([MusicTrack]) -> Void) -> Task<Void, Never> {
        Task {
            do {
                let tracks = try await tracks()
                guard !Task.isCancelled, !tracks.isEmpty else { return }
                then(tracks)
            } catch {
                if !Task.isCancelled { MusicPresenter.reportFailure(error) }
            }
        }
    }

    private static var registry: MusicProviderRegistry { .shared }

    // MARK: - Data

    private static var loaded: (generation: Int, playlists: [MusicPlaylist], complete: Bool)?

    /// Regular playlists for the "Add to Playlist" submenu. Smart ones reject tracks.
    /// Empty again after a sign-out or a server or profile switch: they belong to the account.
    static var playlists: [MusicPlaylist] {
        loaded?.generation == MusicProviderRegistry.shared.generation ? loaded?.playlists ?? [] : []
    }

    /// Fills `playlists` once per account; callers rebuild their menu when it returns.
    static func loadPlaylists() async {
        let generation = MusicProviderRegistry.shared.generation
        guard loaded?.generation != generation || loaded?.complete == false else { return }
        var found: [MusicPlaylist] = []
        var complete = true
        // Signed-in servers only: an entry kept for an old address would fail the lot or list twice.
        for provider in MusicProviderRegistry.shared.signedInProviders {
            do {
                for library in try await provider.musicLibraries() {
                    // The same playlist can come back for more than one library.
                    for playlist in try await provider.playlists(in: library, sort: .title)
                    where !playlist.isSmart && !found.contains(playlist) {
                        found.append(playlist)
                    }
                }
            } catch {
                // A failed server is not "no playlists": the next page asks again.
                complete = false
            }
        }
        guard !Task.isCancelled else { return }
        loaded = (generation, found, complete)
    }

    // ponytail: a queue takes at most 2000 playlist tracks (four requests), so a longer
    // playlist plays a window of itself. Page the queue itself if that ever matters.
    static let playlistCap = 2000

    /// A playlist's tracks for Play, Shuffle and the queue rows, from `offset` on.
    static func playlistTracks(_ playlist: MusicPlaylist, from offset: Int = 0) async throws -> [MusicTrack] {
        guard let provider = registry.provider(for: playlist.ref) else { return [] }
        var tracks: [MusicTrack] = []
        var page: Page? = Page(offset: offset, limit: 500)
        while let next = page, tracks.count < playlistCap {
            let result = try await provider.tracks(inPlaylist: playlist.ref, page: next)
            tracks += result.items
            page = result.nextPage
        }
        return tracks
    }

    /// Where a shuffle starts reading a playlist longer than the cap: anywhere, not always the top.
    static func shuffleOffset(count: Int) -> Int {
        Int.random(in: 0...max(0, count - playlistCap))
    }
}
