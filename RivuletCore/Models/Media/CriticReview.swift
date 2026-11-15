// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CriticReview.swift
//  Rivulet
//
//  One critic's excerpt. Strings are server text and are shown verbatim.
//

import Foundation

nonisolated struct CriticReview: Sendable, Hashable {
    enum Verdict: Sendable, Hashable {
        case fresh, rotten

        var label: String {
            switch self {
            case .fresh: String(localized: "Fresh")
            case .rotten: String(localized: "Rotten")
            }
        }
        /// SF Symbol for the verdict mark.
        var symbol: String {
            switch self {
            case .fresh: "hand.thumbsup.fill"
            case .rotten: "hand.thumbsdown.fill"
            }
        }
    }

    let critic: String?
    let outlet: String?
    let verdict: Verdict?
    let excerpt: String

    /// "Critic, Outlet", whichever exist.
    var byline: String? {
        let parts = [critic, outlet].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
