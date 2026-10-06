// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum StallVerdict: Equatable, Sendable {
    case ignored
    case counted
    case stepDown
}

/// Auto's step-down rule: two stalls within a minute. Seeks and loads buffer by design.
nonisolated struct StallTracker: Sendable {
    static let window: TimeInterval = 60
    static let longStall: TimeInterval = 10
    static let grace: TimeInterval = 5

    private var stalls: [Date] = []
    private var quietUntil: Date = .distantPast

    mutating func noteSeekOrLoad(at date: Date) {
        quietUntil = date.addingTimeInterval(Self.grace)
    }

    /// A step-down spends the stalls behind it; the new step starts with a clean count.
    mutating func noteStepDown() {
        stalls.removeAll()
    }

    mutating func bufferingStarted(at date: Date) -> StallVerdict {
        guard date >= quietUntil else { return .ignored }
        stalls = stalls.filter { date.timeIntervalSince($0) < Self.window } + [date]
        guard stalls.count >= 2 else { return .counted }
        stalls.removeAll()
        return .stepDown
    }

    /// A counted stall still going after this long steps down on its own.
    func isLongStall(startedAt start: Date, now: Date) -> Bool {
        now.timeIntervalSince(start) >= Self.longStall
    }
}
