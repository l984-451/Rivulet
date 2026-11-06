// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RootShellViewController.swift
//  Rivulet
//
//  The navigation shell: one content child per tab, the sidebar, the left-edge
//  focus catcher and the Menu policy. SwiftUI owns the selection: the shell
//  reports intent through onTabChange and gets the result via applySelection.
//

import UIKit

/// Invisible focus target at the left edge; focus landing here means the
/// user pushed left out of content, which opens the sidebar.
private final class EdgeCatcherView: UIView {
    override var canBecomeFocused: Bool { true }
}

final class RootShellViewController: UIViewController {

    /// Builds a content controller for a tab. Set before the view loads.
    var makeContent: ((SidebarTab) -> UIViewController)?
    /// Reports tab intent upward to the SwiftUI selection binding.
    var onTabChange: ((SidebarTab) -> Void)?

    /// Nested detail / Settings sub-page: sidebar cannot open, pill hides,
    /// and Menu is left alone for the surface's own back handling.
    var interactionBlocked = false {
        didSet { updateChromeVisibility() }
    }
    /// Music library selected: music draws its own sidebar, ours stays out.
    var pillSuppressed = false {
        didSet { updateChromeVisibility() }
    }

    /// A counter: each bump closes the sidebar (a profile switch lands on Home
    /// with the sidebar closed, as the TV app's relaunch does).
    var collapseRequest = 0 {
        didSet {
            guard collapseRequest != oldValue, isViewLoaded else { return }
            evictCachedContent()
            // The switch emptied the mounted page: once it reloads, focus has to
            // be driven into it again, as on a fresh mount.
            contentHasHadFocus = false
            collapseSidebar()
            updateChromeVisibility()
        }
    }

    /// Drops every cached page but Home: they hold the previous profile's items.
    private func evictCachedContent() {
        for (tab, vc) in contentVCs where tab != .home {
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
            contentVCs[tab] = nil
        }
    }

    /// The profile panel is up: the sidebar folds to its pill, which names the user.
    var profilePanelOpen = false {
        didSet {
            guard profilePanelOpen != oldValue, isViewLoaded else { return }
            sidebar.setPillShowsProfile(profilePanelOpen)
            if profilePanelOpen { collapseSidebar() }
            updateChromeVisibility()
        }
    }
    /// A counter: each bump reopens the sidebar on the profile row (the panel
    /// closed with no switch, back to where Select was pressed).
    var profileRowRequest = 0 {
        didSet { if profileRowRequest != oldValue, isViewLoaded { expandSidebar(aimAt: .account) } }
    }

    private(set) var currentTab: SidebarTab = .home
    private var contentVCs: [SidebarTab: UIViewController] = [:]
    private let sidebar = ShellSidebarViewController()
    private let edgeCatcher = EdgeCatcherView()
    private var belowTop = false
    /// The edge catcher stays out of the focus system until the mounted content
    /// has held focus, or a focus search on not-yet-focusable content parks on
    /// it for good. Reset on every mount, not once per launch (#280).
    private var contentHasHadFocus = false
    private var pendingSections: [ShellSidebarSection]?
    /// Bounded retry that pushes focus into freshly mounted content — see
    /// `driveFocusIntoContent()`.
    private var contentFocusRetries = 0
    /// The retry budget ran out with nothing focusable on the page. The catcher
    /// is re-armed as an escape hatch so Left and Menu still have a target.
    private var contentFocusGaveUp = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        mountContent(for: currentTab)

