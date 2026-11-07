// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Home: hero, Continue Watching, then each pinned library's rows. Parity source:
/// RivuletiOS/Plex/Home/IOSPlexHomeView.swift, IOSPlexHeroFeed.swift, IOSPlexHomeHero.swift.
/// This placeholder lists the rows only; the hero is still to port.
struct MacHomeView: View {
    @EnvironmentObject private var browse: BrowseStore

    var body: some View {
        Group {
            if browse.homeRows.isEmpty {
                if browse.isLoadingContent {
                    ProgressView()
                } else if let error = browse.contentError ?? browse.failedServers.first?.message {
                    MacErrorView(title: "Couldn't Load Home", message: error) { await browse.refresh() }
                } else {
                    ContentUnavailableView("Nothing on Home Yet", systemImage: "rectangle.stack",
                                           description: Text("Pin a library to Home in Plex, then refresh."))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(browse.failedServers) { MacServerFailureBanner(failure: $0) }
                        ForEach(browse.homeRows) { MacShelfView(hub: $0) }
                    }
                    .padding(.vertical, 20)
                }
            }
        }
        .navigationTitle("Home")
    }
}
