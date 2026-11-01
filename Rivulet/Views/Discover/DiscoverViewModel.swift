// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DiscoverViewModel.swift
//  Rivulet
//
//  View model for Discover (`PlexHomeViewController` in `.discover` mode):
//  TMDB sections, hero items and the "For You" row, with in-library matches.
//

import SwiftUI
import Combine

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var sectionItems: [TMDBDiscoverSection: [TMDBListItem]] = [:]
    @Published private(set) var forYou: [TMDBListItem] = []
    @Published private(set) var inLibraryTMDBIds: Set<Int> = []
    @Published private(set) var heroItems: [TMDBListItem] = []
    @Published private(set) var loading = false

    private let discoverService = TMDBDiscoverService.shared
    private let recommendationService = DiscoverRecommendationService.shared
    private let libraryIndex = LibraryGUIDIndex.shared

    /// Minimum watched items required before we try to personalize the "For You"
    /// row. Fewer watches produce noisy recommendations that feel random.
    private let forYouColdStartMinWatched = 5

    /// Cap on hero carousel items. Matches the home page's cap.
    private let heroItemCap = 9

    func load() async {
        loading = true
        defer { loading = false }

        // Fetch all 8 sections in parallel.
        await withTaskGroup(of: (TMDBDiscoverSection, [TMDBListItem]).self) { group in
            for section in TMDBDiscoverSection.allCases {
                group.addTask { [discoverService] in
                    let items = await discoverService.fetchSection(section)
                    return (section, items)
                }
            }
            for await (section, items) in group {
                sectionItems[section] = items
            }
        }

        // Precompute the in-library TMDB id set for sync lookup from row closures.
        await recomputeInLibrarySet()

        // Pick hero items from the same popular sources the home page uses.
        heroItems = computeHeroItems(cap: heroItemCap)

        // Warm the image cache for every hero backdrop/poster so paging the
        // carousel doesn't flash a blank frame while the image downloads.
        prefetchHeroAssets(heroItems)

        // "For You" appends below the curated sections once watch-history
        // features resolve, so it doesn't shift the layout out from under
        // the user. Hides itself on cold-start (too few watched items to
        // produce a meaningful profile).
        let watchedItems = await collectWatchHistory()
        if watchedItems.count >= forYouColdStartMinWatched {
            let profile = await WatchProfileBuilder.build(from: watchedItems)
            forYou = await recommendationService.forYouRow(profile: profile)
        } else {
            forYou = []
        }
    }

    func items(for section: TMDBDiscoverSection) -> [TMDBListItem] {
        sectionItems[section] ?? []
    }

    func libraryMatch(for item: TMDBListItem) async -> PlexMetadata? {
        guard let entry = await libraryIndex.lookup(tmdbId: item.id, type: item.mediaType),
              let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else { return nil }
        return await LibraryGUIDIndex.items(for: [entry], serverURL: serverURL, authToken: token)[entry.ratingKey]
    }

    /// Re-derive the in-library TMDB id set (call when LibraryGUIDIndex
    /// repopulates after this model loaded — the UIKit Discover page races
    /// the sidebar's index build on cold launch).
    func refreshLibraryMatches() async {
        await recomputeInLibrarySet()
    }

    /// Warm the image cache for the full hero carousel so paging doesn't
    /// trigger a blank flash. Larger `w1280` size is what `HeroBackdropImage`
    /// will resolve from the `original` URL — using `original` for prefetch
    /// matches what the view requests.
    private func prefetchHeroAssets(_ items: [TMDBListItem]) {
        let backdropBase = "https://image.tmdb.org/t/p/original"
        let posterBase = "https://image.tmdb.org/t/p/w500"
        var urls: [URL] = []
        for item in items {
            if let path = item.backdropPath,
               let url = URL(string: "\(backdropBase)\(path)") {
                urls.append(url)
            }
            if let path = item.posterPath,
               let url = URL(string: "\(posterBase)\(path)") {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        Task { await ImageCacheManager.shared.prefetch(urls: urls) }
    }

    /// Interleave Popular Movies + Popular TV (which we've already fetched for
    /// the curated rows) to seed the hero carousel. Prefers items with backdrops.
    private func computeHeroItems(cap: Int) -> [TMDBListItem] {
        let movies = sectionItems[.moviePopular] ?? []
        let shows = sectionItems[.tvPopular] ?? []

        var interleaved: [TMDBListItem] = []
        let count = max(movies.count, shows.count)
        for i in 0..<count {
            if i < movies.count { interleaved.append(movies[i]) }
            if i < shows.count { interleaved.append(shows[i]) }
            if interleaved.count >= cap * 2 { break }
        }

        // Prefer items with a backdrop so the hero never shows the fallback gradient.
        let ranked = interleaved.sorted { (a, b) in
            let aHas = (a.backdropPath?.isEmpty == false) ? 1 : 0
            let bHas = (b.backdropPath?.isEmpty == false) ? 1 : 0
            return aHas > bHas
        }

        return Array(ranked.prefix(cap))
    }

    /// Rebuild `inLibraryTMDBIds` by asking the library index for each fetched item.
    /// This runs after section items load. Single pass, one actor hop per id — cheap.
    private func recomputeInLibrarySet() async {
        let allIds = sectionItems.values.flatMap { $0.map { ($0.id, $0.mediaType) } }
        var newSet: Set<Int> = []
        for (id, mediaType) in allIds {
            if await libraryIndex.lookup(tmdbId: id, type: mediaType) != nil {
                newSet.insert(id)
            }
        }
        inLibraryTMDBIds = newSet
    }

    private func collectWatchHistory() async -> [PlexMetadata] {
        let dataStore = PlexDataStore.shared
        let auth = PlexAuthManager.shared
        guard let serverURL = auth.selectedServerURL,
              let token = auth.selectedServerToken else { return [] }
        await dataStore.loadLibrariesIfNeeded()
        let visibleLibraries = dataStore.visibleVideoLibraries

        var watched: [PlexMetadata] = []
        for library in visibleLibraries.prefix(3) {  // Cap to keep latency sane
            if let result = try? await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                serverURL: serverURL,
                authToken: token,
                sectionId: library.key,
                start: 0,
                size: 200
            ) {
                watched.append(contentsOf: result.items.filter { ($0.viewCount ?? 0) > 0 })
            }
        }
        return Array(watched.prefix(120))
    }
}
