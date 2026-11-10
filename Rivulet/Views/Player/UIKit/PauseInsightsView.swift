// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PauseInsightsView.swift
//  Rivulet
//
//  Insights raised over the pause screen by Down from its hint: the Insights
//  panel and its sub-tab pills, with none of the player chrome. Up past the top
//  or Menu closes it (`onClose`), back to the pause screen.
//

import UIKit

final class PauseInsightsView: UIView {

    private enum Metrics {
        static let pillGap: CGFloat = 30
        static let subTabGap: CGFloat = 16
    }

    var onClose: (() -> Void)?

    let insights: InsightsPanelContainerView
    private let pills = UIStackView()
    /// Up from the top row lands here, which closes the view.
    private let closeCatcher = FocusCatcher()
    /// Up from the panel returns to the shown tab's pill, Down from a pill enters the panel.
    private let returnGuide = UIFocusGuide()

    init(insights: InsightsPanelContainerView) {
        self.insights = insights
        super.init(frame: .zero)

        pills.axis = .horizontal
        pills.spacing = Metrics.subTabGap
        let tabs = insights.availableTabs.count > 1 ? insights.availableTabs : []
        for tab in tabs {
            let pill = PlayerInfoPillButton(title: tab.title, compact: true)
            pill.isSelectedTab = tab == insights.currentTab
            pills.addArrangedSubview(pill)
        }
        pills.isHidden = tabs.isEmpty

        for view in [closeCatcher, pills, insights] as [UIView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addLayoutGuide(returnGuide)
        returnGuide.preferredFocusEnvironments = [insights]
        // The panel sits under the pills, or straight under the catcher's gap without them.
        let panelTop = tabs.isEmpty
            ? insights.topAnchor.constraint(equalTo: closeCatcher.bottomAnchor, constant: Metrics.pillGap)
            : insights.topAnchor.constraint(equalTo: pills.bottomAnchor, constant: Metrics.pillGap)
        NSLayoutConstraint.activate([
            closeCatcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            closeCatcher.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeCatcher.topAnchor.constraint(equalTo: topAnchor),
            closeCatcher.heightAnchor.constraint(equalToConstant: 10),

            pills.leadingAnchor.constraint(equalTo: leadingAnchor),
            pills.topAnchor.constraint(equalTo: closeCatcher.bottomAnchor, constant: Metrics.pillGap),
            panelTop,

            insights.leadingAnchor.constraint(equalTo: leadingAnchor),
            insights.trailingAnchor.constraint(equalTo: trailingAnchor),
            insights.bottomAnchor.constraint(equalTo: bottomAnchor),

            returnGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            returnGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            returnGuide.topAnchor.constraint(equalTo: pills.bottomAnchor),
            returnGuide.bottomAnchor.constraint(equalTo: insights.topAnchor),
        ])
        returnGuide.isEnabled = !tabs.isEmpty
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [insights] }

    private var selectedPill: PlayerInfoPillButton? {
        pills.arrangedSubviews.compactMap { $0 as? PlayerInfoPillButton }.first { $0.isSelectedTab }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        if next === closeCatcher {
            // Next turn: the container's didUpdateFocus for this same move must still
            // see the panel up, or it counts the move as input and drops the pause screen.
            DispatchQueue.main.async { [weak self] in self?.onClose?() }
            return
        }
        // Focusing a pill switches to its tab, as on the rail.
        if let index = pills.arrangedSubviews.firstIndex(where: { $0 === next }),
           insights.availableTabs.indices.contains(index) {
            for case let (i, pill as PlayerInfoPillButton) in pills.arrangedSubviews.enumerated() {
                pill.isSelectedTab = i == index
            }
            insights.select(insights.availableTabs[index])
        }
        returnGuide.preferredFocusEnvironments = next.isDescendant(of: insights)
            ? selectedPill.map { [$0] } ?? [] : [insights]
    }

    /// Menu closes an open actor first, then the view.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else {
            super.pressesBegan(presses, with: event)
            return
        }
        if !insights.handleMenuPress() { onClose?() }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else {
            super.pressesEnded(presses, with: event)
            return
        }
    }

    /// An invisible focus stop; clear but not hidden, so the engine can land on it.
    private final class FocusCatcher: UIView {
        override var canBecomeFocused: Bool { true }
    }
}
