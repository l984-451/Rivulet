// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsContainerViewController.swift
//  Rivulet
//
//  Settings container and its focus owner: the title, the left description
//  panel, and a right pane whose pages swap with a directional cross-dissolve,
//  as tvOS Settings does. A focus guide traps Left in sub-pages; the SwiftUI
//  wrapper's `.onExitCommand` calls `pop()`.
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

    // Measured off tvOS Settings: pages move about 72 pt and settle in about 0.67 s.
    private let slideDistance: CGFloat = 72
    private let transitionDuration: TimeInterval = 0.67
    private var isAnimating = false
    private enum Navigation {
        case push(SettingsPage)
        case pop(Int)
    }
    private var pendingNavigation: Navigation?

    var depth: Int { pages.count }

    /// The first page. A standalone flow (the setup landing's) starts below `.root`.
    private let rootPage: SettingsPage

    /// Set for a standalone flow: Menu or a pop from its first page calls it.
    var onExit: (() -> Void)?

    /// The pages' frosted wash of the last page's artwork. Off for a flow that brings its own
    /// backdrop (the setup landing); set before the view loads.
    var drawsBackdrop = true
    private let ambientView = AmbientBackdropView()

    /// The Settings tab follows the system appearance, as tvOS Settings does, though the app
    /// window is pinned dark. A standalone flow keeps the dark of what it sits over.
    var followsSystemAppearance = false
    private var sceneStyleRegistration: UITraitChangeRegistration?

    init(rootPage: SettingsPage = .root) {
        self.rootPage = rootPage
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if drawsBackdrop { installBackdrop() } else { view.backgroundColor = .clear }
        setupLayout()
        if rootPage == .silo { SettingsContent.beginSiloFlow() }
        let root = makePage(rootPage)
        pages = [root]
        installPageView(root, into: rightPane)
        updateChrome(for: rootPage, animated: false)
        updateFocusGuide()
        if onExit != nil {
            let menu = UITapGestureRecognizer(target: self, action: #selector(menuPressed))
            menu.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            view.addGestureRecognizer(menu)
        }
    }

    @objc private func menuPressed() { pop() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if drawsBackdrop { ambientView.setAmbient(url: AmbientBackdropView.lastURL) }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The scene's traits are the system's; the window's dark override sits below it.
        guard followsSystemAppearance, sceneStyleRegistration == nil,
              let scene = view.window?.windowScene else { return }
        overrideUserInterfaceStyle = scene.traitCollection.userInterfaceStyle
        sceneStyleRegistration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (scene: UIWindowScene, _: UITraitCollection) in
            self?.overrideUserInterfaceStyle = scene.traitCollection.userInterfaceStyle
        }
    }

    /// Home's background, layer for layer: black, the artwork wash with its vignette, the adaptive material.
    private func installBackdrop() {
        view.backgroundColor = .black
        let frost = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        for layer in [ambientView, frost] as [UIView] {
            layer.isUserInteractionEnabled = false
            layer.frame = view.bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(layer)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil, presentedViewController == nil,
           pages.contains(where: { $0.page.isSiloFlow }) {
            SettingsContent.cancelSiloFlow()
        }
    }

    private func setupLayout() {
        titleLabel.font = .systemFont(ofSize: 57, weight: .bold)
        titleLabel.textColor = SettingsHeaderCell.captionColor
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

        // Fixed points measured off tvOS Settings (1920x1080): title baseline
        // 111, panel 90,180 870x654, rows from x 1060 (the page adds 24).
        NSLayoutConstraint.activate([
            titleLabel.firstBaselineAnchor.constraint(equalTo: view.topAnchor, constant: 111),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            leftPanel.topAnchor.constraint(equalTo: view.topAnchor, constant: 180),
            leftPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            leftPanel.widthAnchor.constraint(equalToConstant: SettingsLeftPanelView.width),
            leftPanel.heightAnchor.constraint(equalToConstant: 654),

            rightPane.topAnchor.constraint(equalTo: view.topAnchor, constant: 174),
            rightPane.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1036),
            rightPane.widthAnchor.constraint(equalToConstant: 828),
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
        vc.onPush = { [weak self, weak vc] target in
            guard let self, let vc, self.topPage === vc else { return }
            self.push(target)
        }
        // A page closes itself after async work (a sign-in, an add-source
        // check) too, by which time the user may have left it. Only the page
        // on screen may navigate; Menu goes through `pop()` directly.
        vc.onPop = { [weak self, weak vc] in
            guard let self, let vc, self.topPage === vc else { return }
            self.pop()
        }
        vc.onPopTwo = { [weak self, weak vc] in
            guard let self, let vc, self.topPage === vc else { return }
            self.pop(levels: 2)
        }
        vc.onFocusRow = { [weak self, weak vc] id in
            guard let self, let vc, self.topPage === vc else { return }
            self.leftPanel.show(id: id)
        }
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
        if isAnimating {
            pendingNavigation = .push(page)
            return
        }
        if page == .silo, topPage?.page.isSiloFlow != true { SettingsContent.beginSiloFlow() }
        if topPage?.page.isSiloFlow == true, !page.isSiloFlow { SettingsContent.cancelSiloFlow() }
        let newVC = makePage(page)
        let oldVC = topPage
        pages.append(newVC)
        installPageView(newVC, into: rightPane)
        rightPane.layoutIfNeeded()
        updateChrome(for: page, animated: true)
        animateTransition(incoming: newVC, outgoing: oldVC, forward: true)
        updateFocusGuide()
        onDepthChange?(pages.count > 1)
    }

    /// Pops `levels` pages in one transition: the pages between are dropped
    /// unseen (they hold no view while covered).
    func pop(levels: Int = 1) {
        // The incoming page already accepts focus and asynchronous form results.
        if isAnimating {
            if case let .pop(pendingLevels)? = pendingNavigation {
                pendingNavigation = .pop(max(pendingLevels, levels))
            } else {
                pendingNavigation = .pop(levels)
            }
            return
        }
        if pages.count <= levels, let onExit {
            if let page = topPage?.page, page.isSiloFlow {
                SettingsContent.leaveSiloPage(page)
                SettingsContent.cancelSiloFlow()
            }
            onExit()
            return
        }
        guard pages.count > levels else { return }
        for _ in 1..<max(levels, 1) {
            let skipped = pages.remove(at: pages.count - 2)
            if skipped.page.isSiloFlow { SettingsContent.leaveSiloPage(skipped.page) }
            skipped.willMove(toParent: nil)
            skipped.removeFromParent()
        }
        let oldVC = pages.removeLast()
        if oldVC.page.isSiloFlow { SettingsContent.leaveSiloPage(oldVC.page) }
        let newVC = topPage
        if oldVC.page.isSiloFlow, newVC?.page.isSiloFlow != true { SettingsContent.cancelSiloFlow() }
        if let newVC {
            installPageView(newVC, into: rightPane)
            // Rebuild the kept page's rows (the pushed page may have changed
            // them), then lay out, so its cells exist before the focus request
            // in `animateTransition`. In the other order focus goes to nil.
            newVC.reloadRows()
            newVC.collectionView?.layoutIfNeeded()
            rightPane.layoutIfNeeded()
        }
        updateChrome(for: topPage?.page ?? rootPage, animated: true)
        animateTransition(incoming: newVC, outgoing: oldVC, forward: false, removeOutgoing: true)
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
            if let navigation = self.pendingNavigation {
                self.pendingNavigation = nil
                switch navigation {
                case let .push(page): self.push(page)
                case let .pop(levels): self.pop(levels: levels)
                }
                return
            }
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
        // Trap Left only in sub-pages (and always standalone, with no sidebar to reach).
        leftFocusGuide.isEnabled = pages.count > 1 || onExit != nil
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
