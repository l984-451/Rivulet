// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// When a failed route hands over to the other one, for all three apps. Each item switches once:
/// whichever route fails first may hand over, and the route it hands to never hands back.
nonisolated enum RouteFallback {
    /// The file failing, at start or mid-play, hands over to the server transcode.
    /// Nothing to transcode for a download or a stacked title (a transcode plays the first file only).
    static func transcodesAfterOriginalFailure(plan: StreamPlan, hasSwitched: Bool, isLocal: Bool, isStacked: Bool) -> Bool {
        plan == .original && !hasSwitched && !isLocal && !isStacked
    }

    /// A transcode that quality chose (Auto's step, the menu) failing hands over to the file.
    /// A relay has no file route.
    static func playsOriginalAfterTranscodeFailure(plan: StreamPlan, hasSwitched: Bool, isRelay: Bool) -> Bool {
        plan.step != nil && !hasSwitched && !isRelay
    }
}
