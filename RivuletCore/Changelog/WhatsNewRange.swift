// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// Which changelog entries the launch What's New shows: every build after the last one seen,
/// up to the running one. Keys are "<version> (<build>)"; builds only grow on each platform.
enum WhatsNewRange {
    /// At most this many entries, the newest.
    static let limit = 5

    /// `versions` is newest first; the result keeps that order.
    static func versions(_ versions: [String], current: String, lastSeen: String) -> [String] {
        guard let now = build(current) else { return [] }
        // Nothing seen before (or unreadable): just this build's notes, as before.
        guard let seen = build(lastSeen) else { return versions.filter { $0 == current } }
        return Array(versions.filter { guard let b = build($0) else { return false }; return b > seen && b <= now }
            .prefix(limit))
    }

    /// The build number in "1.3.0 (125)".
    static func build(_ key: String) -> Int? {
        guard let open = key.lastIndex(of: "("), key.hasSuffix(")") else { return nil }
        return Int(key[key.index(after: open)..<key.index(before: key.endIndex)])
    }
}
