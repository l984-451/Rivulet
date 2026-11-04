import Testing
import UIKit
@testable import Rivulet

@MainActor
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

        await load(view, item: item("show", .show), full: full)
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
        await load(view, item: item("show", .show), full: false)
        provider.detailResult = nil
        provider.episodesByShow["other"] = [item("other-e1", .episode, parent: "other-s1", season: 1, episode: 1)]

        await load(view, item: item("other", .show), full: false)
        view.layoutIfNeeded()
        let collection = try #require(view.subviews.compactMap { $0 as? UICollectionView }.first)

        #expect(view.indexPathForPreferredFocusedView(in: collection) == IndexPath(item: 0, section: 0))
        #expect(collection.numberOfItems(inSection: 0) == 1)
    }

    private func load(_ view: BelowFoldCollectionView, item: MediaItem, full: Bool) async {
        await withCheckedContinuation { continuation in
            if full {
                view.onSeasonsLoaded = { _, _ in continuation.resume() }
                view.configure(item: item, detail: nil)
            } else {
                view.onEpisodesApplied = { continuation.resume() }
                view.configureEpisodesOnly(item: item)
            }
        }
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
