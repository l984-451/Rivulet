// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The one pair of Skip Length keys both apps read, so the setting can sync.
nonisolated enum SkipLengthKeys {
    static let forward = "skipForwardSeconds"
    static let back = "skipBackSeconds"
    /// The lengths both apps offer, so a synced value is always one the other app can show. Each has a numbered SF Symbol.
    static let options = [5, 10, 15, 30, 60]

    /// Old key to current key: tvOS `skipSeconds`, iOS `playerSkip{Forward,Backward}Seconds`.
    static let legacy: [(old: String, new: String)] = [
        ("skipSeconds", forward),
        ("playerSkipForwardSeconds", forward),
        ("playerSkipBackwardSeconds", back),
    ]

    /// Moves an old key's value to its new name once. A value already under the new name wins.
    static func migrateLegacyKeys(in defaults: UserDefaults = .standard) {
        for (old, new) in legacy {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
            defaults.removeObject(forKey: old)
        }
    }
}
