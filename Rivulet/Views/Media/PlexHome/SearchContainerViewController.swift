// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SearchContainerViewController.swift
//  Rivulet
//
//  The Search tab. `UISearchContainerViewController` owns a UISearchController
//  whose `searchResultsController` is `PlexHomeViewController(mode: .search)`,
//  so the keyboard and the results live in ONE focus hierarchy.
//
//  This replaced the SwiftUI `.searchable` shell, which could not hand focus
//  off at all: a Down press from the keyboard reached the root view controller
//  unhandled and the engine produced no focus update, because the results were
//  on the far side of the search presentation's focus boundary. Submit appeared
//  to work only because dismissing the keyboard tore that environment down and
//  focus fell through to the content underneath. Do not reintroduce
//  `.searchable` here; it is not a styling choice, it is the bug.
//
//  It lives outside `UIKit/` on purpose: the music hand-off hosts a SwiftUI
//  detail, and `Views/**/UIKit/**` is the path the no-SwiftUI lint rule scans.
//

import SwiftUI
import UIKit

final class SearchContainerViewController: UIViewController {
    /// The results surface. Also the whole visible page: prompt/recents when
    /// the query is empty, inline states, and the grouped result grids.
    private let results = PlexHomeViewController(mode: .search)
    private let searchController: UISearchController
    private let searchContainer: UISearchContainerViewController

    /// Reports whether a music detail is covering the page, so the shell can
    /// treat Search the way it treats any nested navigation.
    ///
    /// Always delivered async: the reader is SwiftUI observable state, and both
    /// call sites can run inside a SwiftUI update (`viewDidAppear` fires from
    /// `mountContent`, which the representable drives), which is "Publishing
    /// changes from within view updates is not allowed".
    var onNestedChange: ((Bool) -> Void)?

