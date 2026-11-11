// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoLibraryViewController.swift
//  Rivulet
//
//  A photo library's tab: a stack of grids, one per folder level. Opening a
//  folder puts its grid on top and hides the one beneath; Menu steps back.
//

import UIKit

@MainActor
final class PhotoLibraryViewController: UIViewController {
    private let libraryTitle: String
    private let source: PhotoListing.Source
    private var stack: [PhotoGridViewController] = []

    init(title: String, source: @escaping PhotoListing.Source) {
        self.libraryTitle = title
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        push(folder: nil, title: libraryTitle)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MenuPressInterceptor.register(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        MenuPressInterceptor.resign(self)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { stack.last.map { [$0] } ?? [] }

    private func open(_ memory: PhotoMemory) {
        guard memory.kind == .map else { return push(folder: nil, title: memory.title, memory: memory) }
        guard let (provider, library) = source() else { return }
        present(PhotoMapViewController(provider: provider, library: library), animated: true)
    }

    /// `memory` is one of the root's memories, opened as a flat grid with no albums.
    private func push(folder: MediaItemRef?, title: String, memory: PhotoMemory? = nil) {
        let narrowing = memory?.query ?? .default
        // Every level of a library opens on the Sort and Show it was last left on.
        let listing = PhotoListing(folder: folder, query: narrowing, savedQuery: {
            PhotoPreferences.query(for: $0, narrowedBy: narrowing)
        }, source: memory?.source(over: source) ?? source)
        let grid = PhotoGridViewController(title: title, listing: listing)
        grid.onOpenFolder = { [weak self] in self?.push(folder: $0.ref, title: $0.title) }
        if folder == nil, memory == nil {
            grid.onOpenMemory = { [weak self] in self?.open($0) }
        }
        addChild(grid)
        grid.view.frame = view.bounds
        grid.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(grid.view)
        grid.didMove(toParent: self)
        // Hidden, so the focus engine cannot reach the level beneath.
        stack.last?.view.isHidden = true
        stack.append(grid)
        setNeedsFocusUpdate()
    }
}

// MARK: - Menu

extension PhotoLibraryViewController: MenuBackHandling {
    /// Menu inside a folder steps back one level. At the root, or with focus
    /// anywhere else (the sidebar, a viewer presented over the tab), it is not ours.
    func handleMenuBack() -> Bool {
        guard stack.count > 1, let top = stack.last,
              let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
              focused.isDescendant(of: view) else { return false }
        stack.removeLast()
        stack.last?.view.isHidden = false
        stack.last?.syncSavedQuery()
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
