// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVContainerView.swift
//  Rivulet
//
//  Container view that switches between the Channel, Guide and Browse
//  layouts based on user settings
//

import SwiftUI

// MARK: - Live TV Layout Option

enum LiveTVLayout: String, CaseIterable, CustomStringConvertible {
    case channels = "Channels"
    case guide = "Guide"
    /// Shelves of live cards, after the Apple TV app (UIKit).
    case browse = "Browse"

    var description: String { rawValue }
}

// MARK: - Live TV Container View

struct LiveTVContainerView: View {
    /// Optional source ID to filter channels. nil = show all sources.
    var sourceIdFilter: String?

    @AppStorage("liveTVLayout") private var liveTVLayoutRaw = "Guide"
    @StateObject private var dataStore = LiveTVDataStore.shared

    private var layout: LiveTVLayout {
        LiveTVLayout(rawValue: liveTVLayoutRaw) ?? .guide
    }

    var body: some View {
        Group {
            switch layout {
            case .channels:
                ChannelListView(sourceIdFilter: sourceIdFilter)
            case .guide:
                GuideLayoutView(sourceIdFilter: sourceIdFilter)
            case .browse:
                LiveBrowseBridge(sourceIdFilter: sourceIdFilter)
                    .ignoresSafeArea()
                    .id(sourceIdFilter ?? "all")
            }
        }
        .task {
            // Elevate EPG loading priority when user visits Live TV
            await dataStore.elevatePreloadPriority()
            // ...and re-fetch when what we already have has gone stale (older
            // than 30 minutes, or a window that no longer covers now). Both
            // layouts below only load when their data is EMPTY, so without
            // this a returning visit keeps showing an outdated — or
            // entirely past-dated, hence blank — grid.
            await dataStore.refreshIfStale()
        }
    }
}

/// Hosts the UIKit Browse layout. `.id` on the source rebuilds it when the
/// sidebar switches Live TV sources.
private struct LiveBrowseBridge: UIViewControllerRepresentable {
    let sourceIdFilter: String?

    func makeUIViewController(context: Context) -> LiveBrowseViewController {
        LiveBrowseViewController(sourceIdFilter: sourceIdFilter)
    }

    func updateUIViewController(_ uiViewController: LiveBrowseViewController, context: Context) {}
}

#Preview {
    LiveTVContainerView()
}
