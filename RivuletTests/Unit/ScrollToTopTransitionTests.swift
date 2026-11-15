import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class ScrollToTopTransitionTests: XCTestCase {
    func test_topLayoutSettlesImmediatelyWhileSlideAnimates() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Reduce Motion intentionally disables the slide")
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let scroll = SnapshotScrollView(frame: container.bounds)
        container.addSubview(scroll)
        scroll.contentSize = CGSize(width: 1920, height: 6000)
        scroll.contentOffset.y = 3000

        ScrollToTopTransition.perform(in: scroll) {
            scroll.contentOffset.y = 0
        }

        XCTAssertEqual(scroll.contentOffset.y, 0)
        let slide = try XCTUnwrap(scroll.layer.animation(forKey: "returnToTop") as? CABasicAnimation)
        XCTAssertGreaterThan(slide.duration, 0, "The return must animate rather than jump")
        XCTAssertEqual(slide.fromValue as? CGFloat, -scroll.bounds.height, "Long returns travel at most one screen")
        XCTAssertEqual(slide.toValue as? CGFloat, 0)
        XCTAssertEqual(container.subviews.count, 2, "The outgoing picture covers the layout jump")
    }

    func test_alreadyAtTopStillUpdatesFocusWithoutAnimating() {
        let scroll = SnapshotScrollView()
        var updated = false
        var completed = false
        ScrollToTopTransition.perform(in: scroll, updates: { updated = true }, completion: { completed = true })
        XCTAssertTrue(updated)
        XCTAssertTrue(completed)
        XCTAssertNil(scroll.layer.animation(forKey: "returnToTop"))
    }

    func test_emptyCollectionReturnsToItsInsetWithoutAnInvalidFocusTarget() {
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                          collectionViewLayout: UICollectionViewFlowLayout())
        collection.contentInsetAdjustmentBehavior = .never
        collection.contentInset.top = 60
        collection.contentOffset.y = 400
        SidebarReselection.returnToTop(in: collection, focusing: IndexPath(item: 0, section: 0))
        XCTAssertEqual(collection.contentOffset.y, -60)
    }

    private final class SnapshotScrollView: UIScrollView {
        override func snapshotView(afterScreenUpdates afterUpdates: Bool) -> UIView? {
            UIView(frame: bounds)
        }
    }
}
