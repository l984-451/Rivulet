// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// See All for one Home or detail row, paged through the hub's own key. Parity source:
/// RivuletiOS/Plex/Home/IOSPlexHubGridView.swift. Placeholder shows the items the row already holds.
struct MacHubGridView: View {
    let hub: MediaHub

    var body: some View {
        ScrollView {
            MacPosterGrid(items: hub.items, loadMore: nil).padding(.vertical, 20)
        }
        .navigationTitle(hub.title)
    }
}
