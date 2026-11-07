// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Search across every server, scoped to All, Movies or TV Shows. Parity source:
/// RivuletiOS/Search/IOSPlexSearchView.swift. Owns its `.searchable` field.
struct MacSearchView: View {
    @State private var query = ""

    var body: some View {
        MacFeaturePlaceholder(title: "Search", symbol: "magnifyingglass",
                              source: "RivuletiOS/Search/IOSPlexSearchView.swift")
            .navigationTitle("Search")
            .searchable(text: $query)
    }
}
