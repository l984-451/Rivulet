import Testing
import UIKit
@testable import Rivulet

@MainActor
struct EpisodeDetailNavigationTests {
    @Test(.serialized, arguments: [false, true], [false, true])
    func swipesReachSelectableInfoAndRespectModal(hasExtras: Bool, entersBeforeLoad: Bool) async throws {
        let provider = StubMediaProvider(id: UUID().uuidString)
        let item = MediaItem(
            ref: MediaItemRef(providerID: provider.id, itemID: "episode"), kind: .episode, title: "Episode",
            sortTitle: nil, overview: "Episode overview", year: 2026, runtime: 1800,
            parentRef: nil, grandparentRef: nil, episodeNumber: 1, seasonNumber: 3, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
        var detail = MediaItemDetail(
            item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
            chapters: [], mediaSources: [], trailerURL: nil, contentRating: nil, nextEpisode: nil, collections: [])
        if hasExtras {
            detail.extras = [.init(id: "extra", title: "Extra", thumbnailURL: nil, duration: 60,
                                   playbackKey: "extra", providerID: provider.id)]
        }
        provider.detailResult = detail
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }

        let page = MediaItemDetailPageViewController(item: item, seriesTitle: nil, onPlay: { _, _ in })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = page
        window.isHidden = false
        defer { window.isHidden = true }
        page.loadViewIfNeeded()
        let columns = try #require(descendants(of: page.view).compactMap { $0 as? InfoColumnsView }.first)
        if entersBeforeLoad {
            page.pressesBegan([ArrowPress(.downArrow)], with: nil)
            #expect(page.preferredFocusEnvironments.first === columns)
        }
        try await waitUntil { descendants(of: columns).contains { $0 is AboutCardControl } }
        page.view.layoutIfNeeded()
        if entersBeforeLoad {
            #expect(page.preferredFocusEnvironments.first === columns)
            #expect(columns.isUserInteractionEnabled)
            for _ in 0..<(hasExtras ? 2 : 1) {
                page.pressesBegan([ArrowPress(.upArrow)], with: nil)
            }
        }
        let cards = descendants(of: columns).compactMap { $0 as? AboutCardControl }
        #expect(cards.count == 3)
        #expect(cards.allSatisfy { $0.canBecomeFocused })
        #expect(columns.isUserInteractionEnabled == false)

        let buttons = descendants(of: page.view).compactMap { $0 as? FocusableActionButton }
        let previousButton = try #require(buttons.last)
        #expect(page.preferredFocusEnvironments.first === buttons.first)
        page.rememberHeroFocus(previousButton)
        page.rememberHeroFocus(cards.first)

        let swipes = (page.view.gestureRecognizers ?? []).compactMap { $0 as? UISwipeGestureRecognizer }
        let down = try #require(swipes.first { $0.direction == .down })
        let up = try #require(swipes.first { $0.direction == .up })
        let binding = try #require(down.delegate as? DirectionalInputBinding)
        let scroll = try #require(page.view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(binding.gestureRecognizerShouldBegin(up) == false)
        #expect(binding.gestureRecognizerShouldBegin(down))
        binding.handleSwipe(down)
        #expect(scroll.contentOffset.y > 0)
        if hasExtras {
            #expect(columns.isUserInteractionEnabled == false)
            let extras = try #require(descendants(of: page.view).compactMap { $0 as? ExtrasShelfView }.first)
            #expect(page.preferredFocusEnvironments.first === extras.firstCard)
            binding.handleSwipe(down)
        }
        #expect(columns.isUserInteractionEnabled)
        #expect(page.preferredFocusEnvironments.first === columns)
        #expect(binding.gestureRecognizerShouldBegin(down) == false)
        let infoOffset = scroll.contentOffset
        let stepsToInfo = hasExtras ? 2 : 1

        for _ in 0..<stepsToInfo { binding.handleSwipe(up) }
        #expect(scroll.contentOffset == .zero)
        #expect(columns.isUserInteractionEnabled == false)
        #expect(page.preferredFocusEnvironments.first === previousButton)
        for _ in 0..<stepsToInfo {
            page.pressesBegan([ArrowPress(.downArrow)], with: nil)
        }
        #expect(scroll.contentOffset == infoOffset)
        #expect(page.preferredFocusEnvironments.first === columns)

        for card in cards {
            card.sendActions(for: .primaryActionTriggered)
            let popup = try #require(page.presentedViewController as? InfoPopupViewController)
            try await waitUntil { popup.isBeingPresented == false }
            #expect(binding.gestureRecognizerShouldBegin(up) == false)
            page.pressesBegan([ArrowPress(.upArrow)], with: nil)
            #expect(scroll.contentOffset == infoOffset)
            await withCheckedContinuation { continuation in
                page.dismiss(animated: false) { continuation.resume() }
            }
        }
        #expect(binding.gestureRecognizerShouldBegin(up))
        for _ in 0..<stepsToInfo {
            page.pressesBegan([ArrowPress(.upArrow)], with: nil)
        }
        #expect(page.preferredFocusEnvironments.first === previousButton)
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while condition() == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

private final class ArrowPress: UIPress {
    private let arrow: UIPress.PressType
    init(_ arrow: UIPress.PressType) {
        self.arrow = arrow
        super.init()
    }
    override var type: UIPress.PressType { arrow }
}
