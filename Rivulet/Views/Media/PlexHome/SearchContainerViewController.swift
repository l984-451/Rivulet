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

        // NO safe-area inset here for the sidebar pill (#292). Pushing the
        // chrome down with `additionalSafeAreaInsets` DID clear the pill, but
        // the search controller collapses the keyboard by scrolling the chrome
        // up off screen and restores it with its own arithmetic, which the inset
        // is not part of: coming back from a row left the keyboard clipped by
        // about the inset's height, every time, no matter what the page's own
        // padding was. Search suppresses the pill instead (`TVSidebarView`),
        // which is what Live TV already does for the same collision.
        //
        // This is the same lesson as the note in `init`: the search controller
        // owns this layout, and perturbing it costs more than it buys.
        addChild(searchContainer)
        searchContainer.view.frame = view.bounds
        searchContainer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(searchContainer.view)
        searchContainer.didMove(toParent: self)
    }


    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard preferredHalf == .keyboard else { return [results] }
        // ORDER matters, and both entries are load-bearing.
        //
        // The container alone is not enough. `results` IS the search
        // controller's `searchResultsController` (see `init`), so asking the
        // container to resolve focus can resolve straight back DOWN into the
        // results, which is exactly what made Up from the top row look dead:
        // the request was made and satisfied, by the item we were trying to
        // leave. (A sibling note added in 9a1ffda claims the container "has
        // nothing but the chrome to resolve to". That described an approach
        // abandoned in the same commit; the page is not our own child.)
        //
        // The bar alone is not enough either, which is the finding that note
        // got right: routing through the container is what CREATES the tvOS
        // keyboard, and aiming at the bar on first mount meant it never
        // appeared. So the bar goes first, for the case where the keyboard
        // already exists and is merely collapsed, and the container stays
        // behind it for the case where it has to be built.
        return [searchController.searchBar, searchContainer]
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

    /// Re-expand the collapsed keyboard.
    ///
    /// The search controller shrinks its chrome to the bare field once focus
    /// moves into the results, and only grows it back when the field becomes
    /// first responder again. Focus alone does not do it, which is why coming
    /// back up landed on the field with the keyboard still collapsed, and why
    /// from the top row Up did nothing at all: the engine will not focus an
    /// item that is not on screen, and while collapsed there were no keys to
    /// focus. Aiming `preferredFocusEnvironments` at the bar instead of the
    /// container is NOT the fix here — see the note there, it stops the
    /// keyboard being created in the first place.
    private func reopenKeyboard() {
        // Start the page moving BEFORE the keyboard opens, so the two run
        // together. Getting down to a row leaves the page scrolled, and the
        // search controller does not scroll it back when the chrome grows again,
        // so the rows sat over the lower half of the re-expanded keyboard.
        // Animated on the page's shared focus-scroll curve: snapping it first
        // read as a jump ahead of the keyboard.
        results.animateToContentTop()
        guard !searchController.searchBar.isFirstResponder else { return }
        searchController.searchBar.becomeFirstResponder()
    }

    /// Move Down out of the keyboard, and Up out of the results' top row.
    ///
    /// The focus engine acts on arrow presses BEFORE the responder chain, and
    /// only presses it DECLINED bubble. So a Down press arriving here is one the
    /// engine could not use: it found nothing below the keyboard. Redirecting on
    /// that press therefore steals nothing — the keyboard's own Left/Right
    /// letter navigation and the results' own row-to-row moves never reach this
    /// method, because the engine consumes them.
    ///
    /// This is a declined-press escape, and it is deliberately
    /// not a `UIFocusGuide`: a guide has to be POSITIONED where the engine will
    /// find it, and the whole problem is that the search controller lays out
    /// the keyboard and the results in a hierarchy we do not control, so there
    /// is no frame we can pin a guide to and trust.
    ///
    /// Gated on where focus ACTUALLY is, not on `preferredHalf`, so the two can
    /// never drift apart.
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
    private func correctUpward(from section: Int, engineMoved: Bool) {
        let before = UIFocusSystem.focusSystem(for: view)?.focusedItem
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Whether the engine moved takes TWO signals, because it can act on
            // either side of the responder chain. `engineMoved` is the page's
            // own record of a move it made BEFORE the press was delivered; the
            // identity check below catches one made after. Judging by identity
            // alone read an already-handled press as a decline and moved a
            // second row: from row 3 Up landed on row 1, from row 2 on the
            // keyboard. Judging by the flag alone misses the other ordering.
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
                // Re-ask from HERE. `focusRow` scrolled the row in and marked it
                // as the one-shot target, but made its own request from
                // `results`, which no longer contains focus: the engine has
                // already moved to the keyboard, and `setNeedsFocusUpdate()` is
                // ignored unless the asking environment contains focus. The
                // target survives (consumed on read, and that read never
                // happened), so asking again from the controller that owns BOTH
                // halves lands on it. Without this the skipped row stays skipped.
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
        // Requested from HERE on purpose: `setNeedsFocusUpdate()` is ignored
        // unless the asking environment currently contains focus, and this
        // controller is the nearest one that contains both halves.
        //
        // There used to be a `results.view.isUserInteractionEnabled = false`
        // around this, to stop the search container resolving back into the
        // results. It was self-defeating: disabling interaction removes the
        // subtree from the focus system, so nothing contained focus any more and
        // the request that followed was ignored outright — `moved=false`.
        //
        // The resolving-back it was fighting is real, though. It is handled in
        // `preferredFocusEnvironments` by naming the bar ahead of the container,
        // which steers the request without taking anything out of the focus
        // system. (The old claim that the results page is "our own child" and so
        // cannot be resolved back into is wrong — see that note.)
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
