// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import UIKit
@testable import Rivulet

@Suite(.serialized)
@MainActor
struct NativeDetailScrollLifecycleTests {
    private func makeView() throws -> (BelowFoldCollectionView, FocusScrollControlledCollectionView) {
        let view = BelowFoldCollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view.layoutIfNeeded()
        let collection = try #require(view.subviews.compactMap { $0 as? FocusScrollControlledCollectionView }.first)
        return (view, collection)
    }

    private func finishSlide(_ view: BelowFoldCollectionView) {
        let start = CACurrentMediaTime()
        for frame in 1...240 {
            view.advanceSlide(at: start + Double(frame) / 60)
        }
    }

    @Test func customSlideRestoresNativeScrollingOnCompletion() throws {
        let (view, collection) = try makeView()
        #expect(collection.isScrollEnabled)
        var focusRequests = 0
        var completions = 0
        view.slideToDetailsTop(animated: true, onReadyForFocus: { focusRequests += 1 },
                               completion: { completions += 1 })
        #expect(collection.isScrollEnabled == false)
        finishSlide(view)
        #expect(focusRequests == 1)
        #expect(completions == 1)
        #expect(collection.isScrollEnabled)
    }

    @Test(arguments: [false, true])
    func activeSlideLandsAtTheNewRestWhenLogoHeightChanges(returning: Bool) throws {
        let (view, collection) = try makeView()
        if returning { view.slideToDetailsTop(animated: false) }
        let start = CACurrentMediaTime()
        var completed = false
        if returning {
            view.slideToHeroRest(animated: true) { completed = true }
        } else {
            view.slideToDetailsTop(animated: true, completion: { completed = true })
        }
        for frame in 1...8 { view.advanceSlide(at: start + Double(frame) / 60) }
        try #require(completed == false)

        let offset = collection.contentOffset.y + collection.adjustedContentInset.top
        let halfPixel = 0.5 / max(1, collection.traitCollection.displayScale)
        view.logoHeight = 60
        #expect(abs(collection.contentOffset.y + collection.adjustedContentInset.top - offset) <= halfPixel)
        for frame in 9...240 { view.advanceSlide(at: start + Double(frame) / 60) }
        try #require(completed)

        let expected = returning ? 0 : view.detailsRestOff
        #expect(abs(collection.contentOffset.y + collection.adjustedContentInset.top - expected) <= halfPixel)
    }

    @Test func lateLogoKeepsTheSettledDetailsAtRest() throws {
        let (view, collection) = try makeView()
        view.slideToDetailsTop(animated: false)
        let originalRest = view.detailsRestOff
        view.logoHeight = 60
        try #require(view.detailsRestOff != originalRest)
        #expect(abs(collection.contentOffset.y + collection.adjustedContentInset.top - view.detailsRestOff) < 0.5)
    }

    @Test func resetCancelsCustomSlideAndRestoresNativeScrolling() throws {
        let (view, collection) = try makeView()
        var staleCompletion = false
        var staleFocus = false
        view.slideToDetailsTop(animated: true, onReadyForFocus: { staleFocus = true },
                               completion: { staleCompletion = true })
        #expect(collection.isScrollEnabled == false)
        view.resetScroll()
        #expect(collection.isScrollEnabled)
        let rest = collection.contentOffset
        finishSlide(view)
        #expect(staleCompletion == false)
        #expect(staleFocus == false)
        #expect(collection.contentOffset == rest)
    }

    @Test func immediateReturnSupersedesCustomSlide() throws {
        let (view, collection) = try makeView()
        var staleCompletion = false
        var returned = false
        view.slideToDetailsTop(animated: true, completion: { staleCompletion = true })
        view.slideToHeroRest(animated: false) { returned = true }
        #expect(returned)
        #expect(collection.isScrollEnabled)
        let rest = collection.contentOffset
        finishSlide(view)
        #expect(staleCompletion == false)
        #expect(collection.contentOffset == rest)
    }

    @Test func immediateEntrySupersedesTheReverseSlide() throws {
        let (view, collection) = try makeView()
        view.slideToDetailsTop(animated: false)
        var staleCompletion = false
        var entered = false
        view.slideToHeroRest(animated: true) { staleCompletion = true }
        view.slideToDetailsTop(animated: false, completion: { entered = true })
        let rest = collection.contentOffset
        finishSlide(view)
        #expect(entered)
        #expect(staleCompletion == false)
        #expect(collection.contentOffset == rest)
        #expect(collection.isScrollEnabled)
    }

