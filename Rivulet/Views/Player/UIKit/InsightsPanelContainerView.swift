// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsPanelContainerView.swift
//  Rivulet
//
//  The Insights tab of the player's info pane, in the same glass box as Info
//  and Details. Its sub-tabs (Top 10, Cast, one per trivia category) sit on the
//  rail's pill row; this view shows the selected one as a row of cards.
//  Selecting a cast member crossfades the box to their bio and filmography
//  while the video keeps playing; Menu crossfades back.
//

import UIKit

final class InsightsPanelContainerView: UIView, RailPanelMenuHandling {

    private enum Metrics {
        static let height: CGFloat = 250
        static let radius: CGFloat = 48
        static let crossfadeDuration: TimeInterval = 0.2
    }

    private enum State {
        case list
        case actor
    }

    let availableTabs: [InsightsTab]
    private(set) var currentTab: InsightsTab
    private let listView: InsightsCastListView
    private let provider: PersonFilmographyProviding
    /// Internal for tests: the actor view a selection built, until Menu tears it down.
    private(set) var actorView: InsightsActorView?
    private let coordinator = InsightsActorLoadCoordinator()
    private var state: State = .list

    init(
        cast: [MediaPerson],
        trivia: TitleTrivia? = nil,
        suppressedTriviaIDs: Set<String> = [],
        provider: PersonFilmographyProviding = PersonFilmographyProvider()
    ) {
        let tabs = InsightsTab.availableTabs(cast: cast, trivia: trivia, suppressedTriviaIDs: suppressedTriviaIDs)
        availableTabs = tabs
        // Top 10 leads when it exists: it is the curated highlight reel.
        currentTab = tabs.first(where: { $0 == .topTen }) ?? tabs.first ?? .cast
        listView = InsightsCastListView(
            cast: cast, trivia: trivia, suppressedTriviaIDs: suppressedTriviaIDs,
            initialTab: currentTab, onSelectCast: { _ in })
        self.provider = provider
        super.init(frame: .zero)

        let glass = makePaneGlass(cornerRadius: Metrics.radius)
        [glass, listView].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        listView.onSelectCast = { [weak self] person in self?.crossfadeToActor(person) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A sub-tab gained focus on the pill row.
    func select(_ tab: InsightsTab) {
        guard tab != currentTab else { return }
        currentTab = tab
        if state == .actor { reverseCrossfadeToList() }
        listView.setTab(tab)
    }

    // MARK: - Crossfade

    /// Internal for tests; in production only a cast card's Select calls it.
    func crossfadeToActor(_ person: MediaPerson) {
        guard state == .list else { return }
        let token = coordinator.begin()

        let actor = InsightsActorView(person: person)
        actor.translatesAutoresizingMaskIntoConstraints = false
        actor.alpha = 0
        addSubview(actor)
        NSLayoutConstraint.activate([
            actor.topAnchor.constraint(equalTo: topAnchor),
            actor.leadingAnchor.constraint(equalTo: leadingAnchor),
            actor.trailingAnchor.constraint(equalTo: trailingAnchor),
            actor.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        actorView = actor
        state = .actor
        // The faded list must not stay focusable underneath the actor.
        listView.isUserInteractionEnabled = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        UIView.animate(withDuration: Metrics.crossfadeDuration, animations: {
            self.listView.alpha = 0
            actor.alpha = 1
        }, completion: { [weak self] _ in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        })

        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.provider.load(person: person)
            // A newer selection or a return to the list drops this load.
            guard self.coordinator.isCurrent(token) else { return }
            if let result {
                actor.populate(result)
            } else {
                actor.showDetailsUnavailable()
            }
        }
    }

    /// Internal for tests; see `crossfadeToActor`.
    func reverseCrossfadeToList() {
        guard state == .actor, let actor = actorView else { return }
        coordinator.cancel()
        state = .list
        listView.isUserInteractionEnabled = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        UIView.animate(withDuration: Metrics.crossfadeDuration, animations: {
            actor.alpha = 0
            self.listView.alpha = 1
        }, completion: { [weak self] _ in
            actor.removeFromSuperview()
            if self?.actorView === actor { self?.actorView = nil }
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        })
    }

    // MARK: - Focus and Menu

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        switch state {
        case .list: return [listView]
        case .actor: return actorView.map { [$0] } ?? [listView]
        }
    }

    /// Menu first closes a reading bio, then the actor, then (declined) the pane.
    func handleMenuPress() -> Bool {
        guard state == .actor else { return false }
        if actorView?.handleMenuPress() == true { return true }
        reverseCrossfadeToList()
        return true
    }
}
