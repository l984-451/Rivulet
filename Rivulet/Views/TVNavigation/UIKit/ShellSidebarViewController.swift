// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ShellSidebarViewController.swift
//  Rivulet
//
//  The custom shell sidebar: Rivulet's own recreation of the tvOS
//  `.sidebarAdaptable` chrome, built so the shell owns expansion, collapse,
//  and the pill (which the system version cannot hide; see the pill research
//  notes). Currently reachable only through the `--sidebar-preview` launch
//  argument for visual evaluation; the shell integration comes after the
//  look is approved.
//

import UIKit

// MARK: - Metrics

private enum Metrics {
    /// MEASURED from the live system sidebar (SidebarMeasure dump,
    /// 2026-07-31): rows are 78pt pitch, zero spacing; content leading x 54
    /// in window coords; every section break is a 70pt gap with the header
    /// drawn inside it; list top inset 55, bottom 51. The focused capsule is
    /// the 302pt-wide hosted content, ~54pt tall centered in the 78pt cell
    /// (capsule height read from the screenshot against the cell frames).
    ///
    /// MEASURED from the presentation-layer trace of the system morph
    /// (SidebarAnim bursts, 2026-07-31, simulator): the glass card animates
    /// frame AND corner radius between panel (35,35 340x1010) r52 and pill
    /// (50,50 ~160x60) r30 over ~450ms, settling ~97% by 240ms (high-damping
    /// spring). Sim-captured; re-verify timing on device.
    static let panelWidth: CGFloat = 340
    static let panelInset: CGFloat = 35
    static let panelCornerRadius: CGFloat = 52
    /// 54 (window) - 36 (panel inset) = capsule leading inside the panel.
    static let contentLeading: CGFloat = 18
    static let contentTrailing: CGFloat = 18
    /// 55 (list top inset, window) - 36 (panel inset).
    static let contentTop: CGFloat = 19
    static let contentBottom: CGFloat = 15
    static let rowPitch: CGFloat = 78
    /// Video-measured (default.mov, pitch-calibrated): the focused capsule
    /// nearly fills the 78pt row.
    static let capsuleHeight: CGFloat = 75
    static var capsuleRadius: CGFloat { capsuleHeight / 2 }
    static var capsuleVerticalInset: CGFloat { (rowPitch - capsuleHeight) / 2 }
    static let sectionGap: CGFloat = 70
    static let pillOrigin = CGPoint(x: 50, y: 50)
    static let pillHeight: CGFloat = 60
    /// USER-VERIFIED on screen: the single spring crossfade reads nearly
    /// identical to the system morph; a literal three-phase re-timing from
    /// the 120fps frame analysis read distinctly WORSE and was reverted.
    /// Trust the A/B eyeball over tile-level frame forensics here.
    static let morphDuration: TimeInterval = 0.45
    static let morphDamping: CGFloat = 0.9
    static let dimAlpha: CGFloat = 0.35
    /// Darkens the glass toward the system sidebar's tone; the sole knob for
    /// the material tuning pass, to be converged against sampled pixels.
    static let glassTint = UIColor.black.withAlphaComponent(0.12)
}

/// System row coloring: focused = solid white capsule, dark content; selected
/// but unfocused = translucent capsule, full-white content; otherwise bare, dim.
private func sidebarRowColors(focused: Bool, selected: Bool) -> (background: UIColor, content: UIColor) {
    if focused { return (.white, .black) }
    if selected { return (UIColor.white.withAlphaComponent(0.1), .white) }
    return (.clear, UIColor.white.withAlphaComponent(0.6))
}

/// The collapsed pill's back-chevron. NOT SF `chevron.left`: measured from the
/// system pill it is tall and narrow (7.5 x 25.7pt, aspect ~1:3.4), a 3.2pt
/// stroke with rounded caps/join and a sharp ~60deg vertex, drawn so the
/// proportion matches exactly.
private final class PillChevronView: UIView {
    private let shape = CAShapeLayer()
    private let size = CGSize(width: 8, height: 26)