    @Test func coveringThePageDoesNotDiscardTheSlideCompletion() throws {
        let (view, collection) = try makeView()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = view.bounds
        window.addSubview(view)
        var completed = false
        view.slideToDetailsTop(animated: true, completion: { completed = true })
        view.removeFromSuperview()
        finishSlide(view)
        #expect(completed)
        #expect(collection.isScrollEnabled)
    }

    @Test func anotherScrollViewCannotDriveDetailChoreography() throws {
        let (view, collection) = try makeView()
        let rail = UIScrollView()
        rail.contentOffset = CGPoint(x: 200, y: 80)
        var reported: [CGFloat] = []
        view.onScroll = { reported.append($0) }
        view.scrollViewDidScroll(rail)
        #expect(reported.isEmpty)
        view.scrollViewDidScroll(collection)
        #expect(reported.count == 1)
        var proposed = CGPoint(x: 300, y: 0)
        view.scrollViewWillEndDragging(rail, withVelocity: .zero, targetContentOffset: &proposed)
        #expect(proposed == CGPoint(x: 300, y: 0))
    }

    @Test func focusCallbackCanReverseTheSlideWithoutCompletingTheOldRequest() throws {
        let (view, collection) = try makeView()
        let hero = collection.contentOffset.y
        var staleCompletion = false
        var returned = false
        view.slideToDetailsTop(animated: true, onReadyForFocus: {
            view.slideToHeroRest(animated: true) { returned = true }
        }, completion: { staleCompletion = true })
        finishSlide(view)
        #expect(returned)
        #expect(staleCompletion == false)
        #expect(collection.contentOffset.y == hero)
        #expect(collection.isScrollEnabled)
    }

    @Test func focusCallbackCanResetWithoutAStaleCompletion() throws {
        let (view, collection) = try makeView()
        let hero = collection.contentOffset.y
        var staleCompletion = false
        view.slideToDetailsTop(animated: true, onReadyForFocus: { view.resetScroll() },
                               completion: { staleCompletion = true })
        finishSlide(view)
        #expect(staleCompletion == false)
        #expect(collection.contentOffset.y == hero)
        #expect(collection.isScrollEnabled)
    }

    @Test func immediateFocusCallbackCanSupersedeItsCompletion() throws {
        let (view, collection) = try makeView()
        let hero = collection.contentOffset.y
        var staleCompletion = false
        view.slideToDetailsTop(animated: false, onReadyForFocus: { view.resetScroll() },
                               completion: { staleCompletion = true })
        #expect(staleCompletion == false)
        #expect(collection.contentOffset.y == hero)
    }
}

@Suite(.serialized)
@MainActor
struct DetailMotionTests {
    @Test(arguments: [MediaKind.movie, .show])
    func primaryArtworkKeepsItsShorterPath(kind: MediaKind) async throws {
        let provider = StubMediaProvider(id: "detail-motion-\(kind)")
        let title = item("title", kind: kind, providerID: provider.id)
        if kind == .movie {
            provider.relatedContent = RelatedContent(
                items: [item("related", kind: .movie, providerID: provider.id)], collection: nil)
            provider.detailResult = MediaItemDetail(
                item: title, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
                chapters: [], mediaSources: [], trailerURL: URL(string: "https://youtu.be/aqz-KE-bpKQ"),
                contentRating: nil, nextEpisode: nil, collections: [])
        } else {
            provider.episodesByShow["title"] = [item("episode", kind: .episode, providerID: provider.id)]
        }
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }

