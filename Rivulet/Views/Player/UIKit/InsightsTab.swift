// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsTab.swift
//  Rivulet
//
//  Which tabs the Insights panel offers, and what they are called
//  (Docs/superpowers/specs/2026-07-08-insights-toptrivia-tabs-design.md):
//  Top 10, Cast, then one pill per category that has visible facts. Pure
//  domain logic — the rail's pill row renders these as Insights' sub-tabs.
//

import Foundation

/// One selectable tab in the Insights panel's pill bar.
enum InsightsTab: Hashable {
    case topTen
    case cast
    case category(TriviaCategory)

    var title: String {
        switch self {
        case .topTen: return "Top 10"
        case .cast: return "Cast"
        case .category(let category): return category.tabDisplayName
        }
    }

    /// Which tabs should be offered given the panel's current cast/trivia
    /// inputs — pure, no UIKit dependency, directly unit-testable. Order:
    /// Top 10 (if >=1 qualifying fact), Cast (if non-empty), then one pill
    /// per `TriviaCategory` (in `TriviaCategory.allCases` declaration order)
    /// that has >=1 visible fact after suppression filtering.
    static func availableTabs(
        cast: [MediaPerson],
        trivia: TitleTrivia?,
        suppressedTriviaIDs: Set<String>
    ) -> [InsightsTab] {
        var tabs: [InsightsTab] = []
        if let trivia, !trivia.topTenFacts(suppressed: suppressedTriviaIDs).isEmpty {
            tabs.append(.topTen)
        }
        if !cast.isEmpty {
            tabs.append(.cast)
        }
        if let trivia {
            let visible = trivia.visibleFacts(suppressed: suppressedTriviaIDs)
            for category in TriviaCategory.allCases where visible.contains(where: { $0.category == category }) {
                tabs.append(.category(category))
            }
        }
        return tabs
    }
}
