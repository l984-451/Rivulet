// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ShuttleGrammar.swift
//  Rivulet
//
//  Pure FF/RW shuttle grammar: click-and-hold enters shuttle at level 1,
//  clicks in the same direction bump up to the level 8 cap, clicks in the
//  opposite direction step down THROUGH zero into the opposite direction.
//  Levels 1-4 are AVKit's (`AVScrubbingController.defaultScrubbingRates`,
//  8x/24x/48x/96x); 5-8 keep doubling past AVKit's cap. The bar numbers
//  levels from 2 as AVKit does.
//

import Foundation

nonisolated enum ShuttleGrammar {
    static let maxLevel = 8

    /// Content-seconds per real-second at each level.
    static let ratesPerLevel: [TimeInterval] = [0, 8, 24, 48, 96, 192, 384, 768, 1536]

    static func step(current: Int, clickForward: Bool) -> Int {
        let clickSign = clickForward ? 1 : -1
        if current == 0 { return clickSign }
        if (current > 0) == clickForward {
            return min(abs(current) + 1, maxLevel) * clickSign
        }
        // Opposite direction: step toward zero, then CROSS into the opposite
        // direction rather than stopping on it. Landing on zero routed to
        // `cancelScrub()`, which restores the pre-shuttle position — so
        // stepping down to level 1 and clicking once more threw away everything
        // the user had just shuttled past and resumed where they started.
        // Select still commits and Down still cancels; those are the exits.
        let stepped = (abs(current) - 1) * (current > 0 ? 1 : -1)
        return stepped == 0 ? clickSign : stepped
    }

    static func rate(forLevel level: Int) -> TimeInterval {
        let idx = min(abs(level), maxLevel)
        return ratesPerLevel[idx]
    }
}
