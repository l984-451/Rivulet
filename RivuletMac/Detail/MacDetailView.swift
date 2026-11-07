// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Movie, show, season or episode page: art, actions, episodes, then related rows. Parity source:
/// RivuletiOS/Plex/Detail/IOSPlexDetailView.swift and IOSPlexDetailSections.swift.
/// Placeholder: poster, title and a Play button through `MacActions`.
struct MacDetailView: View {
    let item: MediaItem
    @Environment(\.macActions) private var actions

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            MacPosterCard(item: item, width: 220, showsCaption: false)
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.largeTitle.bold())
                if IOSPlaybackGate.canPlay(item.ref) {
                    Button(item.isInProgress ? "Resume" : "Play", systemImage: "play.fill") { actions.play(item) }
                        .buttonStyle(.borderedProminent)
                }
                Text("Detail page not built yet.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(MacMetrics.pageMargin)
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle(item.title)
    }
}