        let view = BelowFoldCollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let collection = try #require(view.subviews.compactMap { $0 as? UICollectionView }.first)
        view.configure(item: title, detail: nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while collection.numberOfSections == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(collection.numberOfSections > 0)
        view.layoutIfNeeded()
        view.slideToDetailsTop(animated: false)
        collection.layoutIfNeeded()
        let cell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        let restingY = cell.frame.minY
        view.setLowerRowsOffset(120)
        #expect(abs(cell.frame.minY - restingY) < 0.5)
        if kind == .movie {
            let header = try #require(collection.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 0)))
            #expect(header.transform.ty == 120)
            var rail: UIView = cell
            while let parent = rail.superview, parent !== collection { rail = parent }
            try #require(rail.superview === collection)
            try #require(header.superview === collection)
            let layers = try #require(collection.layer.sublayers)
            let headerOrder = try #require(layers.firstIndex { $0 === header.layer })
            let railOrder = try #require(layers.firstIndex { $0 === rail.layer })
            #expect(header.layer.zPosition < rail.layer.zPosition
                    || (header.layer.zPosition == rail.layer.zPosition && headerOrder < railOrder),
                    "The moving heading must render behind its orthogonal artwork rail")
            let lower = try #require(collection.cellForItem(at: IndexPath(item: 0, section: 1)))
            #expect(lower.transform.ty == 120)
        }
        view.setLowerRowsOffset(0)
        #expect(abs(cell.frame.minY - restingY) < 0.5)
    }

    @Test(arguments: [false, true])
    func castFocusDestinationIgnoresTheTemporaryRowTranslation(hasTrailers: Bool) async throws {
        let provider = StubMediaProvider(id: "cast-motion-\(hasTrailers)")
        let title = item("title", kind: .show, providerID: provider.id)
        provider.episodesByShow["title"] = [item("episode", kind: .episode, providerID: provider.id)]
        provider.relatedContent = RelatedContent(
            items: [item("related", kind: .movie, providerID: provider.id)], collection: nil)
        provider.detailResult = MediaItemDetail(
            item: title, tagline: nil, genres: [], studios: [],
            cast: [MediaPerson(id: "actor", name: "Actor", role: "Role", imageURL: nil)],
            directors: [], writers: [], chapters: [], mediaSources: [],
            trailerURL: hasTrailers ? URL(string: "https://youtu.be/aqz-KE-bpKQ") : nil,
            contentRating: nil, nextEpisode: nil, collections: [])
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }

        let view = BelowFoldCollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let collection = try #require(view.subviews.compactMap { $0 as? FocusScrollControlledCollectionView }.first)
        let source = try #require(collection.dataSource as? UICollectionViewDiffableDataSource<BelowFoldSectionKind, BelowFoldItem>)
        view.configure(item: title, detail: provider.detailResult)
        let deadline = ContinuousClock.now + .seconds(3)
        while !source.snapshot().sectionIdentifiers.contains(.cast), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let section = try #require(source.snapshot().sectionIdentifiers.firstIndex(of: .cast))
        view.layoutIfNeeded()
        view.slideToDetailsTop(animated: false)
        collection.layoutIfNeeded()
        let path = IndexPath(item: 0, section: section)
        collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
        let cell = try #require(collection.cellForItem(at: path))
        let target = try #require(collection.restingOffset(for: cell))
        let restingY = cell.convert(cell.bounds, to: collection).minY
        let maxY = collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom
        try #require(target.y > -collection.adjustedContentInset.top + 120 && target.y + 120 < maxY)
        for offset: CGFloat in [120, 40, 0] {
            view.setLowerRowsOffset(offset)
            #expect(abs(cell.convert(cell.bounds, to: collection).minY - restingY - offset) < 0.5)
            #expect(collection.restingOffset(for: cell) == target,
                    "A second Down during the slide must use the row's final resting geometry")
        }
    }

    @Test(arguments: [BelowFoldSectionKind.cast, .trailers, .extras, .about, .related, .collection], [false, true])
    func primaryRowsFinishAtTheirNativeFocusDestination(primary: BelowFoldSectionKind, animated: Bool) async throws {
        let provider = StubMediaProvider(id: "primary-landing-\(primary)-\(animated)")
        let title = item("title", kind: .movie, providerID: provider.id)
        provider.detailResult = MediaItemDetail(
            item: title, tagline: nil, genres: [], studios: [],
            cast: primary == .cast ? [MediaPerson(id: "actor", name: "Actor", role: "Role", imageURL: nil)] : [],
            directors: [], writers: [], chapters: [], mediaSources: [],
            trailerURL: primary == .trailers ? URL(string: "https://youtu.be/aqz-KE-bpKQ") : nil,
            contentRating: nil, nextEpisode: nil, collections: [])
        if primary == .extras {
            provider.detailResult?.extras = [MediaItemDetail.Extra(
                id: "extra", title: "Extra", thumbnailURL: nil, duration: nil,
                playbackKey: "extra", providerID: provider.id)]
        }
        let poster = item("poster", kind: .movie, providerID: provider.id)
        if primary == .related {
            provider.relatedContent = RelatedContent(items: [poster], collection: nil)
        } else if primary == .collection {
            provider.relatedContent = RelatedContent(
                items: [], collection: CollectionRow(title: "Collection", members: [poster], collection: nil))
        }
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }
        let view = ExpandedDetailContainerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view.item = title
        view.setExpanded(true)
        view.layoutIfNeeded()
        view.revealBelowFoldCollection()
        let below = view.belowFoldCollection
        let collection = try #require(below.subviews.compactMap { $0 as? FocusScrollControlledCollectionView }.first)
        let source = try #require(collection.dataSource as? UICollectionViewDiffableDataSource<BelowFoldSectionKind, BelowFoldItem>)
        let deadline = ContinuousClock.now + .seconds(3)
        while collection.numberOfSections == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(source.snapshot().sectionIdentifiers.first == primary)
        view.layoutIfNeeded()
        collection.layoutIfNeeded()
        let path = IndexPath(item: 0, section: 0)
        let header = collection.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: path)
        let heroRest = view.heroTravelDistance - below.detailsRestOff
        if primary == .cast || primary == .trailers || primary == .extras {
            let header = try #require(header)
            #expect(abs(header.transform.ty - heroRest) < 0.5)
        }
        view.setBelowFoldScrollActive(true)
        var completed = false
        below.slideToDetailsTop(animated: animated, travelDistance: view.heroTravelDistance,
                                completion: { completed = true })
        let start = CACurrentMediaTime()
        for frame in 1...240 { below.advanceSlide(at: start + Double(frame) / 60) }
        try #require(completed)
        collection.layoutIfNeeded()
        let cell = try #require(collection.cellForItem(at: path))
        let focusCell: UICollectionViewCell
        if let shelf = cell as? ShelfRowCell {
            shelf.layoutIfNeeded()
            shelf.rowCollectionView.layoutIfNeeded()
            focusCell = try #require(shelf.rowCollectionView.cellForItem(at: path))
        } else {
            focusCell = cell
        }
        let target = try #require(collection.restingOffset(for: focusCell))
        #expect(abs(target.y - collection.contentOffset.y) < 0.5,
                "The next horizontal focus move must not correct the primary row's vertical landing")
        #expect(view.scrollProgress == 1)
        below.slideToHeroRest(animated: false)
        view.setBelowFoldScrollActive(false)
        if let header { #expect(abs(header.transform.ty - heroRest) < 0.5) }
    }

    @Test(arguments: [false, true])
    func lateLogoPreservesHeroProgressMidSlide(returning: Bool) throws {
        let view = ExpandedDetailContainerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view.layoutIfNeeded()
        let below = view.belowFoldCollection
        view.setBelowFoldScrollActive(true)
        var updates: [CGFloat] = []
        view.onScrollProgress = { updates.append($0) }
        if returning {
            below.slideToDetailsTop(animated: false)
            below.slideToHeroRest(animated: true, travelDistance: view.heroTravelDistance)
        } else {
            below.slideToDetailsTop(animated: true, travelDistance: view.heroTravelDistance)
        }
        let start = CACurrentMediaTime()
        for frame in 1...16 { below.advanceSlide(at: start + Double(frame) / 60) }
        let progress = try #require(updates.last)
        try #require(progress > 0 && progress < 1)

        let oldRest = below.detailsRestOff
        updates.removeAll()
        below.logoHeight = 60
        try #require(below.detailsRestOff > oldRest)
        #expect(updates == [progress])

        for frame in 17...240 { below.advanceSlide(at: start + Double(frame) / 60) }
        #expect(updates.last == (returning ? 0 : 1))
        #expect(zip(updates, updates.dropFirst()).allSatisfy { returning ? $0 >= $1 : $0 <= $1 })
    }

    @Test func lateLogoDuringPeekDoesNotNotifyTheHero() throws {
        let view = ExpandedDetailContainerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view.layoutIfNeeded()
        var progressUpdates: [CGFloat] = []
        view.onScrollProgress = { progressUpdates.append($0) }
        let originalRest = view.belowFoldCollection.detailsRestOff
        view.belowFoldCollection.logoHeight = 60

        try #require(view.belowFoldCollection.detailsRestOff != originalRest)
        #expect(progressUpdates.isEmpty)
    }

    @Test func seasonSelectorDisappearsBeforeItsReturnTravelEnds() throws {
        let view = ExpandedDetailContainerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view.layoutIfNeeded()
        view.setSeasonPills(["Season 1", "Season 2"], seasonRefIDs: ["s1", "s2"], selectedIndex: 0)
        let pill = try #require(view.seasonPillsFocusEnvironment as? SeasonPillView)
        let header = try #require(pill.superview?.superview?.superview)
        try #require(header.superview === view)
        let distance = view.belowFoldCollection.detailsRestOff
        try #require(distance > 0)
        view.setBelowFoldScrollActive(true)
        view.driveScrollProgress(fromCollectionOffset: distance)
        #expect(header.alpha == 1)
        view.driveScrollProgress(fromCollectionOffset: distance / 2)
        #expect(header.alpha == 0, "The selector must not trail translucently over the returning hero")
        #expect(header.transform.ty > 0)
        view.driveScrollProgress(fromCollectionOffset: 0)
        #expect(header.alpha == 0)
        view.driveScrollProgress(fromCollectionOffset: distance / 2)
        #expect(header.alpha == 0)
        view.driveScrollProgress(fromCollectionOffset: distance)
        #expect(header.alpha == 1)
    }

    private func item(_ id: String, kind: MediaKind, providerID: String) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: id),
            kind: kind, title: id, sortTitle: nil, overview: nil,
            year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
    }
}

