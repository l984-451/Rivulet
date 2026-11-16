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

    @Test func customSlideRestoresNativeScrollingOnCompletion() throws {
        let (view, collection) = try makeView()
        #expect(collection.isScrollEnabled)
        var completed = false
        view.slideToDetailsTop(animated: true) { completed = true }
        #expect(collection.isScrollEnabled == false)
        view.advanceSlide(at: CACurrentMediaTime() + 1)
        #expect(completed)
        #expect(collection.isScrollEnabled)
    }

    @Test func resetCancelsCustomSlideAndRestoresNativeScrolling() throws {
        let (view, collection) = try makeView()
        var staleCompletion = false
        view.slideToDetailsTop(animated: true) { staleCompletion = true }
        #expect(collection.isScrollEnabled == false)
        view.resetScroll()
        #expect(collection.isScrollEnabled)
        let rest = collection.contentOffset
        view.advanceSlide(at: CACurrentMediaTime() + 1)
        #expect(staleCompletion == false)
        #expect(collection.contentOffset == rest)
    }

    @Test func immediateReturnSupersedesCustomSlide() throws {
        let (view, collection) = try makeView()
        var staleCompletion = false
        var returned = false
        view.slideToDetailsTop(animated: true) { staleCompletion = true }
        view.slideToHeroRest(animated: false) { returned = true }
        #expect(returned)
        #expect(collection.isScrollEnabled)
        let rest = collection.contentOffset
        view.advanceSlide(at: CACurrentMediaTime() + 1)
        #expect(staleCompletion == false)
        #expect(collection.contentOffset == rest)
    }

    @Test func immediateEntrySupersedesTheReverseSlide() throws {
        let (view, collection) = try makeView()
        view.slideToDetailsTop(animated: false)
        var staleCompletion = false
        var entered = false
        view.slideToHeroRest(animated: true) { staleCompletion = true }
        view.slideToDetailsTop(animated: false) { entered = true }
        let rest = collection.contentOffset
        view.advanceSlide(at: CACurrentMediaTime() + 1)
        #expect(entered)
        #expect(staleCompletion == false)
        #expect(collection.contentOffset == rest)
        #expect(collection.isScrollEnabled)
    }

    @Test func coveringThePageDoesNotDiscardTheSlideCompletion() throws {
        let (view, collection) = try makeView()
        let window = UIWindow(frame: view.bounds)
        window.addSubview(view)
        var completed = false
        view.slideToDetailsTop(animated: true) { completed = true }
        view.removeFromSuperview()
        view.advanceSlide(at: CACurrentMediaTime() + 1)
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
}
