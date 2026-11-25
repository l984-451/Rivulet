// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What a channel airs from now on, as a viewer reads it: real programmes
/// only, never a placeholder for a channel without guide data or an empty
/// slot the guide fills a gap with.
nonisolated enum LiveSchedule {
    static func isListed(_ program: UnifiedProgram) -> Bool {
        !program.id.contains(":placeholder:") && !program.isEmptySlot
    }

    /// The programme on now, when it is listed, then the ones after it in
    /// airing order, at most `limit`.
    static func upcoming(in programs: [UnifiedProgram], now: Date, limit: Int) -> [UnifiedProgram] {
        Array(programs
            .filter { $0.endTime > now && isListed($0) }
            .sorted { $0.startTime < $1.startTime }
            .prefix(limit))
    }

    /// The first listed programme that starts after `now`.
    static func next(in programs: [UnifiedProgram], now: Date) -> UnifiedProgram? {
        programs
            .filter { $0.startTime > now && isListed($0) }
            .min { $0.startTime < $1.startTime }
    }
}
