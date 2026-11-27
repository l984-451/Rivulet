// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation
import Observation

/// Discover's For You row on iOS and Mac, as tvOS's `DiscoverViewModel` builds it: TMDB's titles in
/// the genres you watch most, less the ones a server already has.
@Observable @MainActor
final class DiscoverForYou {
    /// Published only once `DiscoverOwnership` has answered for every title, so an owned one never flashes in.
    private(set) var items: [MediaItem] = []
    /// The key `items` was built for.
    @ObservationIgnored private var built: [String]?

    /// Builds the row once per `key`: coming back to the page keeps it, and a new key (Refresh, other
    /// servers or libraries) builds it again while the old row stays up.
    func load(key: [String], libraries: [MediaLibrary], providers: [any MediaProvider], ownership: DiscoverOwnership,
              isShown: (MediaItem) -> Bool, service: DiscoverRecommendationService = DiscoverRecommendationService()) async {
        guard key != built else { return }
        let watched = await Self.watchHistory(libraries, providers: providers)
        guard !Task.isCancelled else { return }
        let candidates = await service.candidates(watched: watched).map(TMDBMediaMapper.item)
        guard !Task.isCancelled else { return }
        // Only titles not already known owned: a server failing now can't undo the curated rows' answers.
        await ownership.check([candidates.filter { ownership.copies[$0.ref] == nil }], providers: providers, isShown: isShown)
        guard !Task.isCancelled else { return }
        items = await DiscoverRecommendationService.row(candidates) { ownership.copies[$0.ref] != nil }
        built = key
    }

    /// The libraries the history reads, as on tvOS: the first three movie or TV libraries shown, in
    /// server order (the selected Plex server's first).
    static func historyLibraries(_ shown: [MediaLibrary]) -> [MediaLibrary] {
        Array(shown.filter { $0.kind == .movies || $0.kind == .shows }.prefix(3))
    }

    /// tvOS's scan on any server: each library's first 200 titles in title order, one request each,
    /// and the watched ones among them, at most 120.
    static func watchHistory(_ shown: [MediaLibrary], providers: [any MediaProvider]) async -> [WatchedTitle] {
        let jobs = historyLibraries(shown).enumerated().compactMap { index, library in
            providers.first { $0.id == library.providerID }.map { (index, library, $0) }
        }
        let page = Page(offset: 0, limit: 200)
        let sort = SortOption.titleAsc
        let found = await BoundedFanOut.map(jobs) { index, library, provider in
            (index, (try? await provider.items(in: library, sort: sort, page: page))?.items ?? [])
        }
        // Movies and shows only: Plex can list a collection in its movies' place.
        let listed = found.sorted { $0.0 < $1.0 }.flatMap(\.1).filter { $0.kind == .movie || $0.kind == .show }
        return listed.filter(WatchedTitle.isWatched).prefix(120).map(WatchedTitle.init)
    }
}