    override init(frame: CGRect) {
        super.init(frame: frame)
        shape.fillColor = nil
        shape.strokeColor = UIColor.white.cgColor
        shape.lineWidth = 3.2
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { size }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = shape.lineWidth / 2
        let w = size.width, h = size.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: w - inset, y: inset))          // top-right
        path.addLine(to: CGPoint(x: inset, y: h / 2))            // vertex (left, mid)
        path.addLine(to: CGPoint(x: w - inset, y: h - inset))    // bottom-right
        shape.path = path.cgPath
        shape.frame = CGRect(origin: CGPoint(x: (bounds.width - w) / 2,
                                             y: (bounds.height - h) / 2), size: size)
    }
}


// MARK: - Collection view

/// Directs its opening focus at a specific row. `remembersLastFocusedIndexPath`
/// only restores the last-touched cell; the sidebar needs the SELECTED tab
/// focused on every open, so it sets `preferredFocusIndexPath` first.
final class SidebarCollectionView: UICollectionView {
    var preferredFocusIndexPath: IndexPath?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // The cell must exist right now, or the engine ignores this and falls
        // back to its own pick (realized in aimInitialFocusAtSelectedTab).
        if let indexPath = preferredFocusIndexPath, let cell = cellForItem(at: indexPath) {
            return [cell]
        }
        return super.preferredFocusEnvironments
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // The aim is for the OPENING move only, and nothing was clearing it.
        // Left set, EVERY later focus update while the sidebar was open
        // resolved back through it to the selected row — so the expand
        // animator's completion, which requests focus ~0.3s after opening,
        // yanked the user back from whatever row they had already moved to.
        // The next open re-aims via `aimInitialFocusAtSelectedTab`.
        if let next = context.nextFocusedItem as? UIView, next.isDescendant(of: self) {
            preferredFocusIndexPath = nil
        }
    }
}

// MARK: - Row cell

final class ShellSidebarRowCell: UICollectionViewCell {
    static let reuseIdentifier = "ShellSidebarRowCell"

    private let backgroundPill = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private var isSelectedTab = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundPill.layer.cornerRadius = Metrics.capsuleRadius
        backgroundPill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backgroundPill)

        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .systemFont(ofSize: 29, weight: .medium)

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel])
        stack.axis = .horizontal
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            backgroundPill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundPill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundPill.topAnchor.constraint(equalTo: contentView.topAnchor,
                                                constant: Metrics.capsuleVerticalInset),
            backgroundPill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor,
                                                   constant: -Metrics.capsuleVerticalInset),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 17),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -17),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        applyAppearance(focused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: ShellSidebarItem, isSelectedTab: Bool) {
        self.isSelectedTab = isSelectedTab
        iconView.image = UIImage(systemName: item.icon)
        titleLabel.text = item.title
        applyAppearance(focused: isFocused)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        if focused {
            coordinator.addCoordinatedAnimations({ self.applyAppearance(focused: true) })
        } else {
            // Clear instantly: running the unfocus through the coordinator
            // leaves the old row's white capsule ghosting behind the move.
            applyAppearance(focused: false)
        }
    }

    private func applyAppearance(focused: Bool) {
        let colors = sidebarRowColors(focused: focused, selected: isSelectedTab)
        backgroundPill.backgroundColor = colors.background
        iconView.tintColor = colors.content
        titleLabel.textColor = colors.content
    }
}

// MARK: - Section header

final class ShellSidebarHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "ShellSidebarHeaderView"
    static let elementKind = "ShellSidebarHeader"
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 21, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.45)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Controller

final class ShellSidebarViewController: UIViewController {

    private enum State { case expanded, collapsed }

    private var state: State = .expanded
    private var sections: [ShellSidebarSection] = []
    private var selectedTab: SidebarTab = .home

