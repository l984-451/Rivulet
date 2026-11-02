// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A decorative video session. Cleanup only releases server resources; it must
/// never report viewing progress or mark the title as watched.
nonisolated struct ThemeVideo: Sendable {
    let url: URL
    var stop: @Sendable () async -> Void = {}
}
