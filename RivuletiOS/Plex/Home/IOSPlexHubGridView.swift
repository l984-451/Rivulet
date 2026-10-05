// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// See All for one Home or detail row, paged through the hub's own key.
struct IOSPlexHubGridView: View {
    let route: IOSPlexHubRoute
    @EnvironmentObject private var plex: IOSPlexSession
    @State private var items: [PlexMetadata]
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedRevision: Int?

    private static let pageSize = 60

    init(route: IOSPlexHubRoute) {
        self.route = route
        _items = State(initialValue: route.hub.Metadata ?? [])
    }

    /// Continue Watching follows the session's own cache-busted copy.
    private var shown: [PlexMetadata] {
        route.hub.isContinueWatching ? (plex.continueWatching?.Metadata ?? items) : items
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
                    if route.hub.isContinueWatching { await plex.refresh() } else { await reload() }
                }
            }
        }
        .navigationTitle(route.hub.displayTitle)
        .navigationBarTitleDisplayMode(.large)
        .task(id: plex.watchStateRevision) {
            guard route.pages, loadedRevision != plex.watchStateRevision else { return }
            await reload()
        }
    }

    /// Refetches everything loaded so far, keeping the scroll position.
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await plex.hubPage(route.hub, start: 0, size: max(Self.pageSize, items.count))
            items = page.items.uniqued()
            total = page.totalSize
            error = nil
            loadedRevision = plex.watchStateRevision
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
            guard let page = try? await plex.hubPage(route.hub, start: items.count, size: Self.pageSize) else { return }
            items = (items + page.items).uniqued()
            // An empty page means the server's count overstated; stop paging.
            self.total = page.items.isEmpty ? items.count : page.totalSize
        }
    }
}

extension Array where Element == PlexMetadata {
    /// Drops repeats by id, keeping the first; ForEach needs unique ids.
    func uniqued() -> [PlexMetadata] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
