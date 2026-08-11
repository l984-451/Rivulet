// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsContainerViewController.swift
//  Rivulet
//
//  UIKit Settings container — the single focus authority and the owner of the
//  whole Settings surface (replaces the SwiftUI NavigationStack so the
//  transition can be fully controlled). Mirrors the SwiftUI layout: a
//  persistent title + left description panel, and a right content pane whose
//  page row-lists are swapped with a custom DIRECTIONAL cross-dissolve
//  (push = new from right / old to left; pop = new from left / old to right) —
//  matching Apple TV Settings + the old SwiftUI `animatePageSwap`.
//
//  Focus never collapses to nil (preferredFocusEnvironments → top page).
//  Left is trapped in sub-pages via a focus guide (so it can't open the
//  sidebar); Menu-pop is driven by the SwiftUI wrapper's `.onExitCommand`
//  calling `pop()`. The wedge is structurally impossible: focus is always
//  owned, and there is no SwiftUI in-place rebuild.
//

import UIKit

@MainActor
final class SettingsContainerViewController: UIViewController {

    /// Fired (post-transition) with the new sub-page state (`true` = depth > 1).
    var onDepthChange: ((Bool) -> Void)?

    private let titleLabel = UILabel()
    private let leftPanel = SettingsLeftPanelView()
    private let rightPane = UIView()
    private let leftFocusGuide = UIFocusGuide()

    private var pages: [SettingsPageViewController] = []
    private var topPage: SettingsPageViewController? { pages.last }

    private let slideDistance: CGFloat = 80
    private let transitionDuration: TimeInterval = 0.45
    private var isAnimating = false

    var depth: Int { pages.count }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupLayout()
        // Root page.
        let root = makePage(.root)
        pages = [root]
        installPageView(root, into: rightPane)
        updateChrome(for: .root, animated: false)
        updateFocusGuide()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func setupLayout() {
        titleLabel.font = .systemFont(ofSize: 52, weight: .bold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(leftPanel)

        // No hard clip: clipping the sliding pages against the pane bounds
        // cuts the capsules at the edge and reveals the container edge. We
        // instead fade the outgoing page out fast (below) so it never visibly
        // overflows, and the incoming slides in from off the screen's right.
        rightPane.clipsToBounds = false
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rightPane)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            leftPanel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            leftPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leftPanel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.55),

