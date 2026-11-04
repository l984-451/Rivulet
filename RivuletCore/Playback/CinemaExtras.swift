// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Trailers and pre-roll videos before a movie (#491). The server picks them, from its Cinema
/// Trailers settings; the count is the only thing the client asks for.
enum CinemaExtras {
    static let countKey = "cinemaTrailersCount"
    static let countOptions = 0...5

    /// Off unless the user asked. Plex plays a server's pre-roll only with a count above 0 (measured).
    static var count: Int {
        min(max(UserDefaults.standard.integer(forKey: countKey), countOptions.lowerBound), countOptions.upperBound)
    }

    /// A movie started from its beginning, on its own. A resume or a playlist goes straight in.
    static func applies(type: String?, startOffset: TimeInterval?, inPlaylist: Bool, count: Int) -> Bool {
        count > 0 && type == "movie" && !inPlaylist && (startOffset ?? 0) <= 0
    }
}
