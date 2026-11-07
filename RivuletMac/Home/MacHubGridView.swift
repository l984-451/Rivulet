// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// See All for one Home or detail row, paged through the hub's own key.
/// Port of RivuletiOS/Plex/Home/IOSPlexHubGridView.swift.
struct MacHubGridView: View {
    let hub: MediaHub
    @EnvironmentObject private var browse: BrowseStore
    @State private var items: [MediaItem]
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedRevision: Int?

    private static let pageSize = 60

    init(hub: MediaHub) {
        self.hub = hub
        _items = State(initialValue: hub.items)
    }

    private var pages: Bool { hub.pagingKey != nil }

    /// Only the merged row, which has no server; a library's own in-progress row keeps its items.
    private var isContinueWatching: Bool { hub.id == BrowseStore.continueWatchingID && hub.providerID.isEmpty }

    /// Continue Watching follows the store's own merged copy.
    private var shown: [MediaItem] {
        isContinueWatching ? (browse.continueWatching.nilIfEmpty ?? items) : items
    }

    var body: some View {
        Group {
            if shown.isEmpty, let error {
                MacErrorView(title: "Couldn't Load", message: error) { await reload() }
            } else {
                ScrollView {
                    MacPosterGrid(items: shown, loadMore: loadMore).padding(.vertical, 20)
                    if isLoading { ProgressView().padding() }
                }
            }
        }
        .navigationTitle(hub.title)
        .task(id: browse.watchStateRevision) {
            guard pages, loadedRevision != browse.watchStateRevision else { return }
            await reload()
        }
    }

    /// Refetches everything loaded so far, keeping the scroll position.
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await browse.provider(for: hub.providerID)?.hubPage(
                hub, page: Page(offset: 0, limit: max(Self.pageSize, items.count)))
                ?? PagedResult(items: hub.items, total: hub.items.count, nextPage: nil)
            items = page.items.uniqued()
            total = page.total
            error = nil
            loadedRevision = browse.watchStateRevision
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() {
        guard pages, !isLoading, let total, items.count < total else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let page = try? await browse.provider(for: hub.providerID)?.hubPage(
                hub, page: Page(offset: items.count, limit: Self.pageSize)) else { return }
            items = (items + page.items).uniqued()
            // An empty page means the server's count overstated; stop paging.
            self.total = page.items.isEmpty ? items.count : page.total
        }
    }
}

private extension Array where Element == MediaItem {
    /// Drops repeats by id, keeping the first; ForEach needs unique ids.
    func uniqued() -> [MediaItem] {
        var seen = Set<MediaItemRef>()
        return filter { seen.insert($0.id).inserted }
    }
}