    private let dimmingView = UIView()
    /// ONE glass card morphs between panel and pill, as the trace showed the
    /// system does: frame and corner radius animate together on one spring;
    /// the list fades out and clips inside the shrinking card while the pill
    /// content fades in.
    private let cardView = UIView()
    private let glassView: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = Metrics.glassTint
        return UIVisualEffectView(effect: effect)
    }()
    private let pillChevron = PillChevronView()
    private let pillIcon = UIImageView()
    private let pillLabel = UILabel()
    private let pillStack = UIStackView()
    private var collectionView: SidebarCollectionView!
    private var transitionAnimator: UIViewPropertyAnimator?

    // MARK: Shell integration
    // When embedded, RootShellViewController owns expansion, focus handoff,
    // and tab authority; the sidebar reports intent through these callbacks.
    // The preview modal path keeps `embedded` false and self-drives.
    var embedded = false
    var onTabSelected: ((SidebarTab) -> Void)?
    var onCollapseRequested: (() -> Void)?
    private var pillHidden = false

    var isExpanded: Bool { state == .expanded }
    var focusTarget: UIView { collectionView }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        if expanded { aimInitialFocusAtSelectedTab() }
        setState(expanded ? .expanded : .collapsed)
        if !animated {
            transitionAnimator?.stopAnimation(false)
            transitionAnimator?.finishAnimation(at: .end)
        }
    }

    /// Directs the sidebar's opening focus at the currently selected tab's
    /// row (Home opens on Home, Settings on Settings). The cell must be
    /// realized before the focus engine reads `preferredFocusEnvironments`,
    /// so unhide + lay out + scroll it into view first.
    private func aimInitialFocusAtSelectedTab() {
        guard let indexPath = indexPath(for: selectedTab) else {
            collectionView.preferredFocusIndexPath = nil
            return
        }
        collectionView.isHidden = false
        collectionView.preferredFocusIndexPath = indexPath
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
    }

    private func indexPath(for tab: SidebarTab) -> IndexPath? {
        for (s, section) in sections.enumerated() {
            if let i = section.items.firstIndex(where: { $0.tab == tab }) {
                return IndexPath(item: i, section: s)
            }
        }
        return nil
    }

    /// Selection pushed down from the shell (SwiftUI is the tab authority).
    func setSelectedTabExternal(_ tab: SidebarTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        configurePill(item(for: tab))
        collectionView.reloadData()
    }

    /// Live section updates pushed from SwiftUI, which observes every store
    /// that feeds the sidebar. Diffed, so idle updates cost nothing; no
    /// snapshot dance, the whole point of owning the shell.
    func setSections(_ new: [ShellSidebarSection]) {
        guard new != sections else { return }
        sections = new
        guard isViewLoaded else { return }
        collectionView.reloadData()
        configurePill(item(for: selectedTab))
    }

    /// Collapsed-state pill visibility, driven by the below-top focus signal.
    func setPillHidden(_ hidden: Bool) {
        pillHidden = hidden
        guard state == .collapsed, transitionAnimator == nil else { return }
        UIView.animate(withDuration: 0.18) {
            self.cardView.alpha = hidden ? 0 : 1
            self.pillChevron.alpha = hidden ? 0 : 1
        }
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        sections = Self.liveSections()
        buildViews()
        configurePill(item(for: selectedTab))
        applyState(expanded: true, animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard transitionAnimator == nil else { return }
        cardView.frame = state == .expanded ? panelFrame : pillFrame
        layoutListInCard()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        state == .expanded ? [collectionView] : []
    }

    // MARK: Input

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch (press.type, state) {
            case (.rightArrow, .expanded):
                if embedded { onCollapseRequested?() } else { setState(.collapsed) }
                return
            case (.leftArrow, .collapsed) where !embedded:
                setState(.expanded)
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: Morph

    private var panelFrame: CGRect {
        CGRect(x: Metrics.panelInset, y: Metrics.panelInset,
               width: Metrics.panelWidth,
               height: view.bounds.height - 2 * Metrics.panelInset)
    }

    private var pillFrame: CGRect {
        let content = pillStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGRect(x: Metrics.pillOrigin.x, y: Metrics.pillOrigin.y,
                      width: content.width + 48, height: Metrics.pillHeight)
    }

    private func setState(_ newState: State) {
        guard newState != state, transitionAnimator == nil else { return }
        state = newState
        applyState(expanded: newState == .expanded, animated: true)
    }

    private func applyState(expanded: Bool, animated: Bool) {
        let targetFrame = expanded ? panelFrame : pillFrame
        let targetRadius = expanded ? Metrics.panelCornerRadius : Metrics.pillHeight / 2
        collectionView.isHidden = false
        cardView.alpha = 1
        // The chevron belongs to the collapsed pill only; it never shows while
        // the panel is open.
        let chevronTarget: CGFloat = expanded ? 0 : (pillHidden ? 0 : 1)
        guard animated else {
            cardView.frame = targetFrame
            cardView.layer.cornerRadius = targetRadius
            dimmingView.alpha = expanded ? Metrics.dimAlpha : 0
            collectionView.alpha = expanded ? 1 : 0
            pillStack.alpha = expanded ? 0 : 1
            pillChevron.alpha = chevronTarget
            collectionView.isHidden = !expanded
            if !expanded, pillHidden { cardView.alpha = 0 }
            view.setNeedsLayout()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return
        }
        let animator = UIViewPropertyAnimator(duration: Metrics.morphDuration,
                                              dampingRatio: Metrics.morphDamping) {
            self.cardView.frame = targetFrame
            self.cardView.layer.cornerRadius = targetRadius
            self.dimmingView.alpha = expanded ? Metrics.dimAlpha : 0
            self.collectionView.alpha = expanded ? 1 : 0
            self.pillStack.alpha = expanded ? 0 : 1
            self.pillChevron.alpha = chevronTarget
        }
        animator.addCompletion { _ in
            self.transitionAnimator = nil
            if self.state == .collapsed {
                // A hidden list is invisible to the focus engine; alpha 0 is not.
                self.collectionView.isHidden = true
                // pillHidden can flip mid-morph: a below-top focus change posts
                // while this animator is in flight, and setPillHidden bails on a
                // live transition. Reconcile BOTH the card and its chevron here,
                // or the chevron is left stranded visible over a hidden pill.
                let pillAlpha: CGFloat = self.pillHidden ? 0 : 1
                self.cardView.alpha = pillAlpha
                self.pillChevron.alpha = pillAlpha
            }
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
        transitionAnimator = animator
        animator.startAnimation()
    }

    // MARK: Views

    private func buildViews() {
        dimmingView.backgroundColor = .black
        dimmingView.frame = view.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimmingView)

        cardView.layer.cornerCurve = .continuous
        cardView.layer.masksToBounds = true
        view.addSubview(cardView)

        glassView.frame = cardView.bounds
        glassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cardView.addSubview(glassView)

        collectionView = SidebarCollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        // The card is the frame of reference; without this the scroll view
        // adds the window safe-area top (6pt at this geometry) to the list.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        // Off: initial focus is directed at the selected tab, not the last
        // one the user happened to touch (see aimInitialFocusAtSelectedTab).
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.register(ShellSidebarRowCell.self,
                                forCellWithReuseIdentifier: ShellSidebarRowCell.reuseIdentifier)
        collectionView.register(ShellSidebarHeaderView.self,
                                forSupplementaryViewOfKind: ShellSidebarHeaderView.elementKind,
                                withReuseIdentifier: ShellSidebarHeaderView.reuseIdentifier)
        cardView.addSubview(collectionView)

        // Back-chevron, as the system pill shows: OUTSIDE the capsule, to its
        // left, white. Custom-drawn (see PillChevronView) to match the system
        // pill's tall-narrow proportion. Lives on the main view (not the glass
        // card) so it sits outside the glass, and fades with the pill.
        pillChevron.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pillChevron)

        pillIcon.tintColor = .white
        pillIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        pillLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        pillLabel.textColor = .white
        pillStack.addArrangedSubview(pillIcon)
        pillStack.addArrangedSubview(pillLabel)
        pillStack.axis = .horizontal
        pillStack.spacing = 12
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(pillStack)

        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            pillStack.centerYAnchor.constraint(equalTo: cardView.topAnchor,
                                               constant: Metrics.pillHeight / 2),
            // Chevron sits just left of the collapsed pill, vertically centered
            // on it. The pill's left edge is at pillOrigin.x.
            pillChevron.trailingAnchor.constraint(equalTo: view.leadingAnchor,
                                                  constant: Metrics.pillOrigin.x - 12),
            pillChevron.centerYAnchor.constraint(equalTo: view.topAnchor,
                                                 constant: Metrics.pillOrigin.y + Metrics.pillHeight / 2),
        ])
    }

    /// The list keeps its full panel-state size and lets the shrinking card
    /// CLIP it (with a fade), matching the portal look of the system morph;
    /// resizing the list itself would squish rows mid-animation.
    private func layoutListInCard() {
        collectionView.frame = CGRect(
            x: Metrics.contentLeading,
            y: Metrics.contentTop,
            width: Metrics.panelWidth - Metrics.contentLeading - Metrics.contentTrailing,
            height: panelFrame.height - Metrics.contentTop - Metrics.contentBottom)
    }

    private func configurePill(_ item: ShellSidebarItem) {
        pillIcon.image = UIImage(systemName: item.icon)
        pillLabel.text = item.title
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                  heightDimension: .absolute(Metrics.rowPitch))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            // Window safe-area insets (80 leading / 60 top) must not shift
            // rows: the card's own geometry is the only frame of reference.
            section.contentInsetsReference = .none
            section.interGroupSpacing = 0
            // Measured: every section break is one 70pt gap; a titled section
            // draws its header inside the gap, an untitled one leaves it empty.
            if self?.sections[sectionIndex].title != nil {
                let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                        heightDimension: .absolute(Metrics.sectionGap))
                section.boundarySupplementaryItems = [
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: headerSize,
                        elementKind: ShellSidebarHeaderView.elementKind,
                        alignment: .top)
                ]
            } else if sectionIndex > 0 {
                section.contentInsets = NSDirectionalEdgeInsets(top: Metrics.sectionGap,
                                                                leading: 0, bottom: 0, trailing: 0)
            }
            return section
        }
    }

    // MARK: Data

    private static func liveSections() -> [ShellSidebarSection] {
        let defaults = UserDefaults.standard
        func flag(_ key: String, default fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        let profileName = PlexUserProfileManager.shared.selectedUser?.displayName
            ?? PlexAuthManager.shared.username
            ?? "Account"
        return ShellSidebarModel.sections(
            libraries: PlexDataStore.shared.visibleMediaLibraries,
            liveTVSources: LiveTVDataStore.shared.sources,
            combineLiveTV: flag("combineLiveTVSources", default: true),
            showDiscover: flag("showDiscoverTab", default: true),
            discoverAbove: flag("discoverAboveLibraries", default: true),
            liveTVAbove: flag("liveTVAboveLibraries", default: false),
            serverName: PlexAuthManager.shared.savedServerName,
            profileName: profileName)
    }

    private func item(for tab: SidebarTab) -> ShellSidebarItem {
        for section in sections {
            if let match = section.items.first(where: { $0.tab == tab }) { return match }
        }
        return ShellSidebarItem(tab: .home, title: "Home", icon: "house.fill")
    }

}

// MARK: - Collection view

extension ShellSidebarViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ShellSidebarRowCell.reuseIdentifier,
            for: indexPath) as! ShellSidebarRowCell
        let item = sections[indexPath.section].items[indexPath.item]
        cell.configure(item: item, isSelectedTab: item.tab == selectedTab)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: ShellSidebarHeaderView.reuseIdentifier,
            for: indexPath) as! ShellSidebarHeaderView
        header.label.text = sections[indexPath.section].title
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let tab = sections[indexPath.section].items[indexPath.item].tab
        select(tab: tab)
        if embedded { onTabSelected?(tab) }
    }

    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        // Containment: while expanded, focus stays inside the sidebar; the
        // shell moves it out explicitly on collapse (state flips first, so
        // that move is never blocked).
        guard embedded, state == .expanded else { return true }
        if let nextView = context.nextFocusedView, !nextView.isDescendant(of: view) {
            return false
        }
        return true
    }

    private func select(tab: SidebarTab) {
        selectedTab = tab
        configurePill(item(for: tab))
        collectionView.reloadData()
    }
}
