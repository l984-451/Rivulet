// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The Search tab. The results page is the UISearchController's `searchResultsController`, so the
// keyboard and results share one focus hierarchy. Do not use `.searchable`: focus cannot cross the
// search presentation boundary.

import UIKit

final class SearchContainerViewController: UIViewController {
    /// The results surface. Also the whole visible page: prompt/recents when
    /// the query is empty, inline states, and the grouped result grids.
    private let results = PlexHomeViewController(mode: .search)
    private let searchController: UISearchController
    private let searchContainer: UISearchContainerViewController


    /// Reports whether a music detail covers the page. Delivered async because callers can run
    /// inside a SwiftUI update, where publishing observable state is not allowed.
    var onNestedChange: ((Bool) -> Void)?

    private func reportNested(_ isNested: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onNestedChange?(isNested) }
    }

    init() {
        // The page is the results controller so the search controller can collapse its keyboard
        // when focus moves into the results. Do not mount it as our own child: that loses the collapse.
        searchController = UISearchController(searchResultsController: results)
        searchContainer = UISearchContainerViewController(searchController: searchController)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        searchController.searchResultsUpdater = self
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = String(localized: "Search your libraries")
        // Otherwise a dimming view covers the results, which are the whole page, until the
        // first query. `showsSearchResultsController` is unavailable on tvOS.
        searchController.obscuresBackgroundDuringPresentation = false

        // A recents pill sets the query from inside the results controller;
        // mirror it back into the field so the two never disagree.
        results.onSearchQueryChangedByController = { [weak self] query in
            guard let self, self.searchController.searchBar.text != query else { return }
            self.searchController.searchBar.text = query
        }
        // Search is the ONLY surface that fires this — home, discover and
        // library never route a music tap through it.
        results.onSelectMusic = { [weak self] meta in
            self?.presentMusicDetail(meta)
        }

        // No safe-area inset for the sidebar pill (#292): the search controller restores its
        // collapsed chrome without it and clips the keyboard. `TVSidebarView` hides the pill instead.
        addChild(searchContainer)
        searchContainer.view.frame = view.bounds
        searchContainer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(searchContainer.view)
        searchContainer.didMove(toParent: self)
    }


    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard preferredHalf == .keyboard else {
            // Coming back from outside the page (the sidebar): the tile focus left.
            // The page has not scrolled meanwhile, so the view is still that tile.
            if let tile = lastResultsFocus, tile.window != nil,
               let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
               !focused.isDescendant(of: view) {
                return [tile, results]
            }
            return [results]
        }
        // Order matters. The container alone can resolve back down into the results; the bar
        // alone never creates the keyboard on first mount, which only the container does.
        return [searchController.searchBar, searchContainer]
    }

    // MARK: - Music hand-off

    /// Artists and albums open the Music pages; tracks play directly and are
    /// intercepted in the results controller, never reaching here.
    private func presentMusicDetail(_ meta: PlexMetadata) {
        guard meta.type == "artist" || meta.type == "album" else { return }
        if MusicPresenter.showDetail(for: meta, from: self) { reportNested(true) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentedViewController == nil { reportNested(false) }
    }

    /// Leaving the tab (the shell caches this controller) resets the query and focus. Skipped while
    /// a music detail covers the page, so returning from an album keeps the user's place.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard presentedViewController == nil else { return }
        preferredHalf = .keyboard
        guard searchController.searchBar.text?.isEmpty == false else { return }
        searchController.searchBar.text = nil
        // Assigning `text` does not call the delegate, so the page has to be
        // told itself or it keeps rendering the previous results.
        results.updateSearchQuery("")
    }

    // MARK: - Keyboard ⇄ results hand-off

    /// Which half of the page the next focus REQUEST should aim at. Written by
    /// the press hand-off below, and by `didUpdateFocus` for the engine's own moves.
    private enum Half { case keyboard, results }
    private var preferredHalf: Half = .keyboard
    private weak var lastResultsFocus: UIView?

    /// Follow the engine's own moves, so Right out of the sidebar returns to
    /// the half focus left. Focus leaving the page (the sidebar) changes nothing.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView, next.isDescendant(of: view) else { return }
        let inResults = next.isDescendant(of: results.view)
        preferredHalf = inResults ? .results : .keyboard
        if inResults { lastResultsFocus = next }
    }

    /// Re-expands the collapsed keyboard. The search controller grows its chrome back only when the
    /// field becomes first responder; focus alone leaves it collapsed with no keys to focus.
    private func reopenKeyboard() {
        // Scroll the page back before the keyboard opens, so the two move together; the search
        // controller leaves it scrolled under the keyboard otherwise.
        results.animateToContentTop()
        guard !searchController.searchBar.isFirstResponder else { return }
        searchController.searchBar.becomeFirstResponder()
    }

    /// Moves Down out of the keyboard and Up out of the results' top row, from presses the engine
    /// declined. Not a `UIFocusGuide`: the search controller owns the layout, so there is no frame to
    /// pin one to. Gated on where focus is, not on `preferredHalf`.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let types = Set(presses.map(\.type))
        // Read-and-clear on EVERY arrow, so the flag never carries over from an
        // earlier press and makes the next one think a move happened.
        let engineMoved = results.consumeEngineMovedFocus()
        if types.contains(.downArrow), !focusIsInResults {
            rescue(to: .results)
        } else if types.contains(.upArrow),
                  // Fall back to the last row focus was in: when the engine
                  // jumps straight out to the keyboard it does so BEFORE this
                  // runs, and the live section is already nil by now.
                  let from = results.focusedSectionForHandoff ?? results.lastFocusedSection {
            correctUpward(from: from, engineMoved: engineMoved)
        }
        // Enqueued LAST so it runs after the engine's move and after any rescue
        // above. The results page cannot be trusted to scroll itself: see
        // `revealFocusedRowIfNeeded`.
        if types.contains(.upArrow) || types.contains(.downArrow) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.results.revealFocusedRowIfNeeded()
            }
        }
        super.pressesBegan(presses, with: event)
    }

    /// Up out of a results row, judged by the destination. The engine can skip to the keyboard
    /// when the row above has scrolled off screen, so a handled press can still be wrong.
    private func correctUpward(from section: Int, engineMoved: Bool) {
        let before = UIFocusSystem.focusSystem(for: view)?.focusedItem
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // The engine can move before the press arrives (`engineMoved`) or after it (identity
            // check); either alone misreads one ordering and moves an extra row.
            let movedAfter = UIFocusSystem.focusSystem(for: self.view)?.focusedItem !== before
            let moved = engineMoved || movedAfter
            let landedInPage = self.results.focusedSectionForHandoff != nil

            if moved {
                // Its row-to-row moves are right; the only choice it gets wrong
                // is leaving for the keyboard while a row above was available.
                guard !landedInPage else { return }
                guard section > 0, self.results.focusRow(section - 1) else {
                    // Genuinely left from the top row. Focus is on the field but
                    // the chrome is still collapsed, so grow it back or the
                    // keyboard stays half off screen.
                    self.preferredHalf = .keyboard
                    self.reopenKeyboard()
                    return
                }
                // Re-ask from here: `results` no longer contains focus, so its own request was
                // ignored, but the one-shot target it set survives.
                self.move(to: .results)
                return
            }

            // Declined: nothing above was on screen to take focus. From the top
            // row that is the collapsed keyboard, which the engine will not
            // focus until it is back; below it, a row scrolled out of view.
            guard section > 0, self.results.focusRow(section - 1) else {
                self.move(to: .keyboard)
                return
            }
            self.move(to: .results)
        }
    }

    private func rescue(to half: Half) {
        let before = UIFocusSystem.focusSystem(for: view)?.focusedItem
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  UIFocusSystem.focusSystem(for: self.view)?.focusedItem === before
            else { return }
            // The page has to be scrolled to the top and its cell realized
            // before the request, or there is nothing for focus to land on.
            if half == .results { self.results.aimFocusAtTopRow() }
            self.move(to: half)
        }
    }

    private func move(to half: Half) {
        preferredHalf = half
        if half == .keyboard { reopenKeyboard() }
        // Requested here, the nearest environment containing both halves; `setNeedsFocusUpdate()`
        // is ignored unless the asker contains focus. Disabling interaction on `results` would drop
        // it from the focus system and void the request.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private var focusIsInResults: Bool {
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem else { return false }
        var env: UIFocusEnvironment? = focused
        while let current = env {
            if let view = current as? UIView {
                return view.isDescendant(of: results.view)
            }
            if current === results { return true }
            env = current.parentFocusEnvironment
        }
        return false
    }
}

// MARK: - Query plumbing

extension SearchContainerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        results.updateSearchQuery(searchController.searchBar.text ?? "")
    }
}

extension SearchContainerViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        results.submitSearch()
    }
}

extension SearchContainerViewController: SidebarTabReselecting {
    func reselectSidebarTab() {
        move(to: .keyboard)
    }
}
