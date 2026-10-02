// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoTabsView.swift
//  Rivulet
//
//  Tabbed content for the player's Now Playing Info popup: a Description tab
//  (`CardDescriptionView`, title + summary), an Info tab (static `CardInfoView`
//  metadata) and an Advanced tab (`CardStatsView` live "stats for nerds"
//  telemetry). Sibling of `InsightsPanelContainerView` for the trivia panel,
//  simpler (no crossfade sub-state).
//
//  Not every tab exists for every item: Description needs a summary, and
//  Advanced needs the aether route (a non-nil advanced provider closure). Info
//  is always present, so an item with neither renders just the Info sheet with
//  no tab bar, exactly as the popup did before. Description leads when present
//  — reading the description is what the Info button is reached for (#267). The
//  Advanced sheet is built lazily on the first tab-over and ticks only while it
//  is the visible tab.
//
//  Focus: the sheets expose one invisible focus target per two-up ROW
//  (`InfoFocusRowView`), so the tab bar ↔ content crossings are ordinary
//  focus-engine moves that work identically for swipes and edge clicks — no
//  press handling here. (The previous single-focusable-sheet design drove
//  both crossings from arrow presses, which a Siri Remote swipe never
//  produces, so it only worked from clicks.)
//
//  Menu: intentionally does NOT conform to `RailPanelMenuHandling`, so
//  `PlayerRailPanelView` dismisses the whole panel from either tab.
//

import UIKit
import os

/// TEMP diagnostic instrumentation for the intermittent "Info tab doesn't
/// switch" / "can't move Down into the tab's content" reports — no confirmed
/// repro yet (simulator can't reliably reproduce tvOS focus behavior), so
/// this traces the actual on-device sequence for the next session. Remove
/// once the real cause is confirmed from a captured log.
private let infoTabLog = Logger(subsystem: "com.rivulet.app", category: "PlayerInfoTab")

final class PlayerInfoTabsView: UIView {

    /// One selectable tab in the Info popup's pill bar. Rendered by the shared
    /// `PillTabBarView` (same bar as the Insights panel), which addresses tabs
    /// by index into `availableTabs`.
    enum Tab {
        case description
        case info
        case advanced

        var title: String {
            switch self {
            case .description: return "Description"
            case .info: return "Info"
            case .advanced: return "Advanced"
            }
        }
    }

    private enum Metrics {
        static let tabBarSpacing: CGFloat = 16
    }

    private let descriptionView: CardDescriptionView?
    private let infoView: CardInfoView
    private var statsView: CardStatsView?
    private let advancedProvider: (() -> AetherAdvancedStats?)?
    private let availableTabs: [Tab]
    private let tabBar: PillTabBarView?
    private var currentTab: Tab

    private var contentTopAnchor: NSLayoutYAxisAnchor!
    private var contentTopConstant: CGFloat = 0
    private var contentSideInset: CGFloat = 0

    /// Forwarded to whichever content sheet holds focus, so the hosting panel
    /// can brighten its ring while the sheet is focused (the sheet is one big
    /// scroll target with no internal highlight of its own).
    var onFocusChange: ((Bool) -> Void)? {
        didSet {
            descriptionView?.onFocusChange = onFocusChange
            infoView.onFocusChange = onFocusChange
            statsView?.onFocusChange = onFocusChange
        }
    }

    /// The tabs available for one item, in display order — pure so it is
    /// unit-testable. Info always exists; the other two are conditional.
    static func tabs(hasDescription: Bool, hasAdvanced: Bool) -> [Tab] {
        var tabs: [Tab] = []
        if hasDescription { tabs.append(.description) }
        tabs.append(.info)
        if hasAdvanced { tabs.append(.advanced) }
        return tabs
    }

    /// A lone tab names itself in no bar at all.
    static func showsTabBar(hasDescription: Bool, hasAdvanced: Bool) -> Bool {
        tabs(hasDescription: hasDescription, hasAdvanced: hasAdvanced).count > 1
    }

