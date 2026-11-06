// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// See All for one Home or detail row, paged through the hub's own key.
struct IOSPlexHubGridView: View {
    let route: IOSPlexHubRoute
    @EnvironmentObject private var browse: IOSBrowseStore
    @State private var items: [MediaItem]
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedRevision: Int?

    private static let pageSize = 60

    init(route: IOSPlexHubRoute) {
        self.route = route
        _items = State(initialValue: route.hub.items)
    }

    /// Continue Watching follows the store's own merged copy.
    private var shown: [MediaItem] {
        route.isContinueWatching ? (browse.continueWatching.nilIfEmpty ?? items) : items
    }

    var body: some View {
        Group {
            if shown.isEmpty, let error {
                IOSPlexErrorView(title: "Couldn't Load", message: error) { await reload() }
            } else {
                ScrollView {
                    IOSPlexPosterGrid(items: shown, loadMore: loadMore)
                    if isLoading { ProgressView().padding() }
                }
                .refreshable {
                    if route.isContinueWatching { await browse.refresh() } else { await reload() }
                }
            }
        }
        .navigationTitle(route.hub.title)
        .navigationBarTitleDisplayMode(.large)
        .task(id: browse.watchStateRevision) {
            guard route.pages, loadedRevision != browse.watchStateRevision else { return }
            await reload()
        }
    }

    /// Refetches everything loaded so far, keeping the scroll position.
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await browse.provider(for: route.hub.providerID)?.hubPage(
                route.hub, page: Page(offset: 0, limit: max(Self.pageSize, items.count)))
                ?? PagedResult(items: route.hub.items, total: route.hub.items.count, nextPage: nil)
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
        guard route.pages, !isLoading, let total, items.count < total else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let page = try? await browse.provider(for: route.hub.providerID)?.hubPage(
                route.hub, page: Page(offset: items.count, limit: Self.pageSize)) else { return }
            items = (items + page.items).uniqued()
            // An empty page means the server's count overstated; stop paging.
            self.total = page.items.isEmpty ? items.count : page.total
        }
    }
}

extension Array where Element == MediaItem {
    /// Drops repeats by id, keeping the first; ForEach needs unique ids.
    func uniqued() -> [MediaItem] {
        var seen = Set<MediaItemRef>()
        return filter { seen.insert($0.id).inserted }
    }
}
