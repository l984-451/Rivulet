// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Every server's favorite movies, then shows (`FavoritesFeed`). Parity source:
/// RivuletiOS/Plex/Library/IOSFavoritesView.swift.
struct MacFavoritesView: View {
    var body: some View {
        MacFeaturePlaceholder(title: "Favorites", symbol: "heart",
                              source: "RivuletiOS/Plex/Library/IOSFavoritesView.swift")
            .navigationTitle("Favorites")
    }
}