    init(
        metadata: PlexMetadata,
        modes: StreamingModeInfo,
        advancedProvider: (() -> AetherAdvancedStats?)?
    ) {
        let hasDescription = !CardDescriptionView.paragraphs(of: metadata.summary).isEmpty
        let tabs = Self.tabs(hasDescription: hasDescription, hasAdvanced: advancedProvider != nil)
        self.descriptionView = hasDescription ? CardDescriptionView(metadata: metadata) : nil
        self.infoView = CardInfoView(metadata: metadata, modes: modes)
        self.advancedProvider = advancedProvider
        self.currentTab = tabs[0]
        self.availableTabs = tabs
        self.tabBar = tabs.count > 1 ? PillTabBarView(titles: tabs.map(\.title), selectedIndex: 0) : nil
        super.init(frame: .zero)
        setup()

        // Swipe twin of the Down crossing in pressesBegan (pills → sheet),
        // gated on the same predicates so a declined swipe stays with the
        // focus engine. The iPhone Remote emits no arrow presses.
        entrySwipe = DirectionalInputBinding(
            gatedSwipesOn: self,
            directions: [.down],
            shouldHandle: { [weak self] _ in
                guard let self, let tabBar = self.tabBar else { return false }
                return tabBar.containsFocus && self.currentContentView.infoScrollView.needsFocusableRows
            },
            onSwipe: { [weak self] _ in
                guard let self else { return }
                infoTabLog.notice("driving focus: pills → content (swipe)")
                self.moveFocus(to: self.currentContentView)
            }
        )
    }

    private var entrySwipe: DirectionalInputBinding?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        infoView.translatesAutoresizingMaskIntoConstraints = false
        infoView.isHidden = currentTab != .info
        addSubview(infoView)
        wireUpwardEscape(infoView)

        if let descriptionView {
            descriptionView.translatesAutoresizingMaskIntoConstraints = false
            descriptionView.isHidden = currentTab != .description
            addSubview(descriptionView)
            wireUpwardEscape(descriptionView)
        }

        if let tabBar {
            tabBar.translatesAutoresizingMaskIntoConstraints = false
            tabBar.onSelect = { [weak self] index in
                guard let self, self.availableTabs.indices.contains(index) else { return }
                self.handleTabSelected(self.availableTabs[index])
            }
            addSubview(tabBar)
            NSLayoutConstraint.activate([
                tabBar.topAnchor.constraint(equalTo: topAnchor),
                tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            contentTopAnchor = tabBar.bottomAnchor
            contentTopConstant = Metrics.tabBarSpacing
            // Match the bar's own pill inset so a sheet's leading text edge
            // lines up with the pill capsules above it, the same relationship
            // the Insights panel gets from its matching `rowInset`. Without a
            // bar there is nothing to align to, so the sheet stays flush.
            contentSideInset = PillTabBarView.contentInset
        } else {
            contentTopAnchor = topAnchor
            contentTopConstant = 0
            contentSideInset = 0
        }
        // Each sheet insets its own content by the row highlight's outset
        // (`InfoScrollView.pinContent`); widen the sheet by the same amount so
        // the text edge stays put and only the highlight gains room.
        contentSideInset -= InfoFocusRowView.Focus.outsetX

        // FIXED height, not self-sized. Each sheet still carries a breakable
        // self-sizing constraint for the surfaces that want a panel that hugs
        // its content, but the Info popup is not one of them: its three sheets
        // are different lengths and the Advanced sheet GROWS as telemetry
        // arrives, so a self-sized panel resized under the user while they were
        // reading it and changed height when they switched tabs. Pinning it
        // here breaks each sheet's self-sizing constraint (required beats
        // `.defaultHigh`), so every sheet gets the same viewport and simply
        // scrolls when it has more to show.
        heightAnchor.constraint(equalToConstant: PlayerRailPanelView.fullContentHeight).isActive = true

        constrainToContentArea(infoView)
        if let descriptionView { constrainToContentArea(descriptionView) }
    }

    /// Pins a content sheet to the area below the tab bar (or the whole view
    /// when there is no tab bar).
    private func constrainToContentArea(_ view: UIView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentTopAnchor, constant: contentTopConstant),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentSideInset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentSideInset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Tab switching

    private func handleTabSelected(_ tab: Tab) {
        infoTabLog.notice("tab select requested: \(String(describing: tab), privacy: .public) (current: \(String(describing: self.currentTab), privacy: .public))")
        guard tab != currentTab else {
            infoTabLog.notice("tab select no-op: already on \(String(describing: tab), privacy: .public)")
            return
        }
        currentTab = tab
        if tab == .advanced { _ = ensureStatsView() }
        descriptionView?.isHidden = tab != .description
        infoView.isHidden = tab != .info
        statsView?.isHidden = tab != .advanced
        statsView?.setActive(tab == .advanced)
    }

    /// Builds the Advanced sheet on first use. Only reachable when a tab bar
    /// exists, which requires a non-nil `advancedProvider`.
    private func ensureStatsView() -> CardStatsView {
        if let statsView { return statsView }
        let provider = advancedProvider ?? { nil }
        let stats = CardStatsView(provider: provider)
        stats.translatesAutoresizingMaskIntoConstraints = false
        stats.isHidden = true
        stats.onFocusChange = onFocusChange
        addSubview(stats)
        constrainToContentArea(stats)
        wireUpwardEscape(stats)
        statsView = stats
        return stats
    }

    // MARK: - Focus

    private var currentContentView: InfoTabSheet {
        switch currentTab {
        case .description: return descriptionView ?? infoView
        case .info: return infoView
        case .advanced: return statsView ?? infoView
        }
    }

    /// Set for the duration of one driven focus update — see `moveFocus(to:)`.
    private var focusEscapeTarget: UIView?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let focusEscapeTarget { return [focusEscapeTarget] }
        // Otherwise prefer the EXACT view that already holds focus, so a
        // re-resolution (e.g. a directional press that finds no spatial target
        // at the content's bottom edge) is a strict no-op instead of bouncing
        // focus to the tab bar or to a different row. Only the INITIAL landing
        // (focus not yet inside the content) falls through to the tab bar.
        if let focused = focusedViewInContent {
            infoTabLog.notice("preferredFocusEnvironments: re-affirming focused view in content")
            return [focused]
        }
        if let tabBar {
            infoTabLog.notice("preferredFocusEnvironments: landing on tab bar")
            return [tabBar]
        }
        infoTabLog.notice("preferredFocusEnvironments: landing on content (no tab bar)")
        return [currentContentView]
    }

