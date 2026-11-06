// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import UIKit
@testable import Rivulet

@MainActor
@Suite(.serialized)
struct BelowFoldInitialSelectionTests {
    private let providerID = UUID().uuidString

    @Test func showSelectsOnDeckSeasonAndEpisode() async {
        let provider = makeProvider()
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }

        let content = await BelowFoldContentLoader().load(for: item("show", .show), detail: provider.detailResult)

        #expect(content.initialEpisode?.ref.itemID == "s3e4")
        #expect(content.selectedSeason?.ref.itemID == "s3")
        #expect(provider.playbackCalls.isEmpty)
    }

    @Test func showWithoutOnDeckUsesPlayTargetFallback() async {
        let provider = makeProvider(onDeck: nil)
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }

        let content = await BelowFoldContentLoader().load(for: item("show", .show), detail: nil)

        #expect(content.initialEpisode?.ref.itemID == "s1e2")
        #expect(content.selectedSeason?.ref.itemID == "s1")
    }

    @Test func showWithoutOnDeckReusesWhatTheLoaderFetched() async {
        let provider = makeProvider(onDeck: nil)
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }

        let content = await BelowFoldContentLoader().load(for: item("show", .show), detail: provider.detailResult)

        #expect(content.initialEpisode?.ref.itemID == "s1e2")
        #expect(provider.playbackCalls.isEmpty)
    }

    /// A standalone page runs `configure` straight after the peek load, which must then fetch nothing.
    @Test func supersededPeekLoadFetchesNothing() async throws {
        let provider = makeProvider()
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }
        let view = BelowFoldCollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))

        view.configureEpisodesOnly(item: item("show", .show))
        try await load(view, item: item("show", .show), full: true)

        #expect(provider.playbackCalls == ["detail(show)"])
    }

    /// The full load finishing after the user entered the rail must not scroll it under them.
    @Test func lateFullLoadLeavesAFocusedRailAlone() async throws {
        let provider = makeProvider()
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }
        let view = BelowFoldCollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let host = FocusHost(view)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = view.frame
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        try await load(view, item: item("show", .show), full: false)
        view.layoutIfNeeded()
        let collection = try #require(view.subviews.compactMap { $0 as? FocusScrollControlledCollectionView }.first)
        host.setNeedsFocusUpdate()
        host.updateFocusIfNeeded()
        try await waitUntil { collection.focusedEpisodeIndexPath != nil }
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 21, section: 0)))
        let scroller = try #require(enclosingScroller(of: cell, in: collection))
        // The focus engine's own scroll settles first; it would read as movement below.
        var last = CGFloat.nan
        try await waitUntil {
            defer { last = scroller.contentOffset.x }
            return scroller.contentOffset.x == last
        }
        try await Task.sleep(for: .milliseconds(300))
        scroller.contentOffset.x -= 200
        let moved = scroller.contentOffset.x

        try await load(view, item: item("show", .show), full: true)
        view.layoutIfNeeded()

        #expect(abs(scroller.contentOffset.x - moved) < 50)
    }

    @Test(arguments: [false, true])
    func showRailStartsAtOnDeckEpisode(full: Bool) async throws {
        let provider = makeProvider()
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }
        let view = BelowFoldCollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = view.frame
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }

        try await load(view, item: item("show", .show), full: full)
        view.layoutIfNeeded()
        let collection = try #require(view.subviews.compactMap { $0 as? UICollectionView }.first)
        let index = try #require(view.indexPathForPreferredFocusedView(in: collection))

        #expect(index == IndexPath(item: 21, section: 0))
        #expect(collection.cellForItem(at: index) is EpisodeCollectionCell)
    }

    @Test func changingShowsClearsPreviousEpisodeTarget() async throws {
        let provider = makeProvider()
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }
        let view = BelowFoldCollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = view.frame
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        try await load(view, item: item("show", .show), full: false)
        provider.detailResult = nil
        provider.episodesByShow["other"] = [item("other-e1", .episode, parent: "other-s1", season: 1, episode: 1)]

        try await load(view, item: item("other", .show), full: false)
        view.layoutIfNeeded()
        let collection = try #require(view.subviews.compactMap { $0 as? UICollectionView }.first)

        #expect(view.indexPathForPreferredFocusedView(in: collection) == IndexPath(item: 0, section: 0))
        #expect(collection.numberOfItems(inSection: 0) == 1)
    }

    private func load(_ view: BelowFoldCollectionView, item: MediaItem, full: Bool) async throws {
        var loaded = false
        if full {
            view.onSeasonsLoaded = { _, _ in loaded = true }
            view.configure(item: item, detail: nil)
        } else {
            view.onEpisodesApplied = { loaded = true }
            view.configureEpisodesOnly(item: item)
        }
        try await waitUntil { loaded }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func enclosingScroller(of cell: UIView, in collection: UICollectionView) -> UIScrollView? {
        var view = cell.superview
        while let current = view {
            if let scroller = current as? UIScrollView, scroller !== collection { return scroller }
            view = current.superview
        }
        return nil
    }

    private func makeProvider(onDeck: String? = "s3e4") -> StubMediaProvider {
        let provider = StubMediaProvider(id: providerID)
        provider.childrenByParent["show"] = (1...3).map { (number: Int) in
            item("s\(number)", .season, parent: "show", season: number)
        }
        for season in 1...3 {
            provider.childrenByParent["s\(season)"] = (1...8).map { (number: Int) in
                item("s\(season)e\(number)", .episode, parent: "s\(season)", season: season, episode: number)
            }
        }
        provider.episodesByShow["show"] = (1...3).flatMap { provider.childrenByParent["s\($0)"] ?? [] }
        provider.detailResult = MediaItemDetail(
            item: item("show", .show), tagline: nil, genres: [], studios: [], cast: [], directors: [],
            writers: [], chapters: [], mediaSources: [], trailerURL: nil, contentRating: nil,
            nextEpisode: onDeck.map { item($0, .episode, parent: "s3", season: 3, episode: 4) }, collections: [])
        return provider
    }

    private func item(_ id: String, _ kind: MediaKind, parent: String? = nil,
                      season: Int? = nil, episode: Int? = nil) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: id), kind: kind, title: id,
            sortTitle: nil, overview: nil, year: nil, runtime: nil,
            parentRef: parent.map { MediaItemRef(providerID: providerID, itemID: $0) },
            grandparentRef: kind == .episode ? MediaItemRef(providerID: providerID, itemID: "show") : nil,
            episodeNumber: episode, seasonNumber: season, childProgress: nil,
            userState: MediaUserState(isPlayed: season == 1 && episode != 2, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
    }
}

private final class FocusHost: UIViewController {
    private let content: UIView

    init(_ content: UIView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() { view = content }
    override var preferredFocusEnvironments: [UIFocusEnvironment] { [content] }
}
