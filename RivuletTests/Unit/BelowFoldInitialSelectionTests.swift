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

    @Test(arguments: [false, true])
    func initialFocusDuringSlidePreservesTheSelectedSeasonLanding(animated: Bool) async throws {
        try await verifyInitialFocusDuringSlide(animated: animated, missesEarlyFocus: false)
    }

    @Test(arguments: [false, true])
    func missedEarlyFocusRetriesAtDetailsRest(animated: Bool) async throws {
        try await verifyInitialFocusDuringSlide(animated: animated, missesEarlyFocus: true)
    }

    private func verifyInitialFocusDuringSlide(animated: Bool, missesEarlyFocus: Bool) async throws {
        let provider = makeProvider()
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }
        let view = BelowFoldCollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view.isUserInteractionEnabled = false
        let anchor = PreviewFocusAnchorView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let host = FocusHost(view, anchor: anchor)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = view.frame
        window.windowLevel = .alert
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            presenter.present(host, animated: false) { continuation.resume() }
        }
        defer { presenter.dismiss(animated: false) }
        try await load(view, item: item("show", .show), full: false)
        view.layoutIfNeeded()
        let focus = try #require(UIFocusSystem.focusSystem(for: window))
        try await waitUntil { focus.focusedItem === anchor }
        let collection = try #require(view.subviews.compactMap { $0 as? FocusScrollControlledCollectionView }.first)
        let target = IndexPath(item: 21, section: 0)
        let cell = try #require(collection.cellForItem(at: target))
        let rail = try #require(enclosingScroller(of: cell, in: collection))
        let initialX = rail.contentOffset.x
        var completed = false
        var focusedDuringSlide = false
        view.onEpisodeFocused = { episode in
            if episode?.ref.itemID == "s3e4", !collection.isScrollEnabled { focusedDuringSlide = true }
        }
        func requestFocus() {
            view.isUserInteractionEnabled = true
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
        }
        var retries = 0
        view.onLateInitialFocusReady = {
            retries += 1
            #expect(collection.isScrollEnabled)
            requestFocus()
        }
        defer { view.onLateInitialFocusReady = nil }
        view.slideToDetailsTop(animated: animated, travelDistance: 1035, onReadyForFocus: {
            if !missesEarlyFocus { requestFocus() }
        }, completion: { completed = true })
        try await waitUntil { completed }
        try await waitUntil { collection.focusedEpisodeIndexPath == target }
        #expect(retries == (missesEarlyFocus ? 1 : 0))
        #expect(focusedDuringSlide == (animated && !missesEarlyFocus))
        #expect(collection.focusedEpisodeIndexPath == target)
        #expect(abs(rail.contentOffset.x - initialX) < 1)
        try await waitUntil { rail.isScrollEnabled }
        #expect(collection.isScrollEnabled)
    }

    @Test(arguments: [false, true])
    func lateFullLoadOffersTheSelectedEpisodeAfterAnEmptyHandoff(cellRealizesLater: Bool) async throws {
        try await verifyLateEpisodeFocus(cellRealizesLater: cellRealizesLater, contentArrivesBeforeHandoff: false)
    }

    @Test(arguments: [false, true])
    func episodeLoadedBeforeHandoffCanTakeFocusAfterItsCellAppears(animated: Bool) async throws {
        try await verifyLateEpisodeFocus(cellRealizesLater: true, contentArrivesBeforeHandoff: true, animated: animated)
    }

    private func verifyLateEpisodeFocus(cellRealizesLater: Bool, contentArrivesBeforeHandoff: Bool,
                                        animated: Bool = false) async throws {
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
        view.layoutIfNeeded()

        let collection = try #require(view.subviews.compactMap { $0 as? FocusScrollControlledCollectionView }.first)
        let target = IndexPath(item: 21, section: 0)
        var alignedOffset: CGFloat?
        var handoffs = 0
        var retries = 0
        func focusEpisode() {
            if let cell = collection.cellForItem(at: target),
               let rail = enclosingScroller(of: cell, in: collection) {
                alignedOffset = rail.contentOffset.x
                view.isUserInteractionEnabled = true
            }
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
        }
        func handOffFocus() {
            view.slideToDetailsTop(animated: animated, onReadyForFocus: {
                handoffs += 1
                focusEpisode()
            })
            if animated {
                let start = CACurrentMediaTime()
                for frame in 1...240 { view.advanceSlide(at: start + Double(frame) / 60) }
            }
            #expect(collection.focusedEpisodeIndexPath == nil)
        }
        if !contentArrivesBeforeHandoff { handOffFocus() }

        view.onLateInitialFocusReady = {
            retries += 1
            focusEpisode()
        }
        defer { view.onLateInitialFocusReady = nil }
        let episodeLayout = collection.collectionViewLayout
        if cellRealizesLater {
            view.isUserInteractionEnabled = false
            collection.setCollectionViewLayout(UICollectionViewLayout(), animated: false)
        }
        view.configure(item: item("show", .show), detail: nil)
        if cellRealizesLater {
            try await waitUntil { collection.numberOfSections > 0 }
            try #require(collection.cellForItem(at: target) == nil)
            #expect(alignedOffset == nil)
            if contentArrivesBeforeHandoff {
                handOffFocus()
                #expect(handoffs == 0)
            }
            collection.setCollectionViewLayout(episodeLayout, animated: false)
            collection.contentOffset.y = view.detailsRestOff - collection.adjustedContentInset.top
            collection.layoutIfNeeded()
        }
        try await waitUntil { collection.focusedEpisodeIndexPath == target }
        #expect(handoffs == 1)
        #expect(retries == (contentArrivesBeforeHandoff ? 0 : 1))
        let initialX = try #require(alignedOffset)
        let cell = try #require(collection.cellForItem(at: target))
        let rail = try #require(enclosingScroller(of: cell, in: collection))
        try await waitUntil { rail.isScrollEnabled }
        #expect(abs(rail.contentOffset.x - initialX) < 1)
    }

    @Test(arguments: ["s3e4", "s3e3"])
    func refreshReconcilesThePendingEntryEpisode(removedID: String) async throws {
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
        let collection = try #require(view.subviews.compactMap { $0 as? UICollectionView }.first)
        let episodeLayout = collection.collectionViewLayout
        collection.setCollectionViewLayout(UICollectionViewLayout(), animated: false)
        try await load(view, item: item("show", .show), full: false)

        var handoffs = 0
        var preferredPath: IndexPath?
        view.slideToDetailsTop(animated: false, onReadyForFocus: { [weak view] in
            handoffs += 1
            preferredPath = view?.indexPathForPreferredFocusedView(in: collection)
        })
        #expect(handoffs == 0)

        provider.episodesByShow["show"]?.removeAll { $0.ref.itemID == removedID }
        view.refreshWatchState()
        try await waitUntil { collection.numberOfItems(inSection: 0) == 25 }
        collection.setCollectionViewLayout(episodeLayout, animated: false)
        collection.contentOffset.y = view.detailsRestOff - collection.adjustedContentInset.top
        collection.layoutIfNeeded()

        try await waitUntil { handoffs == 1 }
        #expect(preferredPath == (removedID == "s3e4" ? nil : IndexPath(item: 20, section: 0)))
    }

    @Test func lateMovieLoadOffersFocusToTheFirstRow() async throws {
        let title = item("movie", .movie)
        let provider = StubMediaProvider(id: providerID)
        provider.detailResult = MediaItemDetail(
            item: title, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
            chapters: [], mediaSources: [], trailerURL: URL(string: "https://youtu.be/aqz-KE-bpKQ"),
            contentRating: nil, nextEpisode: nil, collections: []
        )
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
        view.layoutIfNeeded()

        let collection = try #require(view.subviews.compactMap { $0 as? FocusScrollControlledCollectionView }.first)
        view.slideToDetailsTop(animated: false, onReadyForFocus: {
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
        })
        #expect(collection.focusedCellIsTopSection == false)

        var retried = false
        view.onLateInitialFocusReady = {
            retried = true
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
        }
        defer { view.onLateInitialFocusReady = nil }
        view.configure(item: title, detail: provider.detailResult)
        try await waitUntil { retried && collection.focusedCellIsTopSection }
        #expect(collection.lastFocusedIndexPath == IndexPath(item: 0, section: 0))
    }

    @Test func carouselWaitsForRowsAndKeepsFocusOnItsAnchorDuringHandoff() async throws {
        let title = item("movie", .movie)
        let provider = StubMediaProvider(id: providerID)
        provider.detailResult = MediaItemDetail(
            item: title, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
            chapters: [], mediaSources: [], trailerURL: URL(string: "https://youtu.be/aqz-KE-bpKQ"),
            contentRating: nil, nextEpisode: nil, collections: []
        )
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }
        let controller = PreviewCarouselViewController(
            items: [title], selectedIndex: 0, sourceFrame: .zero, sourceTarget: nil,
            standaloneDetail: true, onDismiss: { _ in }
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        controller.view.layoutIfNeeded()
        let focus = try #require(UIFocusSystem.focusSystem(for: window))
        let anchor = try #require(controller.view.subviews.compactMap { $0 as? PreviewFocusAnchorView }.first)
        let details = try #require(controller.view.subviews.compactMap { $0 as? ExpandedDetailContainerView }.first)
        let below = details.belowFoldCollection
        let collection = try #require(below.subviews.compactMap { $0 as? FocusScrollControlledCollectionView }.first)
        try await waitUntil {
            controller.setNeedsFocusUpdate()
            controller.updateFocusIfNeeded()
            let play = (controller.preferredFocusEnvironments.first as? PreviewCardView)?.actionFocusEnvironment
            return play != nil && focus.focusedItem === play
        }
        let play = try #require(focus.focusedItem)
        let hero = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let card = try #require(hero.cellForItem(at: IndexPath(item: 0, section: 0)) as? PreviewCardView)
        let chrome = try #require(card.contentView.subviews.compactMap { $0 as? MediaDetailChromeView }.first)
        try await load(below, item: title, full: false)
        try #require(collection.numberOfSections == 0)

        func finishSlide() {
            let start = CACurrentMediaTime()
            for frame in 1...240 { below.advanceSlide(at: start + Double(frame) / 60) }
        }
        let emptyHeroOffset = collection.contentOffset.y
        controller.enterBelowFold()
        #expect(collection.contentOffset.y == emptyHeroOffset)
        #expect(focus.focusedItem === play)

        below.configure(item: title, detail: provider.detailResult)
        try await waitUntil { collection.numberOfSections > 0 }
        let heroOffset = collection.contentOffset.y
        controller.enterBelowFold()
        #expect(!collection.isScrollEnabled)
        #expect(collection.contentOffset.y == heroOffset)
        #expect(focus.focusedItem === anchor)
        try #require(controller.handleUpNavigation())
        finishSlide()
        try await waitUntil { focus.focusedItem === play }

        controller.enterBelowFold()
        finishSlide()
        #expect(chrome.transform.ty == -details.heroTravelDistance)
        #expect(chrome.chromeAlpha == 1)
        try await waitUntil { collection.focusedCellIsTopSection }

        hero.isHidden = true
        let detailsOffset = collection.contentOffset.y
        controller.returnToHeroFromBelowFold()
        #expect(!collection.isScrollEnabled)
        #expect(collection.contentOffset.y == detailsOffset)
        #expect(focus.focusedItem === anchor)
        hero.isHidden = false
        finishSlide()
        #expect(chrome.transform == .identity)
        try await waitUntil { focus.focusedItem === play }
    }

    @Test func lateFullLoadPreservesTheFocusedSeasonAndRailOffset() async throws {
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
        view.slideToDetailsTop(animated: false)
        host.setNeedsFocusUpdate()
        host.updateFocusIfNeeded()
        let target = IndexPath(item: 21, section: 0)
        try await waitUntil { collection.focusedEpisodeIndexPath == target }
        let focus = try #require(UIFocusSystem.focusSystem(for: window))
        let source = try #require(collection.dataSource as? UICollectionViewDiffableDataSource<BelowFoldSectionKind, BelowFoldItem>)
        func focusedEpisode() -> BelowFoldItem? {
            guard let focused = focus.focusedItem as? UIView,
                  let path = collection.ownedCell(containing: focused)?.indexPath else { return nil }
            return source.itemIdentifier(for: path)
        }
        provider.episodesByShow["show"]?.removeAll {
            $0.parentRef?.itemID == "s1" && ($0.episodeNumber ?? 0) <= 6 && $0.episodeNumber != 2
        }
        view.refreshWatchState()
        let updatedPath = IndexPath(item: 16, section: 0)
        try await waitUntil { source.indexPath(for: .episode("s3e4")) == updatedPath }
        try #require(focusedEpisode() == .episode("s3e4"))
        let cell = try #require(collection.cellForItem(at: updatedPath))
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

        let fullDetail = try #require(makeProvider(onDeck: "s1e2").detailResult)
        var selectedSeason: MediaItemRef?
        view.onSeasonsLoaded = { seasons, index in selectedSeason = seasons[index].ref }
        view.configure(item: item("show", .show), detail: fullDetail)
        try await waitUntil { selectedSeason != nil }
        view.layoutIfNeeded()

        #expect(selectedSeason?.itemID == "s3")
        #expect(focusedEpisode() == .episode("s3e4"))
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

    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out", sourceLocation: sourceLocation)
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
    private let anchor: UIView?

    init(_ content: UIView, anchor: UIView? = nil) {
        self.content = content
        self.anchor = anchor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        guard let anchor else {
            view = content
            return
        }
        view = UIView(frame: content.frame)
        content.frame = view.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content)
        view.addSubview(anchor)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard let anchor else { return [content] }
        return content.isUserInteractionEnabled ? [content, anchor] : [anchor]
    }
}
