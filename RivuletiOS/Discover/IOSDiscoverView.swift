// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Discover tab root: TMDB's curated rows, as on tvOS. A title opens its page, or your own copy
/// when a server has it. The root supplies the NavigationStack.
struct IOSDiscoverView: View {
    @State private var discover = DiscoverRows()
    @State private var ownership = DiscoverOwnership()
    /// The `ownershipKey` the last finished check ran for.
    @State private var checked: [String]?
    @EnvironmentObject private var browse: BrowseStore

    var body: some View {
        // Read here, not in a tile, so every row redraws as answers arrive.
        let copies = ownership.copies
        Group {
            if !discover.rows.isEmpty {
                ScrollView {
                    // Not lazy: eight rows at most, each lazy inside. A lazy stack rebuilt rows as they
                    // scrolled back in, and each first laid out header-only, so the page jumped.
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(discover.rows) { row in
                            IOSPlexRail(title: row.section.title, kind: .poster, items: row.items,
                                        destination: { copies[$0.ref] ?? $0 }) {
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
        // Once per load and server list: coming back from a title keeps the answers.
        .task(id: ownershipKey) {
            let key = ownershipKey
            guard key != checked else { return }
            await ownership.check(discover.rows.map(\.items), providers: browse.allProviders, isShown: browse.isShownOnHome)
            if !Task.isCancelled { checked = key }
        }
    }

    /// What the answers depend on: the rows (each load, Refresh included), the servers in order, hidden libraries.
    private var ownershipKey: [String] {
        [String(discover.loads)] + browse.providerOrder + browse.hiddenSidebarLibraries.sorted()
    }
}
