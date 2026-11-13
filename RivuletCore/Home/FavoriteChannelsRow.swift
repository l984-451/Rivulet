// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  The Favorite Channels row on Home (#623): What's On's Favorites shelf, switched on in
//  Settings > Home > Rows (off by default). Ordered with the other rows by `identifier`.
//

import Foundation

nonisolated enum FavoriteChannelsRow {

    static let identifier = "rivulet.favorites.channels"

    static var title: String { String(localized: "Favorite Channels") }

    private static var shownKey: String { HomeSettingsScope.key("showHomeFavoriteChannels") }

    static var isShown: Bool { UserDefaults.standard.bool(forKey: shownKey) }

    static func setShown(_ shown: Bool) {
        UserDefaults.standard.set(shown, forKey: shownKey)
        NotificationCenter.default.post(name: HomeRowSettings.changedNotification, object: nil)
    }
}

extension LiveTVDataStore {
    /// Whether any channel is a favorite, so Settings offers the row.
    var offersHomeFavorites: Bool { !favorites(in: channels).isEmpty }

    /// The row's cards: What's On's Favorites shelf, every source's.
    var homeFavoriteCards: [LiveCardItem] {
        guard FavoriteChannelsRow.isShown else { return [] }
        return whatsOnShelves(sourceIdFilter: nil, favoritesOnly: true).first { $0.id == "favorites" }?.items ?? []
    }
}
