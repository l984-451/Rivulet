// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// How much disk one direct-play session's read-ahead may fill. Without it a whole-film
/// prefetch takes a quarter of free space, 17 GB on a 4K Apple TV (#777).
enum PlaybackDiskBudget {
    nonisolated static let sessionCacheBytes = 4 << 30
}
