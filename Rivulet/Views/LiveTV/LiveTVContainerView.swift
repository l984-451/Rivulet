// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVContainerView.swift
//  Rivulet
//
//  Container view that switches between the Guide, What's On and List
//  layouts based on user settings
//

import SwiftUI

// MARK: - Live TV Layout Option

/// Raw values are what `liveTVLayout` stores, so they never change; a saved
/// "Channels" (a retired layout) falls back to the default.
enum LiveTVLayout: String, CaseIterable, CustomStringConvertible {
    case guide = "Guide"
    /// Shelves of live cards, after the Apple TV app (UIKit).
    case browse = "Browse"
    /// Categories beside a channel list (UIKit).
    case list = "List"

    var description: String {
        switch self {
        case .guide: return String(localized: "Guide")
        case .browse: return String(localized: "What's On")
        case .list: return String(localized: "List")
        }
    }

    /// With nothing saved, or a saved layout that no longer exists.
    static let fallback: LiveTVLayout = .browse
}

// MARK: - Live TV Container View

struct LiveTVContainerView: View {
    /// Optional source ID to filter channels. nil = show all sources.
    var sourceIdFilter: String?

    @AppStorage("liveTVLayout") private var liveTVLayoutRaw = LiveTVLayout.fallback.rawValue
    @StateObject private var dataStore = LiveTVDataStore.shared

    private var layout: LiveTVLayout {
        LiveTVLayout(rawValue: liveTVLayoutRaw) ?? .fallback
    }

    var body: some View {
        Group {
            switch layout {
            case .guide:
                GuideLayoutView(sourceIdFilter: sourceIdFilter)
            case .browse:
                LiveBrowseBridge(sourceIdFilter: sourceIdFilter)
                    .ignoresSafeArea()
                    .id(sourceIdFilter ?? "all")
            case .list:
                LiveListBridge(sourceIdFilter: sourceIdFilter)
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

/// Hosts the UIKit List layout, and builds the guide it lays over itself:
/// the existing guide on the category's tab, limited to its source, focused
/// on the channel. Left from a row's first programme or Menu takes it off.
private struct LiveListBridge: UIViewControllerRepresentable {
    let sourceIdFilter: String?

    func makeUIViewController(context: Context) -> LiveListViewController {
        let list = LiveListViewController(sourceIdFilter: sourceIdFilter)
        list.makeGuide = { target, channelId, close in
            UIHostingController(rootView: GuideLayoutView(
                sourceIdFilter: target.sourceId,
                initialGroup: Self.tabTitle(target.tab, sourceId: target.sourceId),
                initialChannelId: channelId,
                onExit: { group, focusedId in
                    close(LiveListReturn(target: LiveGuideTarget(sourceId: target.sourceId,
                                                                 tab: Self.tab(group, sourceId: target.sourceId)),
                                         channelId: focusedId ?? channelId))
                }))
        }
        return list
    }

    func updateUIViewController(_ list: LiveListViewController, context: Context) {}

    /// The guide's tab title for a target: nil is All Channels.
    @MainActor static func tabTitle(_ tab: LiveGuideTarget.Tab, sourceId: String?) -> String? {
        switch tab {
        case .all: return nil
        case .favorites: return GuideLayoutView.favouritesTab
        case .group(let title): return title
        case .list(let listId):
            return LiveChannelListStore.shared.list(listId)?.tabTitle(taken: taken(sourceId))
        }
    }

    @MainActor private static func taken(_ sourceId: String?) -> Set<String> {
        GuideLayoutView.takenTabNames(sourceIdFilter: sourceId, store: .shared)
    }

    /// A tab title back to a target. The guide matches Favorites, then the
    /// viewer's lists, then groups, so this does too.
    @MainActor static func tab(_ title: String?, sourceId: String?) -> LiveGuideTarget.Tab {
        guard let title else { return .all }
        if title == GuideLayoutView.favouritesTab { return .favorites }
        let taken = taken(sourceId)
        if let list = LiveChannelListStore.shared.lists.first(where: { $0.tabTitle(taken: taken) == title }) {
            return .list(list.id)
        }
        return .group(title)
    }
}

#Preview {
    LiveTVContainerView()
}