    private func reportNested(_ isNested: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onNestedChange?(isNested) }
    }

    init() {
        // The page IS the search controller's results controller, which is what
        // lets the search controller collapse its keyboard when focus moves down
        // into the results and grow the page to fill the space.
        //
        // A previous attempt mounted the page as our own child with a hardcoded
        // 207pt top inset, to take the layout away from the search controller.
        // It fixed nothing — the real cause was `sidebar.view` occluding every
        // focusable item (see `RootShellViewController.updateChromeVisibility`) —
        // and it cost the keyboard collapse, because the search controller no
        // longer knew when focus left it. Do not take the layout back; fix focus
        // hand-off with the press correction below instead.
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
        searchController.searchBar.placeholder = "Search your libraries"
        // OCCLUSION, not appearance. This defaults to true and puts a dimming
        // view over the results controller until the search controller decides
        // to show it. Our results controller IS the page — prompt, recents,
        // inline states and grids — so it has to be visible from the moment the
        // tab mounts, empty query included. (`showsSearchResultsController`,
        // the iOS way to force that, is unavailable on tvOS.)
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

        addChild(searchContainer)
        searchContainer.view.frame = view.bounds
        searchContainer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(searchContainer.view)
        searchContainer.didMove(toParent: self)
    }


    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // ALWAYS the container for the keyboard half, never
        // `searchController.searchBar` directly: routing through the container
        // is what brings the tvOS keyboard up in the first place, and aiming at
        // the bar bypassed it — the keyboard was then never created at all.
        preferredHalf == .results ? [results] : [searchContainer]
    }

    // MARK: - Music hand-off

    /// Artists and albums open the SwiftUI music detail; tracks play directly
    /// and are intercepted in the results controller, never reaching here.
    private func presentMusicDetail(_ meta: PlexMetadata) {
        let kind: MusicSearchDetailRouter.Kind
        switch meta.type {
        case "artist": kind = .artist
        case "album": kind = .album
        default: return
        }

        // The stack is what the pushed album/artist detail navigates within, so
        // Menu inside it pops as it always did. `onExitCommand` sits on the
        // ROOT view only, so it fires just when there is nothing left to pop.
        let root = NavigationStack {
            MusicSearchDetailRouter(plexMeta: meta, kind: kind)
                .onExitCommand { [weak self] in
                    self?.dismiss(animated: true)
                }
        }
        .environment(MusicProviderRegistry.shared)

        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .fullScreen
        reportNested(true)
        present(host, animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentedViewController == nil { reportNested(false) }
    }

    /// Leaving the tab starts the next visit clean: empty query, focus back on
    /// the keyboard. Gated on `presentedViewController` because the music detail
    /// COVERS the page rather than leaving it, and returning from an album to a
    /// wiped query would lose the user's place.
    ///
    /// The controller is cached per tab in the shell, so without this the stale
    /// query and its results survive every switch away and back.
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

    /// Which half of the page the next focus REQUEST should aim at. Only the
    /// press hand-off below writes it, so it always reflects a deliberate move.
    private enum Half { case keyboard, results }
    private var preferredHalf: Half = .keyboard

    /// Move Down out of the keyboard, and Up out of the results' top row.
    ///
    /// The focus engine acts on arrow presses BEFORE the responder chain, and
    /// only presses it DECLINED bubble. So a Down press arriving here is one the
    /// engine could not use: it found nothing below the keyboard. Redirecting on
    /// that press therefore steals nothing — the keyboard's own Left/Right
    /// letter navigation and the results' own row-to-row moves never reach this
    /// method, because the engine consumes them.
    ///
    /// This is the same declined-press escape the player chrome uses
    /// (`InsightsPanelContainerView`, `InfoScrollView`), and it is deliberately
    /// not a `UIFocusGuide`: a guide has to be POSITIONED where the engine will
    /// find it, and the whole problem is that the search controller lays out
    /// the keyboard and the results in a hierarchy we do not control, so there
    /// is no frame we can pin a guide to and trust.
    ///
    /// Gated on where focus ACTUALLY is, not on `preferredHalf`, so the two can
    /// never drift apart.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let types = Set(presses.map(\.type))
        if types.contains(.downArrow), !focusIsInResults {
            rescue(to: .results)
        } else if types.contains(.upArrow), let from = results.focusedSectionForHandoff {
            correctUpward(from: from)
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

    /// Hand off only if the engine could not do it itself.
    ///
    /// `pressesBegan` fires whether or not the engine acted on the arrow, so
    /// intervening synchronously moved focus a SECOND time and landed a row past
    /// the intended one — visible once the top-inset fix let the engine make the
    /// Down move on its own. Sample the focused item, let the engine have the
    /// turn, and step in only if nothing actually moved.
    /// Up out of a results row, keyed on the DESTINATION rather than on whether
    /// the engine moved.
    ///
    /// Gating on "the engine could not move" was wrong here: on Up it CAN move,
    /// it just picks the keyboard. Revealing the focused row scrolls the row above
    /// off the collection's top edge, the engine will not focus an off-screen
    /// item, and the keyboard is the only remaining candidate above — so row 1 got
    /// skipped while every press looked handled.
    private func correctUpward(from section: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Landed back inside the page: the engine got it right, leave it.
            guard self.results.focusedSectionForHandoff == nil else { return }
            guard section > 0, self.results.focusRow(section - 1) else {
                // Genuinely left from the top row: the keyboard is correct, just
                // keep our own aim in step with where focus actually went.
                self.preferredHalf = .keyboard
                return
            }
            self.preferredHalf = .results
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
        // Requested from HERE on purpose: `setNeedsFocusUpdate()` is ignored
        // unless the asking environment currently contains focus, and this
        // controller is the nearest one that contains both halves.
        //
        // There used to be a `results.view.isUserInteractionEnabled = false`
        // around this, to stop the search container resolving back into the
        // results. It was self-defeating: disabling interaction removes the
        // subtree from the focus system, so nothing contained focus any more and
        // the request that followed was ignored outright — `moved=false`. It is
        // also unnecessary now that the results page is our own child rather than
        // the search controller's results, so `searchContainer` has nothing but
        // the chrome to resolve to.
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