            rightPane.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            rightPane.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            rightPane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightPane.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Left-trap: leftward focus from the right pane lands on this guide
        // (covering the left-panel region) and is redirected back into the
        // current page — so Left does nothing in a sub-page (never opens the
        // sidebar). Disabled at the root, where Left yields to the sidebar.
        view.addLayoutGuide(leftFocusGuide)
        NSLayoutConstraint.activate([
            leftFocusGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftFocusGuide.trailingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            leftFocusGuide.topAnchor.constraint(equalTo: rightPane.topAnchor),
            leftFocusGuide.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor)
        ])
    }

    // MARK: - Page factory

    private func makePage(_ page: SettingsPage) -> SettingsPageViewController {
        let vc = SettingsPageViewController(page: page)
        vc.onPush = { [weak self] target in self?.push(target) }
        vc.onPop = { [weak self] in self?.pop() }
        vc.onFocusRow = { [weak self] id in self?.leftPanel.show(id: id) }
        return vc
    }

    private func installPageView(_ vc: SettingsPageViewController, into container: UIView) {
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        vc.didMove(toParent: self)
    }

    // MARK: - Navigation

    func push(_ page: SettingsPage) {
        guard !isAnimating else { return }
        let newVC = makePage(page)
        let oldVC = topPage
        pages.append(newVC)
        installPageView(newVC, into: rightPane)
        rightPane.layoutIfNeeded()
        animateTransition(incoming: newVC, outgoing: oldVC, forward: true)
        updateChrome(for: page, animated: true)
        updateFocusGuide()
        onDepthChange?(pages.count > 1)
    }

    func pop() {
        guard !isAnimating, pages.count > 1 else { return }
        let oldVC = pages.removeLast()
        let newVC = topPage
        if let newVC {
            installPageView(newVC, into: rightPane)
            // Refresh values (e.g. a picker selection just changed) — the kept
            // VC's cells were built with the old value. Reload FIRST, then lay
            // out, so the reloaded cells exist (and are focusable) BEFORE the
            // focus request in `animateTransition`. Reloading AFTER layout
            // strands focus: the request finds no laid-out cell → focusedItem
            // becomes nil → the shell's focus watchdog yanks focus into the
            // content and the sidebar flickers open/closed at the root.
            //
            // REBUILD, don't just reloadData: a kept page's row ARRAY is also
            // stale when the pushed page changed the underlying model (Live TV
            // Sources gains a row when the add-source flow pops back). Reloading
            // cells alone would redraw the old row list.
            newVC.reloadRows()
            newVC.collectionView?.layoutIfNeeded()
            rightPane.layoutIfNeeded()
        }
        animateTransition(incoming: newVC, outgoing: oldVC, forward: false, removeOutgoing: true)
        updateChrome(for: topPage?.page ?? .root, animated: true)
        updateFocusGuide()
        onDepthChange?(pages.count > 1)
    }

    /// Custom directional cross-dissolve. forward (push): new from right, old
    /// to left. backward (pop): new from left, old to right.
    private func animateTransition(incoming: SettingsPageViewController?,
                                   outgoing: SettingsPageViewController?,
                                   forward: Bool,
                                   removeOutgoing: Bool = false) {
        isAnimating = true
        let inFrom: CGFloat = forward ? slideDistance : -slideDistance
        let outTo: CGFloat = forward ? -slideDistance : slideDistance

        // Make sure the incoming sits above the outgoing during the dissolve.
        if let incoming { rightPane.bringSubviewToFront(incoming.view) }

        incoming?.view.alpha = 0
        incoming?.view.transform = CGAffineTransform(translationX: inFrom, y: 0)
        outgoing?.view.alpha = 1
        outgoing?.view.transform = .identity

        UIView.animate(withDuration: transitionDuration, delay: 0,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            incoming?.view.alpha = 1
            incoming?.view.transform = .identity
            outgoing?.view.transform = CGAffineTransform(translationX: outTo, y: 0)
        } completion: { [weak self] _ in
            guard let self else { return }
            if removeOutgoing {
                outgoing?.willMove(toParent: nil)
                outgoing?.view.removeFromSuperview()
                outgoing?.removeFromParent()
            } else {
                // Push: keep the outgoing VC (for a later pop) but drop its
                // view + reset its transform so re-install is clean.
                outgoing?.view.removeFromSuperview()
                outgoing?.view.transform = .identity
                outgoing?.view.alpha = 1
            }
            self.isAnimating = false
            // Defense-in-depth: if the start-of-transition focus request raced
            // the incoming collection's layout and focus settled to nil, land
            // it now (the incoming is opaque + laid out). Guard on nil so we
            // never yank focus back if the user already moved to the sidebar.
            if self.systemFocusedItem == nil {
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        }

        // Outgoing fades out FAST (front-loaded) so it's invisible well before
        // it slides far enough to overflow the panel / clip an edge.
        UIView.animate(withDuration: transitionDuration * 0.45, delay: 0, options: [.curveEaseOut]) {
            outgoing?.view.alpha = 0
        }

        // Move focus to the incoming page.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func updateChrome(for page: SettingsPage, animated: Bool) {
        // Crossfade the title + panel only — NOT the whole view, which would
        // fight the rightPane's directional slide.
        if animated {
            UIView.transition(with: titleLabel, duration: 0.3, options: .transitionCrossDissolve) {
                self.titleLabel.text = page.title
            }
        } else {
            titleLabel.text = page.title
        }
        leftPanel.configure(page: page, animated: animated)
    }

    private func updateFocusGuide() {
        // Trap Left only in sub-pages; point it back at the current page.
        leftFocusGuide.isEnabled = pages.count > 1
        if let collection = topPage?.collectionView {
            leftFocusGuide.preferredFocusEnvironments = [collection]
        }
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let topPage { return [topPage] }
        return super.preferredFocusEnvironments
    }

    /// The window's current system-level focused item (nil = focus collapsed).
    /// Used to nil-guard the completion-block focus re-assert.
    private var systemFocusedItem: UIFocusItem? {
        UIFocusSystem.focusSystem(for: view)?.focusedItem
    }
}
