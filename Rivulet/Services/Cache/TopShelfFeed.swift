// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfFeed.swift
//  Rivulet
//
//  The Top Shelf row: every server's Continue Watching in one list,
//  most recently watched first, then Recently Added (alone when there is none). Both stores call `refresh` when their row changes.
//

import Foundation

@MainActor
enum TopShelfFeed {
    // The poster row shows all of them; the full screen carousel the first 5.
    static let limit = 10

    static func refresh() async {
        let auth = PlexAuthManager.shared
        let profiles = PlexUserProfileManager.shared
        // The Home screen row sits outside the PIN gate (a remembered PIN reopens it unasked).
        guard !auth.relocksOnLaunch || profiles.selectedUser.map(profiles.hasRememberedPin(for:)) ?? false else {
            DiagLog.notice(.topShelf, "Cleared: profile relocks and its PIN is not remembered")
            TopShelfCache.shared.clear()
            return
        }
        // Until a Home profile is entered there is no Plex row to show; keep the last one.
        guard !auth.isContentWithheld else {
            DiagLog.notice(.topShelf, "Skipped: content withheld until a profile is entered")
            return
        }
        let serverURL = auth.selectedServerURL
        let token = auth.selectedServerToken
        var plex: [TopShelfItem] = []
        // Top Shelf shows the rows Home shows: a row hidden in Settings > Home Rows stays off it.
        let cwHub = PlexDataStore.shared.continueWatchingHub
        if let serverURL, let token, !HomeRowSettings.isHidden(cwHub?.hubIdentifier) {
            // /hubs/continueWatching, as the in-app row uses. The global /hubs drops movies (#194).
            plex = TopShelfMapper.items(from: cwHub?.Metadata ?? [],
                                        serverURL: serverURL, token: token, limit: limit * 2)
        }
        let serverStore = ServerDataStore.shared
        let sources = serverStore.sources
        let otherRows = serverStore.visibleHomeRows.filter(\.isContinueWatching).map(\.items)
        var others = otherRows.flatMap { TopShelfMapper.items(from: $0, limit: limit * 2) }
        let primaryID = MediaProviderRegistry.shared.plexProvider?.id
        let primaryVisible = primaryID != nil && serverURL != nil && token != nil && !HomeRowSettings.isHidden(cwHub?.hubIdentifier)
        let primaryRow = primaryVisible ? (PlexDataStore.shared.homeItems.first(where: \.isContinueWatching)?.items ?? []) : []
        let rows = [primaryRow] + otherRows
        let cards = ContinueWatchingRow.shared.cards(rows, identity: { $0.identity ?? [] },
                                                     lookupKey: \.lookupKey, watched: \.userState.lastViewedAt)
        filterCopies(plex: &plex, others: &others, cards: cards,
                     contributingRows: rows.filter { !$0.isEmpty }.count, primaryID: primaryID)

        var row = TopShelfMapper.merge(plex, others, limit: limit)
        let source = row.isEmpty ? "Recently Added" : "Continue Watching"
        var recent = recentlyAdded(serverURL: serverURL, token: token)
        // No Continue Watching anywhere: Recently Added leads, and the carousel shows it.
        if row.isEmpty {
            row = recent
            recent = []
        }
        removeRecentlyWatched(&recent, row: row)
        let items = await TopShelfComposer.composite(items: row, serverURL: serverURL, token: token)
        // A profile changed, locked or signed out during the composite.
        guard auth.selectedServerToken == token, serverStore.sources == sources else {
            DiagLog.notice(.topShelf, "Dropped: profile or sources changed while composing")
            return
        }
        DiagLog.notice(.topShelf, "Refresh: \(items.count) items from \(source), \(recent.count) recently added (plex cw \(plex.count), other cw \(others.count)), \(items.filter { $0.compositeFileName != nil }.count) composites")
        TopShelfCache.shared.writeItems(items, sectionTitle: source, recent: recent)
    }

    static func removeRecentlyWatched(_ recent: inout [TopShelfItem], row: [TopShelfItem]) {
        let refs = Set(row.map { MediaItemRef(providerID: $0.serverIdentifier, itemID: $0.ratingKey) })
        recent.removeAll { refs.contains(MediaItemRef(providerID: $0.serverIdentifier, itemID: $0.ratingKey)) }
    }

    /// A single server's hub may be longer than its Home row. Only remove known
    /// copies in that case; across servers, match the Home row's chosen cards.
    static func filterCopies(plex: inout [TopShelfItem], others: inout [TopShelfItem],
                             cards: [ContinueWatchingMerge.Card<MediaItem>], contributingRows: Int,
                             primaryID: String?) {
        let singleRow = contributingRows <= 1
        let refs = Set(singleRow ? cards.flatMap(\.others).map(\.ref) : cards.map(\.item.ref))
        func remove(_ ref: MediaItemRef) -> Bool {
            singleRow ? refs.contains(ref) : !refs.contains(ref)
        }
        if let primaryID {
            plex.removeAll { remove(MediaItemRef(providerID: primaryID, itemID: $0.ratingKey)) }
        }
        others.removeAll { remove(MediaItemRef(providerID: $0.serverIdentifier, itemID: $0.ratingKey)) }
    }

    /// Newest unwatched titles from the selected Plex server's loaded library hubs and the
    /// other servers' Recently Added rows.
    private static func recentlyAdded(serverURL: String?, token: String?) -> [TopShelfItem] {
        var plex: [TopShelfItem] = []
        if let serverURL, let token {
            let store = PlexDataStore.shared
            let metadata = store.librariesPinnedToHome
                .flatMap { store.libraryHubs[$0.key] ?? [] }
                .filter { $0.promoted == true && !HomeRowSettings.isHidden($0.hubIdentifier) }
                .filter { ($0.hubIdentifier ?? "").lowercased().contains("recentlyadded") }
                .flatMap { $0.Metadata ?? [] }
            plex = TopShelfMapper.recentlyAddedItems(from: metadata, serverURL: serverURL, token: token, limit: limit * 2)
        }
        let others = ServerDataStore.shared.visibleHomeRows
            .filter { $0.id.hasSuffix(".recentlyAdded") }
            // A music library's row lists albums, which Top Shelf leaves out as it does Plex's.
            .flatMap { TopShelfMapper.items(from: $0.items.filter { !$0.userState.isPlayed && $0.isMusic != true },
                                            limit: limit * 2) }
        return TopShelfMapper.merge(plex, others, limit: limit)
    }
}