        sidebar.embedded = true
        addChild(sidebar)
        sidebar.view.frame = view.bounds
        sidebar.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sidebar.view)
        sidebar.didMove(toParent: self)
        sidebar.setExpanded(false, animated: false)
        sidebar.view.isUserInteractionEnabled = false
        if let pendingSections { sidebar.setSections(pendingSections) }

        sidebar.onTabSelected = { [weak self] tab in
            guard let self else { return }
            // The profile row opens the switcher; it has no content to mount.
            if tab == .account { self.onTabChange?(tab); return }
            // Mount before collapsing: `collapseSidebar` resolves focus at once
            // and the SwiftUI round trip is async, so focus would land in the
            // outgoing tab first. The round trip's `applySelection` then no-ops.
            self.applySelection(tab)
            self.onTabChange?(tab)
            self.collapseSidebar()
        }
        sidebar.onCollapseRequested = { [weak self] in self?.collapseSidebar() }

        // Full-height strip at the leading edge: a Left press from any content
        // (hero Play, a shelf's first tile) lands here and opens the sidebar.
        edgeCatcher.frame = CGRect(x: 0, y: 0, width: 2, height: view.bounds.height)
        edgeCatcher.autoresizingMask = [.flexibleHeight]
        edgeCatcher.isHidden = true
        view.addSubview(edgeCatcher)

        MenuPressInterceptor.register(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBelowTopChanged(_:)),
            name: .contentFocusBelowTopChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleContentBecameFocusable),
            name: .contentBecameFocusable, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTabContentReplaced(_:)),
            name: .tabContentReplaced, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let window = view.window { MenuPressInterceptor.install(in: window) }
    }

    // MARK: Selection (SwiftUI is the authority)

    /// Called from the representable whenever the binding changes (or any
    /// SwiftUI update runs); idempotent.
    func applySelection(_ tab: SidebarTab) {
        guard isViewLoaded else { currentTab = tab; return }
        sidebar.setSelectedTabExternal(tab)
        guard tab != currentTab else { return }
        currentTab = tab
        // `mountContent` owns the focus hand-off into the new tab (it is the
        // only place that knows the content is fresh and not yet focusable).
        mountContent(for: tab)
    }

    /// Live sidebar content, pushed from SwiftUI on every relevant change.
    func updateSections(_ sections: [ShellSidebarSection]) {
        guard isViewLoaded else { pendingSections = sections; return }
        let available = Set(sections.flatMap(\.items).map(\.tab))
        for (tab, controller) in contentVCs where !available.contains(tab) && tab != .home {
            if let requests = controller as? SiloRequestsViewController { requests.invalidateAuthority() }
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            contentVCs[tab] = nil
        }
        sidebar.setSections(sections)
    }

    /// Re-points every cached hosting controller at a freshly built root so
    /// content tracks TVSidebarView's state. The type check runs before `build`
    /// because this fires on every TVSidebarView update and a UIKit tab needs none.
    func refreshContentRoots(_ build: (SidebarTab) -> UIViewController?) {
        for tab in contentVCs.keys {
            guard let host = contentVCs[tab] as? RootShellHostingController,
                  let fresh = build(tab) else { continue }
            host.adoptRoot(from: fresh)
        }
    }

    private func mountContent(for tab: SidebarTab) {
        guard let makeContent else { return }
        for (_, vc) in contentVCs where vc.view.superview != nil {
            vc.beginAppearanceTransition(false, animated: false)
            vc.view.removeFromSuperview()
            vc.endAppearanceTransition()
        }
        let next: UIViewController
        if let cached = contentVCs[tab] {
            next = cached
        } else {
            next = makeContent(tab)
            contentVCs[tab] = next
            addChild(next)
            next.didMove(toParent: self)
        }
        next.beginAppearanceTransition(true, animated: false)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(next.view, at: 0)
        next.endAppearanceTransition()

        contentHasHadFocus = false
        contentFocusGaveUp = false
        // `belowTop` belongs to the page that posted it; pages that care re-post
        // on their first focus change, others would inherit a hidden pill.
        belowTop = false
        updateChromeVisibility()
        driveFocusIntoContent()
    }

    /// Resolves focus into the mounted content, retrying on the runloop because
    /// hosted SwiftUI is not focusable in the turn it mounts. Stops when content
    /// takes focus or the budget runs out.
    private func driveFocusIntoContent() {
        contentFocusRetries = 20        // ~1s at 50ms
        retryFocusIntoContent()
    }

    private func retryFocusIntoContent() {
        guard !contentHasHadFocus, !sidebar.isExpanded else { return }
        guard contentFocusRetries > 0 else {
            contentFocusGaveUp = true
            updateChromeVisibility()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return
        }
        contentFocusRetries -= 1
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        guard !contentHasHadFocus else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.retryFocusIntoContent()
        }
    }

    // MARK: Sidebar chrome

    private func expandSidebar(aimAt tab: SidebarTab? = nil) {
        guard !sidebar.isExpanded, !interactionBlocked else { return }
        sidebar.setExpanded(true, animated: true, aimAt: tab)
        updateChromeVisibility()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func collapseSidebar() {
        guard sidebar.isExpanded else { return }
        sidebar.setExpanded(false, animated: true)
        updateChromeVisibility()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // The mount's retry bailed while the sidebar was open; run it now so a
        // still-loading page arms the edge catcher.
        if !contentHasHadFocus { driveFocusIntoContent() }
    }

    private func updateChromeVisibility() {
        guard isViewLoaded else { return }
        if interactionBlocked, sidebar.isExpanded { collapseSidebar() }
        // The profile panel hangs under the pill, so the pill shows on every page.
        sidebar.setPillHidden(!profilePanelOpen && (belowTop || pillSuppressed || interactionBlocked))
        // The collapsed sidebar is a full-screen overlay above all content, and
        // `UIFocusDebugger` names it as the occluder of every item beneath it.
        sidebar.view.isUserInteractionEnabled = sidebar.isExpanded
        edgeCatcher.isHidden = interactionBlocked || !(contentHasHadFocus || contentFocusGaveUp)
    }

    @objc private func handleBelowTopChanged(_ note: Notification) {
        belowTop = note.object as? Bool ?? false
        updateChromeVisibility()
    }

    /// The mounted page finished loading and now has something focusable.
    /// Re-arms the focus drive, whose ~1s budget does not cover a network load.
    @objc private func handleContentBecameFocusable() {
        guard !contentHasHadFocus else { return }
        contentFocusGaveUp = false
        updateChromeVisibility()
        driveFocusIntoContent()
    }

    /// The mounted tab swapped its page: hand focus in as `mountContent` does.
    @objc private func handleTabContentReplaced(_ note: Notification) {
        guard let content = contentVCs[currentTab], note.object as AnyObject? === content else { return }
        contentHasHadFocus = false
        contentFocusGaveUp = false
        belowTop = false
        updateChromeVisibility()
        driveFocusIntoContent()
    }

    // MARK: Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if sidebar.isExpanded { return [sidebar.focusTarget] }
        if let content = contentVCs[currentTab] { return [content] }
        return super.preferredFocusEnvironments
    }

    /// The nearest backing `UIView` at or above `item` in the focus chain.
    /// SwiftUI focus items are not UIViews, so a bare `as? UIView` is nil on a
    /// hosted tab and every containment test would fail there.
    private func backingView(of item: UIFocusEnvironment?) -> UIView? {
        var env = item
        while let current = env {
            if let view = current as? UIView { return view }
            if let controller = current as? UIViewController { return controller.viewIfLoaded }
            env = current.parentFocusEnvironment
        }
        return nil
    }

    /// Is the focused item anywhere inside this shell, sidebar included?
    private func isInsideShell(_ item: UIFocusEnvironment?) -> Bool {
        backingView(of: item)?.isDescendant(of: view) == true
    }

    /// Is the focused item inside the mounted content, i.e. inside the shell
    /// but outside the sidebar?
    private func isInsideContent(_ item: UIFocusEnvironment?) -> Bool {
        guard let backing = backingView(of: item) else { return false }
        return backing.isDescendant(of: view) && !backing.isDescendant(of: sidebar.view)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedItem else { return }
        if let nextView = next as? UIView, nextView === edgeCatcher {
            if isInsideContent(context.previouslyFocusedItem) {
                expandSidebar()
            } else {
                // Spurious landing (launch search); bounce back to content.
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
            return
        }
        // The profile panel hands focus back to the content it left it in, after
        // the sidebar has reopened: pull it into the sidebar.
        if sidebar.isExpanded, isInsideContent(next) {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return
        }
        if !contentHasHadFocus, isInsideContent(next) {
            contentHasHadFocus = true
            updateChromeVisibility()
        }
    }
}

// MARK: - Menu policy

extension RootShellViewController: MenuBackHandling {
    /// Offered AFTER content handlers (registration order): by the time this
    /// runs, the home page has already consumed below-top Menu presses.
    func handleMenuBack() -> Bool {
        guard view.window?.isKeyWindow == true else { return false }
        // Focus must be inside the shell's own views: `isKeyWindow` stays true
        // under a modal, and claiming Menu there kills it in the modal.
        // See CLAUDE.md, Remote Input. Nothing focused and nothing presented is
        // a page still loading, where Menu opens the sidebar instead of quitting.
        let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem
        let loadingPage = focused == nil && view.window?.rootViewController?.presentedViewController == nil
        guard isInsideShell(focused) || loadingPage else { return false }
        if sidebar.cancelRowMove() { return true }
        if sidebar.isExpanded {
            // Menu in the open sidebar returns to Home (issue #192 policy);
            // on Home it falls through so the system can exit the app.
            guard currentTab != .home else {
                collapseSidebar()
                return false
            }
            onTabChange?(.home)
            collapseSidebar()
            return true
        }
        guard !interactionBlocked else { return false }
        expandSidebar()
        return true
    }
}
