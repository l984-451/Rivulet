// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FolderLibraryViewController.swift
//  Rivulet
//
//  A library browsed by folder: a stack of levels. Opening a folder puts its
//  level on top and hides the one beneath; Menu steps back.
//

import UIKit

@MainActor
final class FolderLibraryViewController: UIViewController {
    private let libraryTitle: String
    private let source: FolderListing.Source
    private var stack: [FolderListViewController] = []
    /// The root's View menu, rebuilt each time its button takes focus.
    private let viewMenu: (() -> UIMenu?)?

    init(title: String, viewMenu: (() -> UIMenu?)? = nil, source: @escaping FolderListing.Source) {
        self.libraryTitle = title
        self.viewMenu = viewMenu
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    /// A Plex section by folder.
    convenience init(plex library: PlexLibrary, viewMenu: (() -> UIMenu?)? = nil) {
        self.init(title: library.title, viewMenu: viewMenu) {
            guard let provider = MediaProviderRegistry.shared.plexProvider,
                  let folders = provider as? any FolderProvider else { return nil }
            return (folders, PlexMediaMapper.library(library, providerID: provider.id))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        push(folder: nil, title: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        MenuPressInterceptor.register(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        MenuPressInterceptor.resign(self)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { stack.last.map { [$0] } ?? [] }

    /// The library the root's Shuffle plays, all of it, when it is a video library.
    static func shuffleLibrary(from source: FolderListing.Source) -> MediaLibrary? {
        source().flatMap { $0.1.canShuffle ? $0.1 : nil }
    }

    private func push(folder: MediaItemRef?, title: String?) {
        let source = source
        let level = FolderListViewController(libraryTitle: libraryTitle, folderTitle: title,
                                             listing: FolderListing(folder: folder, source: source),
                                             viewMenu: folder == nil ? viewMenu : nil,
                                             shuffleLibrary: folder == nil ? { Self.shuffleLibrary(from: source) } : nil)
        level.onOpenFolder = { [weak self] in self?.push(folder: $0, title: $1) }
        addChild(level)
        level.view.frame = view.bounds
        level.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(level.view)
        level.didMove(toParent: self)
        // Hidden, so the focus engine cannot reach the level beneath.
        stack.last?.view.isHidden = true
        stack.append(level)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

// MARK: - Menu

extension FolderLibraryViewController: MenuBackHandling {
    /// Menu below a list's first row returns to it; then it steps back one level.
    /// At the root's top, or with focus anywhere else, it is not ours.
    func handleMenuBack() -> Bool {
        guard let top = stack.last,
              let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
              focused.isDescendant(of: view) else { return false }
        if top.returnToTop() { return true }
        guard stack.count > 1 else { return false }
        stack.removeLast()
        stack.last?.view.isHidden = false
        top.view.isHidden = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // Not here: removing a view from the pressed responder chain cancels the
        // press, which re-enters the interceptor that is asking us.
        DispatchQueue.main.async {
            top.willMove(toParent: nil)
            top.view.removeFromSuperview()
            top.removeFromParent()
        }
        return true
    }
}
