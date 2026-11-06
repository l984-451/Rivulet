// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

enum PlexPartKey {
    /// Split a Part key into its path and any query items it already carries.
    ///
    /// Handles the key arriving either raw (`...mp4?fmt=4`) or already
    /// percent-encoded (`...mp4%3Ffmt=4`) — assigning the latter to
    /// `URLComponents.path` would double-encode it to `%253F`.
    static func split(_ key: String) -> (path: String, queryItems: [URLQueryItem]) {
        // Normalize an encoded delimiter so both spellings take the same path.
        // Only the FIRST %3F is the delimiter; anything after it belongs to the
        // query string and is left alone.
        var working = key
        if !key.contains("?"), let encoded = key.range(of: "%3F", options: [.caseInsensitive]) {
            working = key.replacingCharacters(in: encoded, with: "?")
        }

        guard let split = working.firstIndex(of: "?") else {
            return (working, [])
        }
        let path = String(working[working.startIndex..<split])
        let query = String(working[working.index(after: split)...])
        // Parse via URLComponents so escaping in the values is preserved.
        let items = URLComponents(string: "?" + query)?.queryItems ?? []
        return (path, items)
    }
}
