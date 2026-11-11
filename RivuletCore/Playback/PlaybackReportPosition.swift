// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

struct PlaybackReportPosition {
    private var position: TimeInterval

    init(startTime: TimeInterval = 0) {
        position = startTime
    }

    mutating func resolve(_ time: TimeInterval, isLoading: Bool, isStarting: Bool, hasStarted: Bool = true) -> TimeInterval {
        if hasStarted, !isLoading, !isStarting { position = time }
        return position
    }
}
