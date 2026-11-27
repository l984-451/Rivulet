// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// The Favorites page's filter: every favorite, the unwatched ones or the watched ones.
/// A show counts as watched once the server marks it played (every episode seen).
enum FavoritesWatchFilter: String, CaseIterable, Sendable {
    case all, unwatched, watched

    static let storageKey = "favoritesWatchFilter"

    static var current: FavoritesWatchFilter {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(FavoritesWatchFilter.init(rawValue:)) ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .unwatched: String(localized: "Unwatched")
        case .watched: String(localized: "Watched")
        }
    }

    func apply(_ items: [MediaItem]) -> [MediaItem] {
        switch self {
        case .all: items
        case .unwatched: items.filter { !$0.userState.isPlayed }
        case .watched: items.filter(\.userState.isPlayed)
        }
    }
}
