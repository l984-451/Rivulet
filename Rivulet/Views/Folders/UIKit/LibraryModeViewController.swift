// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryModeViewController.swift
//  Rivulet
//
//  A video library tab: its title grid or its folders, swapped in place.
//  The choice is saved per library and profile.
//

import UIKit

@MainActor
final class LibraryModeViewController: UIViewController {
    private let libraryTitle: String
    private let settingsKey: String
    private let defaultMode: LibraryViewMode
    private let makeGrid: () -> PlexHomeViewController
    private let folderSource: FolderListing.Source
    private var grid: PlexHomeViewController?
    private var folders: FolderLibraryViewController?
    private var active: UIViewController?

    init(title: String, settingsKey: String, defaultMode: LibraryViewMode,
         makeGrid: @escaping () -> PlexHomeViewController, folderSource: @escaping FolderListing.Source) {
        self.libraryTitle = title
        self.settingsKey = settingsKey
        self.defaultMode = defaultMode
        self.makeGrid = makeGrid
        self.folderSource = folderSource
        super.init(nibName: nil, bundle: nil)
    }

    /// A Plex movie or show section. One with no metadata agent opens on its folders.
    convenience init(plex library: PlexLibrary) {
        self.init(title: library.title, settingsKey: library.key,
                  defaultMode: library.hasNoMetadataAgent ? .folders : .titles,
                  makeGrid: { PlexHomeViewController(mode: .library(key: library.key, title: library.title)) },
                  folderSource: {
                      guard let provider = MediaProviderRegistry.shared.plexProvider,
                            let folders = provider as? any FolderProvider else { return nil }
                      return (folders, PlexMediaMapper.library(library, providerID: provider.id))
                  })
    }

    /// A library through its provider. One with no metadata opens on its folders.
    convenience init(provider library: MediaLibrary) {
        self.init(title: library.title, settingsKey: library.settingsKey,
                  defaultMode: library.browsesByFolder ? .folders : .titles,
                  makeGrid: {
                      PlexHomeViewController(mode: .library(key: library.settingsKey, title: library.title),
                                             providerLibrary: library)
                  },
                  folderSource: FolderListing.source(for: library))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let mode = LibrarySettingsManager.shared.viewMode(settingsKey, default: defaultMode)
        if mode != .folders { gridPage().setGridShowsCollections(mode == .collections) }
        show(byFolder: mode == .folders)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { active.map { [$0] } ?? [] }

    /// Both pages are kept once made, so switching back keeps place and contents.
    private func page(byFolder: Bool) -> UIViewController {
        guard byFolder else { return gridPage() }
        if let folders { return folders }
        let page = FolderLibraryViewController(title: libraryTitle, viewMenu: { [weak self] in
            guard let self else { return nil }
            // Collections only once the grid has seen some.
            let modes: [LibraryViewMode] = grid?.hasCollections == true
                ? [.titles, .collections, .folders] : [.titles, .folders]
            return LibraryViewMode.menu(modes, current: .folders) { [weak self] in self?.select($0) }
        }, source: folderSource)
        folders = page
        return page
    }

    private func gridPage() -> PlexHomeViewController {
        if let grid { return grid }
        let page = makeGrid()
        page.onSelectViewMode = { [weak self] in self?.select($0) }
        grid = page
        return page
    }

    private func select(_ mode: LibraryViewMode) {
        LibrarySettingsManager.shared.setViewMode(mode, for: settingsKey)
        // Next turn: the menu's button is in the page being removed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if mode != .folders { gridPage().setGridShowsCollections(mode == .collections) }
            guard (mode == .folders) != (active === folders) else { return }
            show(byFolder: mode == .folders)
            NotificationCenter.default.post(name: .tabContentReplaced, object: self)
        }
    }

    private func show(byFolder: Bool) {
        let next = page(byFolder: byFolder)
        guard next !== active else { return }
        let previous = active
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        active = next
        // Focus is still in the old page, so this request is ours to make.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        previous?.willMove(toParent: nil)
        previous?.view.removeFromSuperview()
        previous?.removeFromParent()
    }
}
