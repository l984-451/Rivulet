// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicLibraryViewController.swift
//  Rivulet
//
//  The Music library tab: Apple Music's Library on tvOS 26 without its top
//  tab bar. A category sidebar (x 0..400) beside one browse pane (x 400..1920),
//  everything shifted up to start at y 60.
//

import UIKit
import Combine

/// What the Music sidebar can put in the browse pane.
nonisolated enum MusicLibraryDestination: Hashable, Sendable {
    case recentlyAdded, playlists, artists, albums, songs
    case genre(MusicGenre)

    static let categories: [MusicLibraryDestination] = [.recentlyAdded, .playlists, .artists, .albums, .songs]

    var title: String {
        switch self {
        case .recentlyAdded: String(localized: "Recently Added")
        case .playlists: String(localized: "Playlists")
        case .artists: String(localized: "Artists")
        case .albums: String(localized: "Albums")
        case .songs: String(localized: "Songs")
        case .genre(let genre): genre.title
        }
    }

    /// Genre rows carry no glyph.
    var symbol: String? {
        switch self {
        case .recentlyAdded: "clock"
        case .playlists: "music.note.list"
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genre: nil
        }
    }
}

@MainActor
final class MusicLibraryViewController: UIViewController {
    private let sidebar = MusicLibrarySidebarView()
    private let browse: MusicBrowseViewController
    /// One-shot focus target for Menu from the browse pane.
    private var pendingFocus: UIFocusEnvironment?
    private var queueObserver: AnyCancellable?
    private var genreTask: Task<Void, Never>?

    /// `providerID` nil is the signed-in Plex server.
    init(libraryKey: String, title: String, providerID: String? = nil) {
        browse = MusicBrowseViewController(libraryKey: libraryKey, libraryTitle: title, providerID: providerID)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        let background = MusicChrome.background()
        background.frame = view.bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(background)

        let sidebarWidth = MusicLibrarySidebarView.width
        addChild(browse)
        browse.view.frame = CGRect(x: sidebarWidth, y: 0, width: view.bounds.width - sidebarWidth,
                                   height: view.bounds.height)
        browse.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(browse.view)
        browse.didMove(toParent: self)

        sidebar.frame = CGRect(x: 0, y: 0, width: sidebarWidth, height: view.bounds.height)
        sidebar.autoresizingMask = [.flexibleHeight]
        view.addSubview(sidebar)

        sidebar.onSelect = { [weak self] in self?.browse.show($0) }
        sidebar.onNowPlaying = { MusicQueue.shared.showNowPlaying = true }
        // The row is the only way back into Now Playing, so it lives as long as a track does.
        queueObserver = MusicQueue.shared.$currentTrack
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sidebar.setNowPlayingVisible($0) }
        browse.show(sidebar.selected)
        loadGenres()
        observeAccount()
    }

    private func loadGenres() {
        guard let source = browse.source else { return }
        genreTask?.cancel()
        genreTask = Task { [weak self] in
            guard let genres = try? await source.provider.genres(in: source.library), !Task.isCancelled else { return }
            self?.sidebar.setGenres(genres)
        }
    }

    // Sign-in, server and profile switches rebuild the provider: what is on screen belongs to the
    // old account. A managed profile's own token replaces the owner's about 10s after launch.
    private func observeAccount() {
        withObservationTracking {
            _ = MusicProviderRegistry.shared.generation
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.loadGenres()
                self?.browse.refresh()
                self?.observeAccount()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MenuPressInterceptor.register(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        MenuPressInterceptor.resign(self)
    }

    // MARK: - Focus

    // The focused view itself while focus is inside, so a re-resolution is a no-op.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingFocus { return [pendingFocus] }
        if let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
           focused.isDescendant(of: view) {
            return [focused]
        }
        return [sidebar]
    }
}

// MARK: - Menu

extension MusicLibraryViewController: MenuBackHandling {
    /// Menu in the browse pane steps back to the Music sidebar. Anywhere else
    /// (the sidebar, a page or menu presented over the tab) it is not ours.
    func handleMenuBack() -> Bool {
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
              focused.isDescendant(of: browse.view) else { return false }
        pendingFocus = sidebar
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // Left set, it would pull every later focus update back to the sidebar.
        pendingFocus = nil
        return true
    }
}