    /// Points `preferredFocusEnvironments` at `target` for exactly one update.
    /// `setNeedsFocusUpdate` is ignored unless the requesting environment
    /// CONTAINS focus, so the request has to come from here — the common
    /// ancestor of the pills and the sheet rows — and not from either side.
    /// Same mechanism as `InsightsPanelContainerView.moveFocus(to:)`.
    private func moveFocus(to target: UIView) {
        focusEscapeTarget = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        focusEscapeTarget = nil
    }

    /// Drives Down from the pills into the visible sheet. It does not happen
    /// natively: the pills and the sheet rows live in separate self-driven
    /// scroll views and the focus engine's directional search does not reliably
    /// cross that boundary — Down did nothing at all on device.
    /// `InsightsPanelContainerView` reached the same conclusion for the trivia
    /// panel and drives its crossings the same way.
    ///
    /// The way back up is the sheet's own `onDeclinedUpPress` (wired in
    /// `wireUpwardEscape`), not a branch here: only the scroll view knows
    /// whether an Up press still had somewhere to scroll.
    ///
    /// A sheet that fits on screen is skipped entirely — its rows are not even
    /// focusable (see `InfoFocusRowView.canBecomeFocused`), so Down stays on
    /// the pills rather than walking focus into content that cannot scroll.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let tabBar {
            for press in presses where press.type == .downArrow {
                guard tabBar.containsFocus else { break }
                guard currentContentView.infoScrollView.needsFocusableRows else {
                    infoTabLog.notice("Down ignored: sheet fits, no focus needed in content")
                    return
                }
                infoTabLog.notice("driving focus: pills → content")
                moveFocus(to: currentContentView)
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    /// Gives a sheet its way back to the pills. Called once per sheet, as each
    /// is built.
    private func wireUpwardEscape(_ sheet: InfoTabSheet) {
        sheet.infoScrollView.onDeclinedUpPress = { [weak self] in
            guard let self, let tabBar = self.tabBar else { return }
            infoTabLog.notice("driving focus: content → pills")
            self.moveFocus(to: tabBar)
        }
    }

    /// The currently focused view, if it sits inside the visible content
    /// sheet (as opposed to the tab bar, or nowhere yet on first appearance).
    ///
    /// `canBecomeFocused` is re-checked because it can change under focus: the
    /// Advanced sheet's rows come and go with the telemetry, and once it fits
    /// on screen its rows stop being focus targets. Re-affirming a view that
    /// can no longer take focus would wedge the update.
    private var focusedViewInContent: UIView? {
        guard let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView else { return nil }
        guard focused === currentContentView || focused.isDescendant(of: currentContentView) else { return nil }
        return focused.canBecomeFocused ? focused : nil
    }
}
