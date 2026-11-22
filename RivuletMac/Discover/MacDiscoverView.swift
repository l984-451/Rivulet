// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Discover: TMDB's curated rows, as on tvOS. A title opens its page.
/// Parity source: RivuletiOS/Discover/IOSDiscoverView.swift.
struct MacDiscoverView: View {
    @State private var discover = DiscoverRows()

    var body: some View {
        Group {
            if !discover.rows.isEmpty {
                ScrollView {
                    // Not lazy: eight rows at most, each lazy inside.
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(discover.rows) { row in
                            MacRail(title: row.section.title, kind: .poster, items: row.items) { item, width in
                                MacTileButton(item: item) { MacPosterCard(item: item, width: width) }
                            }
                        }
                    }
                    .padding(.vertical, 24)
                }
            } else if discover.failed {
                MacErrorView(title: "Couldn't Load Discover", message: String(localized: "Try again in a moment.")) {
                    await discover.reload()
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Discover")
        .macPageRefresh { Task { await discover.reload() } }
        // Once: coming back from a title keeps the rows, and Refresh asks again.
        .task {
            if discover.rows.isEmpty { await discover.load() }
        }
    }
}