@MainActor
struct DetailScrollMotionTests {
    @Test(arguments: [-1040.0, 1040.0])
    func settlesWithoutOvershooting(target: Double) {
        var motion = DetailScrollMotion(position: 0, target: target, time: 0)
        var finished = false
        for frame in 1...180 {
            let previous = motion.position
            finished = motion.advance(at: Double(frame) / 60)
            #expect(abs(target - motion.position) <= abs(target - previous))
            if finished { break }
        }
        #expect(finished)
        #expect(motion.position == target)
    }

    @Test func retargetKeepsMomentumAndReversalEventuallySettles() {
        var motion = DetailScrollMotion(position: 0, target: 1040, time: 0)
        for frame in 1...4 { _ = motion.advance(at: Double(frame) / 60) }
        let position = motion.position
        motion.target = -1040
        _ = motion.advance(at: 5.0 / 60)
        #expect(motion.position > position, "Reversal must preserve the outgoing momentum")
        var finished = false
        for frame in 6...240 {
            finished = motion.advance(at: Double(frame) / 60)
            if finished { break }
        }
        #expect(finished)
        #expect(motion.position == -1040)
    }

    @Test func longHeartbeatDoesNotReplayHundredsOfAccelerationSteps() {
        var delayed = DetailScrollMotion(position: 0, target: 1040, time: 0)
        var regular = delayed
        _ = delayed.advance(at: 1)
        for frame in 1...6 { _ = regular.advance(at: Double(frame) / 60) }
        #expect(delayed.position < regular.position)
    }

    @Test func invalidAndBackwardsTimesDoNotCorruptTheNextFrame() {
        var motion = DetailScrollMotion(position: 0, target: 1040, time: 0)
        var reference = motion
        _ = motion.advance(at: .nan)
        _ = motion.advance(at: -1)
        _ = motion.advance(at: .infinity)
        _ = motion.advance(at: 1.0 / 60)
        _ = reference.advance(at: 1.0 / 60)
        #expect(motion.position == reference.position)
    }

    @Test func subpixelTailReachesTheExactDestination() {
        var motion = DetailScrollMotion(position: 0, target: 0.6, time: 0)
        var finished = false
        for frame in 1...180 {
            finished = motion.advance(at: Double(frame) / 60)
            if finished { break }
        }
        #expect(finished)
        #expect(motion.position == 0.6)
    }
}
