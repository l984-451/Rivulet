// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// A server's content rating as the detail pages show it. "NR", "Not Rated" and "Unrated"
/// say there is no rating, so they show nothing, as the Apple TV app shows no badge then.
enum ContentRatingDisplay {
    private static let unrated: Set<String> = ["nr", "not rated", "unrated", "n/a"]

    static func shown(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              !unrated.contains(value.lowercased()) else { return nil }
        return value
    }
}
