// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Live TV: What's On or the Guide over every configured source, recordings, add-source.
/// Parity source: RivuletiOS/LiveTV/ (IOSLiveTVView, IOSLiveWhatsOnView, IOSLiveGuideView,
/// IOSLiveProgrammeSheet, IOSLiveRecordingsView, IOSLivePlayback). Shared logic is in
/// RivuletCore/LiveTV (LiveClient.swift, LiveTVDataStore).
struct MacLiveTVView: View {
    @ObservedObject private var store = LiveTVDataStore.shared

    var body: some View {
        Group {
            if store.hasConfiguredSources {
                MacFeaturePlaceholder(title: "Live TV", symbol: "play.tv", source: "RivuletiOS/LiveTV/IOSLiveTVView.swift")
            } else {
                ContentUnavailableView("Add a Live TV Source", systemImage: "play.tv",
                                       description: Text("Add Plex Live TV, Dispatcharr, Tvheadend or an M3U playlist in Settings."))
            }
        }
        .navigationTitle("Live TV")
    }
}
