// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Discover tab root: TMDB's curated rows, as on tvOS. A title opens its page.
/// The root supplies the NavigationStack.
struct IOSDiscoverView: View {
    @State private var discover = DiscoverRows()

    var body: some View {
        Group {
            if !discover.rows.isEmpty {
                ScrollView {
                    // Not lazy: eight rows at most, each lazy inside. A lazy stack rebuilt rows as they
                    // scrolled back in, and each first laid out header-only, so the page jumped.
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(discover.rows) { row in
                            IOSPlexRail(title: row.section.title, kind: .poster, items: row.items) {
                                IOSPlexPosterCard(item: $0, width: $1)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable { await discover.reload() }
            } else if discover.failed {
                IOSPlexErrorView(title: "Couldn't Load Discover", message: String(localized: "Try again in a moment.")) {
                    await discover.reload()
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Discover")
        .toolbar {
            IOSAccountToolbarItem()
        }
        // Once: a tab switch keeps the rows, and pull to refresh asks again.
        .task {
            if discover.rows.isEmpty { await discover.load() }
        }
    }
}
